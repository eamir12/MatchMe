// lib/screens/profile/intent_drill_page.dart
// Intent drill page with per-page optimistic local selection state so checkboxes
// update instantly and never "jump" when the provider or remote updates arrive.
// - Checkbox/row taps update a local Set immediately (snappy UI).
// - Background calls to notifier.toggleSubIntent / toggleInterest persist changes with awaitPersist: false.
// - Chevron is the only control that loads children (no race between toggle+fetch).
// - Keys used for rows to avoid rebuild-related visual flips.
// - handleBack() remains for wizard integration.

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/option_node_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/locale_provider.dart';

class IntentDrillPage extends ConsumerStatefulWidget {
  final String intentKey;
  final String rootId; // id or key used to fetch root children
  final String rootNodeKey;
  final String rootLabel;
  final String userId;
  final bool autoCloseOnSelect;
  final bool showInternalNavigation;
  final void Function()? onBack;
  final void Function(Map<String, dynamic> node)? onSelectLeaf;
  final void Function()? onDone;

  const IntentDrillPage({
    super.key,
    required this.intentKey,
    required this.rootId,
    required this.rootNodeKey,
    required this.rootLabel,
    required this.userId,
    this.autoCloseOnSelect = true,
    this.showInternalNavigation = true,
    this.onBack,
    this.onSelectLeaf,
    this.onDone,
  });

  @override
  IntentDrillPageState createState() => IntentDrillPageState();
}

class IntentDrillPageState extends ConsumerState<IntentDrillPage> {
  final Set<String> _expandedKeys = {};
  final Map<String, bool> _loading = {};
  final Set<String> _processing = {}; // prevent duplicate concurrency per node

  // Local optimistic selection cache for the duration of this page
  // Keeps UI snappy and prevents "jump" as provider refreshes.
  final Set<String> _localSelectedSubIntents = {};
  final Set<String> _localSelectedInterests = {};
  bool _localInitialized = false;

  String _normalizeKey(String s) {
    final trimmed = s.trim().toLowerCase();
    final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
    return collapsed.replaceAll(RegExp(r'^_|_$'), '');
  }

  String _findMatchingIntentKey(Map<String, dynamic>? subIntentsMap, String candidate) {
    if (subIntentsMap == null) return candidate;
    final target = _normalizeKey(candidate);
    for (final k in subIntentsMap.keys) {
      if (_normalizeKey(k) == target) return k;
    }
    return candidate;
  }

  /// Called by the wizard to collapse expansions first, otherwise navigate back.
  void handleBack() {
    if (_expandedKeys.isNotEmpty) {
      setState(() => _expandedKeys.clear());
      return;
    }
    if (widget.onBack != null) {
      widget.onBack!();
      return;
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    // Initialize local selection cache once after first frame (we need ref available)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final profile = ref.read(profileEditProvider(widget.userId)).asData?.value;
      if (profile != null && !_localInitialized) {
        // populate subintent selections for this intent; use tolerant key matching
        final mainKey = _findMatchingIntentKey(profile.subIntents, widget.intentKey);
        final subs = profile.subIntents[mainKey] ?? <String>[];
        _localSelectedSubIntents.addAll(subs);
        // populate interest selections prefixed by this intent
        profile.interests.forEach((pref, list) {
          final prefIntent = pref.split('::').first;
          if (_normalizeKey(prefIntent) == _normalizeKey(widget.intentKey)) {
            _localSelectedInterests.addAll(list);
          }
        });
        setState(() {
          _localInitialized = true;
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> _fetchChildrenTryBoth(String maybeId, String maybeKey) async {
    try {
      final byId = await ref.read(fetchChildrenProvider(maybeId).future);
      if (byId.isNotEmpty) return byId;
    } catch (_) {}
    try {
      if (maybeKey.isNotEmpty && maybeKey != maybeId) {
        final byKey = await ref.read(fetchChildrenProvider(maybeKey).future);
        if (byKey.isNotEmpty) return byKey;
      }
    } catch (_) {}
    return <Map<String, dynamic>>[];
  }

  void _toggleExpanded(String key) => setState(() {
        if (_expandedKeys.contains(key)) {
          _expandedKeys.remove(key);
        } else {
          _expandedKeys.add(key);
        }
      });

  Color _accentColorForIntent(String intentKey) {
    final k = intentKey.toLowerCase();
    if (k.contains('romantic')) return Colors.pink.shade600;
    if (k.contains('friend')) return Colors.indigo.shade600;
    if (k.contains('activity')) return Colors.teal.shade600;
    if (k.contains('business')) return Colors.deepOrange.shade600;
    return Theme.of(context).colorScheme.primary;
  }

  // Check whether a node should be shown checked — consult local cache first (optimistic),
  // then fall back to provider's current value if local not initialized for that node.
  bool _isNodeChecked(Map<String, dynamic> node, UserProfile? profile) {
    final nodeKey = (node['node_key'] ?? '').toString();
    final nodeType = (node['node_type'] ?? '').toString();
    if (nodeType == 'subintent' || nodeType == 'subinterest') {
      if (_localInitialized) return _localSelectedSubIntents.contains(nodeKey);
      final mainKey = _findMatchingIntentKey(profile?.subIntents, widget.intentKey);
      return profile?.subIntents[mainKey]?.contains(nodeKey) ?? false;
    } else {
      // interest
      final category = (node['category_key'] ?? '') as String? ?? '';
      if (_localInitialized) {
        return _localSelectedInterests.contains(nodeKey);
      }
      final pref = '${widget.intentKey}::$category';
      // tolerant lookup: find matching pref by normalized form in user's interests
      final userPrefs = profile?.interests.keys.toList() ?? [];
      final matchedPref = userPrefs.firstWhere((p) => _normalizeKey(p) == _normalizeKey(pref), orElse: () => pref);
      return profile?.interests[matchedPref]?.contains(nodeKey) ?? false;
    }
  }

  // Update local cache immediately, then persist in background (awaitPersist: false)
  void _toggleSelectionLocallyThenPersist(Map<String, dynamic> node) {
    final nodeKey = (node['node_key'] ?? '').toString();
    final nodeType = (node['node_type'] ?? '').toString();
    if (_processing.contains(nodeKey)) return;
    _processing.add(nodeKey);

    // update local cache synchronously for immediate UI response
    setState(() {
      if (nodeType == 'subintent' || nodeType == 'subinterest') {
        if (_localSelectedSubIntents.contains(nodeKey)) {
          _localSelectedSubIntents.remove(nodeKey);
        } else {
          _localSelectedSubIntents.add(nodeKey);
        }
      } else {
        if (_localSelectedInterests.contains(nodeKey)) {
          _localSelectedInterests.remove(nodeKey);
        } else {
          _localSelectedInterests.add(nodeKey);
        }
      }
    });

    // persist in the background
    Future.microtask(() async {
      try {
        if (nodeType == 'subintent' || nodeType == 'subinterest') {
          ref.read(profileEditProvider(widget.userId).notifier).toggleSubIntent(widget.intentKey, nodeKey, awaitPersist: false);
        } else {
          final category = node['category_key'] as String? ?? '';
          final pref = '${widget.intentKey}::$category';
          ref.read(profileEditProvider(widget.userId).notifier).toggleInterest(pref, nodeKey, awaitPersist: false);
        }
        if (widget.onSelectLeaf != null) widget.onSelectLeaf!(node);
      } catch (e) {
        // If persistence failed in a way that should revert local UI,
        // we can optionally revert local state here. For now we keep optimistic state.
      } finally {
        _processing.remove(nodeKey);
      }
    });
  }

  Future<void> _expandOrCollapse(Map<String, dynamic> node) async {
    final nodeKey = (node['node_key'] ?? '').toString();
    if (_processing.contains(nodeKey)) return;
    _processing.add(nodeKey);
    if (mounted) setState(() => _loading[nodeKey] = true);
    try {
      final children = await _fetchChildrenTryBoth(node['id']?.toString() ?? '', nodeKey);
      if (children.isNotEmpty) _toggleExpanded(nodeKey);
    } catch (e) {
      // Fetch error
    } finally {
      _processing.remove(nodeKey);
      if (mounted) setState(() => _loading[nodeKey] = false);
    }
  }

  // Simple localization helpers (kept local for this widget)
  String _humanizeKey(String key) {
    var s = key;
    s = s.replaceAll(RegExp(r'^(interest_category_|interest_|category_|subIntent|intent|profileEdit)'), '');
    s = s.replaceAll('_', ' ');
    s = s.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final human = words.map((w) {
      if (w.length <= 1) return w.toUpperCase();
      return w[0].toUpperCase() + w.substring(1);
    }).join(' ');
    return human.isEmpty ? key : human;
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key) return null;
      return val;
    } catch (_) {
      return null;
    }
  }

  Widget _buildRow(Map<String, dynamic> node, UserProfile? profile) {
    final nodeKey = (node['node_key'] ?? '').toString();
    final displayKey = (node['display_key'] ?? node['node_key'] ?? '').toString();

    final l10n = ref.read(localizationProvider);
    final label = _tryGetString(l10n, displayKey) ?? _humanizeKey(displayKey);

    final checked = _isNodeChecked(node, profile);
    final loading = _loading[nodeKey] == true;
    final expanded = _expandedKeys.contains(nodeKey);
    final accent = _accentColorForIntent(widget.intentKey);

    final childrenAsync = ref.watch(fetchChildrenProvider(nodeKey));

    // leading checkbox area (keeps fixed width)
    final leading = SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: GestureDetector(
          onTap: () => _toggleSelectionLocallyThenPersist(node),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
            child: loading
                ? SizedBox(key: ValueKey('loading_$nodeKey'), width: 20, height: 20, child: const CircularProgressIndicator(strokeWidth: 2))
                : checked
                    ? Container(
                        key: ValueKey('checked_$nodeKey'),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6)),
                        child: const Icon(Icons.check, size: 14, color: Colors.white),
                      )
                    : Container(
                        key: ValueKey('unchecked_$nodeKey'),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.grey.shade400)),
                      ),
          ),
        ),
      ),
    );

    // small icon (type)
    final smallIcon = CircleAvatar(
      radius: 16,
      backgroundColor: accent.withValues(alpha:0.08),
      child: Icon(
        (node['node_type'] ?? '').toString().toLowerCase() == 'subintent' ? Icons.favorite_border : Icons.label_outline,
        size: 16,
        color: accent,
      ),
    );

    Widget trailing;
    if (loading) {
      trailing = const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      trailing = childrenAsync.when(
        data: (children) {
          if (children.isEmpty) return const SizedBox(width: 8);
          return IconButton(
            key: ValueKey('chev_$nodeKey'),
            icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: Colors.grey.shade700),
            onPressed: () => _expandOrCollapse(node),
            splashRadius: 20,
          );
        },
        loading: () => const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, _) => const SizedBox(width: 8),
      );
    }

    return Container(
      key: ValueKey(nodeKey), // important: preserve widget identity across rebuilds
      margin: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha:0.03),
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleSelectionLocallyThenPersist(node),
            borderRadius: BorderRadius.circular(12.0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  smallIcon,
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                  trailing,
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 64.0, end: 12.0, bottom: 8.0),
              child: _buildChildrenList(nodeKey, profile),
            ),
        ],
      ),
    );
  }

  Widget _buildChildrenList(String parentKey, UserProfile? profile) {
    final childrenAsync = ref.watch(fetchChildrenProvider(parentKey));
    if (parentKey.isEmpty) return const SizedBox.shrink();

    return childrenAsync.when(
      data: (children) {
        if (children.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(ref.read(localizationProvider).getString('profileNotSet'), style: TextStyle(color: Theme.of(context).disabledColor)),
          );
        }
        return Column(children: children.map((c) => _buildRow(c, profile)).toList());
      },
      loading: () => const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 8.0), child: CircularProgressIndicator())),
      error: (e, s) {
        return Center(child: Text(ref.read(localizationProvider).getString('generalError')));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isRtl = l10n.textDirection == ui.TextDirection.rtl;

    // Note: we read provider here for initial fallback and occasional refreshes only;
    // the UI checked state comes primarily from _localSelected* sets to stay snappy.
    final UserProfile? profile = ref.watch(profileEditProvider(widget.userId)).asData?.value;

    // Use the new provider for relevant interests (if interests are displayed in this screen)
    // final relevantInterests = ref.watch(interestsForSelectedIntentsProvider(selectedIntents)); // TODO: Implement this provider if needed

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.rootLabel),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: handleBack,
          ),
        ),
        body: SafeArea(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fetchChildrenTryBoth(widget.rootId, widget.rootNodeKey),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final roots = snap.data ?? [];
              if (roots.isEmpty) return Center(child: Text(l10n.getString('profileNotFound')));
              // If you want to display interests, use relevantInterests here
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                children: roots.map((r) => _buildRow(r, profile)).toList(),
              );
            },
          ),
        ),
      ),
    );
  }
}
