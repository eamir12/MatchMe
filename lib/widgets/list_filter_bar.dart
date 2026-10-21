// lib/widgets/list_filter_bar.dart
//
// Shared search + filter UI for the Chats, Matches and Events screens.
//
// Design notes
// ------------
// Every filter lives behind one filter button. Nothing filter-related is
// exposed on the list itself except the result count, because two stacked
// horizontal chip rows failed badly:
//
//   * intents are an open-ended set (they come from app_intents), so a
//     horizontal scroller silently hid options with no affordance;
//   * both rows had their own "All" chip, which is ambiguous with two on
//     screen at once;
//   * "Unread only" — a toggle — was mixed in with the intent chips.
//
// The sheet fixes all three: a Wrap for the open set, a segmented group for the
// closed one, a Switch for the toggle, and a single place to read and clear the
// state. Match type is a closed set of three, so it gets three rich cards
// rather than chips; intents keep their per-intent brand colours because those
// are already the app's visual vocabulary (romantic pink, friendship green,
// activity blue, business violet).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:matchme/utils/string_extensions.dart';

/// The two match bases a user can filter by, plus "no filter".
enum MatchTypeFilter {
  all,
  proximity,
  event;

  /// Whether a record with this [rawMatchType] passes the filter.
  bool matches(String? rawMatchType) {
    if (this == MatchTypeFilter.all) return true;
    final type = (rawMatchType ?? '').trim().toLowerCase();
    switch (this) {
      case MatchTypeFilter.all:
        return true;
      case MatchTypeFilter.proximity:
        // `co_motion` is proximity matching: both people were moving through
        // the same place at the same time. It belongs with proximity, not
        // event, otherwise a genuinely nearby person is hidden by the filter.
        return type == 'proximity' || type == 'co_motion';
      case MatchTypeFilter.event:
        return type == 'event';
    }
  }

  String labelKey(LocalizationState l10n) {
    switch (this) {
      case MatchTypeFilter.all:
        return 'generalAll';
      case MatchTypeFilter.proximity:
        return 'matchTypeFilterProximity';
      case MatchTypeFilter.event:
        return 'matchTypeFilterEvent';
    }
  }

  IconData get icon {
    switch (this) {
      case MatchTypeFilter.all:
        return Icons.tune_rounded;
      case MatchTypeFilter.proximity:
        return Icons.near_me_rounded;
      case MatchTypeFilter.event:
        return Icons.celebration_rounded;
    }
  }

  /// Accent used for this option's card. Deliberately distinct from the intent
  /// brand colours so the two sections never read as one scale.
  ///
  /// Tuned per brightness: the accent is also used as a text/icon colour on
  /// the card's own tinted wash, so dark mode uses light tones and light mode
  /// uses dark tones to keep that text legible (WCAG AA).
  Color accentFor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (this) {
      case MatchTypeFilter.all:
        return isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);
      case MatchTypeFilter.proximity:
        return isDark ? const Color(0xFF7DD3FC) : const Color(0xFF075985);
      case MatchTypeFilter.event:
        return isDark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9);
    }
  }

  String get blurbKey {
    switch (this) {
      case MatchTypeFilter.all:
        return 'matchTypeFilterAllBlurb';
      case MatchTypeFilter.proximity:
        return 'matchTypeFilterProximityBlurb';
      case MatchTypeFilter.event:
        return 'matchTypeFilterEventBlurb';
    }
  }

  /// Whether this filter can be evaluated at all.
  ///
  /// If the backend has not yet delivered a match type, filtering by proximity
  /// or event would hide everything, which reads as data loss rather than as a
  /// filter. In that case the section is not shown.
  static bool canFilter(List<String> knownRawTypes) {
    return knownRawTypes.any((t) {
      final v = t.trim().toLowerCase();
      return v == 'proximity' || v == 'co_motion' || v == 'event';
    });
  }
}

/// Sort orders available to a list screen.
///
/// Chats and Matches each offer a subset, but they share this enum, one chip
/// style and one section so the two screens feel like the same control. Adding
/// an option to one screen and not the other is how the two drift apart.
enum ListSortOption {
  /// Most recent first: newest match, or most recently active chat.
  recent,
  /// Conversations with unread messages float to the top. Chats only.
  unreadFirst,
  /// Alphabetical by the other person's display name. Both.
  nameAsc,
  /// Most shared interests in common. Matches only.
  sharedInterests,
  /// Highest rated. Matches only.
  topRated,
  /// Closest to expiring. Matches only.
  expiringSoon;

  String labelKey(LocalizationState l10n) {
    switch (this) {
      case ListSortOption.recent:
        return 'sortNewest';
      case ListSortOption.unreadFirst:
        return 'sortUnreadFirst';
      case ListSortOption.nameAsc:
        return 'sortNameAsc';
      case ListSortOption.sharedInterests:
        return 'sortSharedInterests';
      case ListSortOption.topRated:
        return 'sortTopRated';
      case ListSortOption.expiringSoon:
        return 'sortExpiringSoon';
    }
  }

  IconData get icon {
    switch (this) {
      case ListSortOption.recent:
        return Icons.schedule_rounded;
      case ListSortOption.unreadFirst:
        return Icons.mark_chat_unread_rounded;
      case ListSortOption.nameAsc:
        return Icons.sort_by_alpha_rounded;
      case ListSortOption.sharedInterests:
        return Icons.interests_rounded;
      case ListSortOption.topRated:
        return Icons.star_rounded;
      case ListSortOption.expiringSoon:
        return Icons.timer_outlined;
    }
  }

  /// Whether this is the screen's default order, in which case it is not
  /// counted as an active change and needs no summary pill.
  bool get isDefault => this == ListSortOption.recent;
}

/// The complete filter + sort state for a list screen.
class ListFilterState {
  const ListFilterState({
    this.selectedIntentKey,
    this.matchType = MatchTypeFilter.all,
    this.extraToggleLabel,
    this.extraToggleKey,
    this.extraToggleActive = false,
    this.sort = ListSortOption.recent,
  });

  final String? selectedIntentKey;
  final MatchTypeFilter matchType;

  /// Optional secondary toggle shown in the sheet, e.g. "Unread only" on Chats.
  final String? extraToggleLabel;
  final String? extraToggleKey;
  final bool extraToggleActive;

  final ListSortOption sort;

  /// Filters that narrow the list. Sorting is deliberately excluded: changing
  /// the order is not a narrowing, and a filter sheet that counts itself would
  /// badge the icon for a preference the user did not "apply".
  int get activeCount {
    var n = 0;
    if (selectedIntentKey != null && selectedIntentKey!.isNotEmpty) n++;
    if (matchType != MatchTypeFilter.all) n++;
    if (extraToggleActive) n++;
    return n;
  }

  /// True when anything — including the sort order — differs from the
  /// screen's defaults. Drives the "Clear" affordance.
  bool get isPristine => activeCount == 0 && sort.isDefault;

  ListFilterState copyWith({
    String? selectedIntentKey,
    bool clearIntent = false,
    MatchTypeFilter? matchType,
    String? extraToggleLabel,
    String? extraToggleKey,
    bool? extraToggleActive,
    ListSortOption? sort,
  }) {
    return ListFilterState(
      selectedIntentKey: clearIntent
          ? null
          : (selectedIntentKey ?? this.selectedIntentKey),
      matchType: matchType ?? this.matchType,
      extraToggleLabel: extraToggleLabel ?? this.extraToggleLabel,
      extraToggleKey: extraToggleKey ?? this.extraToggleKey,
      extraToggleActive: extraToggleActive ?? this.extraToggleActive,
      sort: sort ?? this.sort,
    );
  }
}

// ---------------------------------------------------------------------------
// Texture
// ---------------------------------------------------------------------------

/// A very low-contrast grain, drawn once from a fixed seed.
///
/// Flat fills read as cheap at large sizes; a faint grain stops large tinted
/// panels from looking like flat plastic. The dot offsets are generated once
/// from a seeded [math.Random] and the painter reports `shouldRepaint =>
/// false`, so this costs a single pass and never re-runs on rebuild.
class GrainPainter extends CustomPainter {
  GrainPainter({this.opacity = 0.035, this.seed = 7});

  final double opacity;
  final int seed;

  static List<Offset> _dotsFor(int seed) {
    final rng = math.Random(seed);
    return List<Offset>.generate(160, (_) {
      return Offset(rng.nextDouble(), rng.nextDouble());
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    const r = 0.7;
    for (final d in _dotsFor(seed)) {
      canvas.drawCircle(
        Offset(d.dx * size.width, d.dy * size.height),
        r,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant GrainPainter old) =>
      old.opacity != opacity || old.seed != seed;
}

/// Paints [child] over a tinted gradient with a grain on top.
class TexturedPanel extends StatelessWidget {
  const TexturedPanel({
    super.key,
    required this.child,
    this.colors,
    this.borderColor,
    this.grainOpacity = 0.035,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final Widget child;
  final List<Color>? colors;
  final Color? borderColor;
  final double grainOpacity;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gradient = colors ??
        <Color>[
          scheme.primary.withValues(alpha: 0.16),
          scheme.tertiary.withValues(alpha: 0.08),
        ];

    return ClipRRect(
      borderRadius: borderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: gradient,
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
          ),
          border: Border.all(
            color: borderColor ?? scheme.primary.withValues(alpha: 0.20),
          ),
          borderRadius: borderRadius,
        ),
        child: Stack(
          children: [
            if (grainOpacity > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: GrainPainter(opacity: grainOpacity),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: padding,
              // A transparent Material so any Material-typed child inside
              // (ListTile, SwitchListTile, InkWell) has a Material ancestor.
              // Without it Flutter asserts "ListTile background color or ink
              // splashes may be invisible" in debug builds.
              child: Material(
                type: MaterialType.transparency,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The list-facing bar
// ---------------------------------------------------------------------------

/// Search field plus the single filter button that owns every filter.
class ListSearchBar extends StatefulWidget {
  const ListSearchBar({
    super.key,
    required this.controller,
    required this.onQueryChanged,
    required this.onOpenFilters,
    required this.l10n,
    required this.activeFilterCount,
    required this.hintKey,
    this.onClearQuery,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 4),
  });

  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onOpenFilters;
  final LocalizationState l10n;
  final int activeFilterCount;
  final String hintKey;
  final VoidCallback? onClearQuery;
  final EdgeInsetsGeometry padding;

  @override
  State<ListSearchBar> createState() => _ListSearchBarState();
}

class _ListSearchBarState extends State<ListSearchBar> {
  bool _isEmpty = true;
  bool _isRtl = false;

  @override
  void initState() {
    super.initState();
    _syncWithController();
    widget.controller.addListener(_syncWithController);
  }

  @override
  void didUpdateWidget(covariant ListSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncWithController);
      _syncWithController();
      widget.controller.addListener(_syncWithController);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWithController);
    super.dispose();
  }

  void _syncWithController() {
    final text = widget.controller.text;
    final isEmpty = text.trim().isEmpty;
    final isRtl = !isEmpty && text.trimLeft().isRtlByFirstStrongChar();
    if (isEmpty == _isEmpty && isRtl == _isRtl) return;
    setState(() {
      _isEmpty = isEmpty;
      _isRtl = isRtl;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final l10n = widget.l10n;

    return Padding(
      padding: widget.padding,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: TextField(
                controller: controller,
                onChanged: widget.onQueryChanged,
                // The search field must never grab focus on its own: after a
                // swipe-down dismiss of the filter sheet the cursor would
                // otherwise land here and pop the keyboard.
                autofocus: false,
                textInputAction: TextInputAction.search,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                // Empty: follow the UI direction so the hint aligns with the
                // locale. Typing: follow the typed text (same as the chat
                // composer) so Hebrew aligns right and English/Spanish left.
                textDirection: _isEmpty
                    ? Directionality.of(context)
                    : (_isRtl ? TextDirection.rtl : TextDirection.ltr),
                textAlign: _isEmpty
                    ? TextAlign.start
                    : (_isRtl ? TextAlign.right : TextAlign.left),
                decoration: InputDecoration(
                  hintText: l10n.getString(widget.hintKey),
                  prefixIcon: const Icon(Icons.search, size: 21),
                  suffixIcon: _isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.getString('generalClear'),
                          onPressed: () {
                            widget.onClearQuery?.call();
                            widget.onQueryChanged('');
                          },
                          icon: const Icon(Icons.close, size: 19),
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _FilterButton(
            activeCount: widget.activeFilterCount,
            tooltip: l10n.getString('listFiltersTitle'),
            activeLabel: l10n.getString(
              'listFilterActiveCount',
              params: {'count': '${widget.activeFilterCount}'},
            ),
            onPressed: widget.onOpenFilters,
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.activeCount,
    required this.tooltip,
    required this.activeLabel,
    required this.onPressed,
  });

  final int activeCount;
  final String tooltip;

  /// The accessibility label for the active state, e.g. "2 active".
  final String activeLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = activeCount > 0;

    return Semantics(
      button: true,
      label: active ? '$tooltip, $activeLabel' : tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(18),
            child: Ink(
              decoration: BoxDecoration(
                gradient: active
                    ? LinearGradient(
                        colors: [
                          scheme.primary,
                          scheme.tertiary,
                        ],
                        begin: AlignmentDirectional.topStart,
                        end: AlignmentDirectional.bottomEnd,
                      )
                    : null,
                color: active
                    ? null
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: active
                      ? Colors.transparent
                      : scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: SizedBox(
                height: 48,
                width: 52,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    if (active)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: CustomPaint(
                            painter: GrainPainter(opacity: 0.05),
                          ),
                        ),
                      ),
                    Icon(
                      Icons.tune_rounded,
                      size: 22,
                      color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                    if (active)
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          constraints: const BoxConstraints(minWidth: 18),
                          decoration: BoxDecoration(
                            color: scheme.onPrimary,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$activeCount',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.3,
                              fontWeight: FontWeight.w800,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The sheet
// ---------------------------------------------------------------------------

Future<ListFilterState?> showListFilterSheet({
  required BuildContext context,
  required ListFilterState initial,
  required LocalizationState l10n,
  required List<String> intentKeys,
  required List<dynamic> allIntents,
  required int Function(ListFilterState) resultCountFor,
  bool showMatchType = false,
  List<ListSortOption> sortOptions = const [],
}) async {
  // Drop focus from the list's search field before the sheet opens: without
  // this the keyboard stays up behind the sheet, and a swipe-down dismiss
  // hands focus (and the keyboard) back to the search field.
  FocusScope.of(context).unfocus();
  final result = await showModalBottomSheet<ListFilterState>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _FilterSheet(
      initial: initial,
      l10n: l10n,
      intentKeys: intentKeys,
      allIntents: allIntents,
      resultCountFor: resultCountFor,
      showMatchType: showMatchType,
      sortOptions: sortOptions,
    ),
  );
  // Swiping the sheet down to dismiss must not put the cursor back in the
  // search field: keep focus cleared when the sheet goes away however it
  // was closed (apply, tap-outside, or swipe-down).
  if (context.mounted) {
    FocusScope.of(context).unfocus();
  }
  return result;
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.l10n,
    required this.intentKeys,
    required this.allIntents,
    required this.resultCountFor,
    required this.showMatchType,
    required this.sortOptions,
  });

  final ListFilterState initial;
  final LocalizationState l10n;
  final List<String> intentKeys;
  final List<dynamic> allIntents;
  final int Function(ListFilterState) resultCountFor;
  final bool showMatchType;
  final List<ListSortOption> sortOptions;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late ListFilterState _draft = widget.initial;

  List<IntentFilterOption> _options() {
    return widget.intentKeys
        .map(
          (key) => getIntentFilterOption(
            key,
            widget.l10n,
            widget.allIntents.cast(),
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final scheme = Theme.of(context).colorScheme;
    final options = _options();
    final resultCount = widget.resultCountFor(_draft);
    final intentOption = _draft.selectedIntentKey == null
        ? null
        : options
              .where((o) => o.key == _draft.selectedIntentKey)
              .firstOrNull;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header: title, active count, clear, and removable summary
              // pills so the current state is readable at a glance.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('listFiltersTitle'),
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        // Shown once there is something to clear. Uses
                        // isPristine rather than activeCount so a
                        // sort-only change also reveals it.
                        if (!_draft.isPristine)
                          TextButton.icon(
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              setState(
                                () => _draft = ListFilterState(
                                  matchType: MatchTypeFilter.all,
                                  extraToggleLabel:
                                      widget.initial.extraToggleLabel,
                                  extraToggleKey:
                                      widget.initial.extraToggleKey,
                                ),
                              );
                            },
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: Text(l10n.getString('generalClear')),
                          ),
                      ],
                    ),
                    if (_draft.activeCount > 0 || !_draft.sort.isDefault) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_draft.matchType != MatchTypeFilter.all)
                            _RemovablePill(
                              label: l10n.getString(
                                _draft.matchType.labelKey(l10n),
                              ),
                              icon: _draft.matchType.icon,
                              color: _draft.matchType.accentFor(context),
                              onRemoved: () => setState(
                                () => _draft = _draft.copyWith(
                                  matchType: MatchTypeFilter.all,
                                ),
                              ),
                            ),
                          if (intentOption != null)
                            _RemovablePill(
                              label: intentOption.label,
                              icon: intentOption.icon,
                              color: intentOption.color,
                              onRemoved: () => setState(
                                () => _draft = _draft.copyWith(
                                  clearIntent: true,
                                ),
                              ),
                            ),
                        if (_draft.extraToggleActive &&
                            (_draft.extraToggleLabel?.isNotEmpty ??
                                  false))
                            _RemovablePill(
                              label: _draft.extraToggleLabel!,
                              icon: Icons.bolt_rounded,
                              // Lifted in dark mode: the pill paints its label
                              // in this colour on a 14% wash of itself.
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? const Color(0xFFFDA4AF)
                                  : const Color(0xFFBE123C),
                              onRemoved: () => setState(
                                () => _draft = _draft.copyWith(
                                  extraToggleActive: false,
                                ),
                              ),
                            ),
                        // A non-default sort is shown so the order is never a
                        // silent state, but it is not part of activeCount — the
                        // user changed a preference, they did not narrow the
                        // list.
                        if (!_draft.sort.isDefault)
                          _RemovablePill(
                            label: l10n.getString(
                              _draft.sort.labelKey(l10n),
                            ),
                            icon: _draft.sort.icon,
                            // Lifted in dark mode; the pill paints its label
                            // in this colour on a 14% wash of itself.
                            color:
                                Theme.of(context).brightness ==
                                    Brightness.dark
                                ? const Color(0xFF2DD4BF)
                                : const Color(0xFF0F766E),
                            onRemoved: () => setState(
                              () => _draft = _draft.copyWith(
                                sort: ListSortOption.recent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  // Dragging the sheet content dismisses the keyboard instead
                  // of moving focus into the search field behind it.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.showMatchType) ...[
                        _SectionLabel(label: l10n.getString('matchTypeFilterLabel')),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            for (final option in MatchTypeFilter.values) ...[
                              Expanded(
                                child: _MatchTypeCard(
                                  option: option,
                                  l10n: l10n,
                                  selected: _draft.matchType == option,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(
                                      () => _draft = _draft.copyWith(
                                        matchType: option,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              if (option != MatchTypeFilter.values.last)
                                const SizedBox(width: 8),
                            ],
                          ],
                        ),
                        const SizedBox(height: 22),
                      ],
                      if (options.isNotEmpty) ...[
                        _SectionLabel(
                          label: l10n.getString('listFilterInterestSection'),
                        ),
                        const SizedBox(height: 10),
                        // Wrap, not a horizontal scroller: an open-ended list
                        // must never hide options.
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final option in options)
                              _IntentChip(
                                label: option.label,
                                icon: option.icon,
                                color: option.color,
                                selected:
                                    _draft.selectedIntentKey == option.key,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  final isSelected =
                                      _draft.selectedIntentKey == option.key;
                                  setState(
                                    () => _draft = _draft.copyWith(
                                      selectedIntentKey: isSelected
                                          ? null
                                          : option.key,
                                      clearIntent: isSelected,
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 22),
                      ],
                      if (_draft.extraToggleKey != null) ...[
                        _SectionLabel(
                          label: l10n.getString('listFilterOptionsSection'),
                        ),
                        const SizedBox(height: 4),
                        TexturedPanel(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 2,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          colors: [
                            scheme.tertiary.withValues(alpha: 0.12),
                            scheme.primary.withValues(alpha: 0.06),
                          ],
                          child: SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            value: _draft.extraToggleActive,
                            title: Text(
                              _draft.extraToggleLabel ?? '',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onChanged: (v) {
                              HapticFeedback.selectionClick();
                              setState(
                                () => _draft = _draft.copyWith(
                                  extraToggleActive: v,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                      // Sort last: the sections above answer "which", this one
                      // answers "in what order". Same chip shape as the intent
                      // chips so the sheet reads as one control.
                      if (widget.sortOptions.length > 1) ...[
                        _SectionLabel(label: l10n.getString('listSortSection')),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final option in widget.sortOptions)
                              _SortChip(
                                label: l10n.getString(option.labelKey(l10n)),
                                icon: option.icon,
                                selected: _draft.sort == option,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(
                                    () => _draft = _draft.copyWith(
                                      sort: option,
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Sticky apply: the list does not change until this is pressed.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(_draft),
                      borderRadius: BorderRadius.circular(16),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [scheme.primary, scheme.tertiary],
                            begin: AlignmentDirectional.topStart,
                            end: AlignmentDirectional.bottomEnd,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: CustomPaint(
                                  painter: GrainPainter(opacity: 0.05),
                                ),
                              ),
                            ),
                            Text(
                              l10n.getString('listFilterShowResults', params: {
                                'count': '$resultCount',
                              }),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.9,
      ),
    );
  }
}

/// One of the three match-type cards. A closed set of three reads better as
/// cards with an icon and a one-line blurb than as chips.
class _MatchTypeCard extends StatelessWidget {
  const _MatchTypeCard({
    required this.option,
    required this.l10n,
    required this.selected,
    required this.onTap,
  });

  final MatchTypeFilter option;
  final LocalizationState l10n;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = option.accentFor(context);
    // Dark-mode accents are light tones, so a white icon on the accent fill
    // would disappear; pick the foreground from the accent's own brightness.
    final onAccent =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : const Color(0xFF0F172A);

    return Semantics(
      button: true,
      selected: selected,
      label: l10n.getString(option.labelKey(l10n)),
      child: TexturedPanel(
        borderRadius: BorderRadius.circular(16),
        borderColor: selected ? accent : scheme.outlineVariant,
        colors: selected
            ? [accent.withValues(alpha: 0.22), accent.withValues(alpha: 0.08)]
            : [
                scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                scheme.surfaceContainerHighest.withValues(alpha: 0.18),
              ],
        grainOpacity: selected ? 0.05 : 0.02,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: selected
                      ? accent
                      : accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  option.icon,
                  size: 18,
                  color: selected ? onAccent : accent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.getString(option.labelKey(l10n)),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? accent : scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.getString(option.blurbKey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.25,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntentChip extends StatelessWidget {
  const _IntentChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The intent palette is mid-tone, so white labels on the selected fill
    // fall short of 4.5:1; pick the label colour from the fill's brightness.
    final onColor = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : const Color(0xFF0F172A);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: selected
                    ? color
                    : color.withValues(alpha: 0.28),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: selected ? onColor : color),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? onColor : color,
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: onColor.withValues(alpha: 0.9),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An active filter shown in the sheet header, tappable to remove it.
class _RemovablePill extends StatelessWidget {
  const _RemovablePill({
    required this.label,
    required this.icon,
    required this.color,
    required this.onRemoved,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label, remove filter',
      child: Material(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onRemoved,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 6, 8, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.close_rounded, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sort chip. Same geometry as the intent chips so the sheet has one chip
/// language, but neutral-toned: sort is a preference, not a category, so it
/// should not borrow the intent brand colours.
class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const accent = Color(0xFF0F766E);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? accent : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: selected ? accent : scheme.outlineVariant,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? Colors.white : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? Colors.white : scheme.onSurface,
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "12 of 34" — makes filtering legible rather than mysterious.
class ResultCountLabel extends StatelessWidget {
  const ResultCountLabel({
    super.key,
    required this.shown,
    required this.total,
    required this.l10n,
    this.padding = const EdgeInsets.fromLTRB(18, 2, 16, 8),
    this.countKey = 'listFilterResultCount',
    this.countOfKey = 'listFilterResultCountOf',
  });

  final int shown;
  final int total;
  final LocalizationState l10n;
  final EdgeInsetsGeometry padding;
  final String countKey;
  final String countOfKey;

  @override
  Widget build(BuildContext context) {
    final isFiltered = shown != total;
    return Padding(
      padding: padding,
      child: Semantics(
        liveRegion: true,
        child: Text(
          isFiltered
              ? l10n.getString(
                  countOfKey,
                  params: {
                    'shown': '$shown',
                    'total': '$total',
                  },
                  // The noun agrees with the total ("1 of 5 conversations").
                  pluralParam: 'total',
                )
              : l10n.getString(countKey, params: {
                  'count': '$shown',
                }),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
