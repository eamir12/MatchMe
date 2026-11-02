// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme_admin/services/admin_local_db_service.dart';
import 'package:matchme_admin/widgets/safe_text.dart';

class _TaxonomyResolver {
  static Map<String, String>? _intentKeyToTranslation;
  static Map<String, String>? _interestKeyToTranslation;
  static Map<String, String>? _categoryKeyToTranslation;
  static DateTime? _lastLoad;
  static const Duration _ttl = Duration(minutes: 5);

  static void _ensureLoadedSync() {
    final now = DateTime.now();
    if (_intentKeyToTranslation != null &&
        _lastLoad != null &&
        now.difference(_lastLoad!) < _ttl)
      return;
    try {
      final intents = AdminLocalDbService.shared.loadSectionDataSync('intents');
      final interests = AdminLocalDbService.shared.loadSectionDataSync(
        'interests',
      );
      if (intents.isEmpty && interests.isEmpty) {
        // No cached data yet (e.g., first launch before sync) — keep null so next call retries immediately
        return;
      }
      final iMap = <String, String>{};
      for (final row in intents) {
        final k = (row['key'] ?? '').toString();
        final tk = (row['translation_key'] ?? '').toString();
        if (k.isNotEmpty && tk.isNotEmpty) iMap[k] = tk;
      }
      final interestMap = <String, String>{};
      final catMap = <String, String>{};
      for (final row in interests) {
        final k = (row['key'] ?? '').toString();
        final tk = (row['translation_key'] ?? '').toString();
        if (k.isEmpty || tk.isEmpty) continue;
        interestMap[k] = tk;
        final parentId = row['parent_id'];
        final isTopLevel = parentId == null;
        if (isTopLevel) catMap[k] = tk;
      }
      _intentKeyToTranslation = iMap;
      _interestKeyToTranslation = interestMap;
      _categoryKeyToTranslation = catMap;
      _lastLoad = now;
    } catch (_) {}
  }

  static String? intentTranslationKey(String rawKey) {
    _ensureLoadedSync();
    return _intentKeyToTranslation?[rawKey];
  }

  static String? interestTranslationKey(String rawKey) {
    _ensureLoadedSync();
    return _interestKeyToTranslation?[rawKey];
  }

  static String? categoryTranslationKey(String rawKey) {
    _ensureLoadedSync();
    return _categoryKeyToTranslation?[rawKey];
  }
}

// ---------- Localization & Formatting Helpers ----------
String _prettySentence(String raw) {
  if (raw.trim().isEmpty) return '';
  var s = raw.replaceAll('::', ' ').replaceAll('_', ' ').trim().toLowerCase();
  if (s.isEmpty) return '';
  s = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  if (s.isEmpty) return '';
  return s[0].toUpperCase() + s.substring(1);
}

bool _isMissing(String value, String key) {
  if (value.trim().isEmpty) return true;
  if (value == key) return true;
  if (value == '$key...') return true;
  return false;
}

String _tryKeys(
  List<String> keys,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t, {
  String? fallback,
}) {
  for (final k in keys) {
    final v = t(k);
    if (!_isMissing(v, k)) return v;
  }
  return fallback ?? '';
}

String _localizeIntent(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  // First, try the authoritative translation_key from the taxonomy tables (shared DB).
  // This mirrors the main app's _resolveDisplayLabel which uses allIntentsMap[key] -> translation_key.
  final tk = _TaxonomyResolver.intentTranslationKey(trimmed);
  if (tk != null && tk.isNotEmpty) {
    final viaTk = t(tk);
    if (!_isMissing(viaTk, tk)) return viaTk;
  }
  final pascal = trimmed
      .split('_')
      .map(
        (w) =>
            w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join('');
  final candidates = <String>[
    trimmed,
    'intent.$trimmed',
    'intentCategory$pascal',
    'intent.category.$trimmed',
  ];
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(trimmed);
}

IconData _intentIcon(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('romantic') ||
      lower.contains('date') ||
      lower.contains('dating')) {
    return Icons.favorite_rounded;
  }
  if (lower.contains('friend') || lower.contains('social')) {
    return Icons.people_alt_rounded;
  }
  if (lower.contains('business') ||
      lower.contains('network') ||
      lower.contains('career')) {
    return Icons.business_center_rounded;
  }
  if (lower.contains('activity') || lower.contains('sport')) {
    return Icons.sports_soccer_rounded;
  }
  return Icons.category_rounded;
}

String _localizeSubIntent(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  // Primary: use authoritative translation_key from taxonomy table if available.
  // This ensures admin and main app resolve to the identical translation key,
  // regardless of how the key is namespaced (e.g., business_networking::women_in_business
  // -> intent.business.women_in_business).
  final tk = _TaxonomyResolver.intentTranslationKey(trimmed);
  if (tk != null && tk.isNotEmpty) {
    final viaTk = t(tk);
    if (!_isMissing(viaTk, tk)) return viaTk;
  }
  // Also try resolving the sub-part alone via the map (covers edge where stored key
  // is already normalized without prefix).
  if (trimmed.contains('::')) {
    final subOnly = trimmed.split('::').last;
    final tkSub = _TaxonomyResolver.intentTranslationKey(subOnly);
    if (tkSub != null && tkSub.isNotEmpty) {
      final viaSub = t(tkSub);
      if (!_isMissing(viaSub, tkSub)) return viaSub;
    }
  }
  final dotVersion = trimmed.replaceAll('::', '.');
  // Build a rich candidate list that covers DB's actual translation_key patterns.
  // DB maps:
  //   business_networking::X -> intent.business.X (not intent.business_networking.X)
  //   activity_partner::X    -> intent.activity.X
  //   romantic::X            -> intent.romantic.X  (same)
  //   friendship::X          -> intent.friendship.X (same)
  // We try both the literal and the canonical ("business" / "activity") variants.
  final candidates = <String>[trimmed, 'intent.$dotVersion', dotVersion];
  if (trimmed.contains('::')) {
    final parts = trimmed.split('::');
    final intent = parts[0];
    final sub = parts.sublist(1).join('::');
    final subDot = sub.replaceAll('::', '.');
    // literal intent prefix
    candidates.add('intent.$intent.$sub');
    candidates.add('intent.$intent.$subDot');
    // canonical prefix remapping (business_networking -> business, activity_partner -> activity)
    String? canonical;
    if (intent == 'business_networking') {
      canonical = 'business';
    } else if (intent == 'activity_partner') {
      canonical = 'activity';
    }
    if (canonical != null) {
      candidates.add('intent.$canonical.$sub');
      candidates.add('intent.$canonical.$subDot');
    }
    // also try without the intent prefix, as some translations are stored without it
    // (fallback already handles, but add canonical sub-only for completeness)
    final hit = _tryKeys(candidates, t);
    if (hit.isNotEmpty) return hit;
    return _prettySentence(sub);
  }
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(trimmed);
}

String _localizeGender(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final candidates = <String>['gender_$trimmed', 'gender.$trimmed', trimmed];
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  final withHyphen = trimmed.replaceAll('_', '-');
  return _prettySentence(
    withHyphen,
  ).replaceAll(' -', '-').replaceAll('- ', '-');
}

String _localizeIntentList(
  List<String> raws,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) => raws
    .map((r) => _localizeIntent(r, t))
    .where((s) => s.isNotEmpty)
    .join(', ');

bool _isRtlText(String text) {
  bool isStrongRtl(int rune) =>
      (rune >= 0x0590 && rune <= 0x08FF) || (rune >= 0xFB1D && rune <= 0xFEFC);
  bool isStrongLtr(int rune) =>
      (rune >= 0x0041 && rune <= 0x005A) || (rune >= 0x0061 && rune <= 0x007A);
  for (final r in text.runes) {
    if (isStrongRtl(r)) return true;
    if (isStrongLtr(r)) return false;
  }
  return false;
}

String _localizeMatchType(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final pascal = trimmed
      .split('_')
      .map(
        (w) =>
            w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join('');
  final candidates = <String>[
    'matchType$pascal',
    'matchInspectorMatchType$pascal',
    'match_type.$trimmed',
    'match.type.$trimmed',
    trimmed,
  ];
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(trimmed);
}

String _pascal(String s) {
  if (s.isEmpty) return '';
  final parts = s.split(RegExp(r'[_\s\-]+'));
  return parts
      .map(
        (w) =>
            w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join();
}

String _localizeFilterValue(
  String raw,
  String key,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final lower = raw.trim().toLowerCase();
  if (lower.isEmpty || lower == 'any' || lower == '[]') {
    final anyHit = _tryKeys(
      ['matchInspectorUnrestricted', 'any', 'generalAny'],
      t,
      fallback: 'Any',
    );
    return anyHit;
  }
  if (lower == 'true' || lower == 'yes') {
    final yesHit = _tryKeys(
      ['yes', 'generalYes', 'settingsWantsChildrenYes'],
      t,
      fallback: 'Yes',
    );
    return yesHit;
  }
  if (lower == 'false' || lower == 'no') {
    final noHit = _tryKeys(
      ['no', 'generalNo', 'settingsWantsChildrenNo'],
      t,
      fallback: 'No',
    );
    return noHit;
  }
  final pascalLower = _pascal(lower);
  final pascalKey = _pascal(key);
  final candidates = <String>[
    '${key}_$lower',
    '$key.$lower',
    'filter_${key}_$lower',
    'lifestyle$pascalKey$pascalLower',
    'lifestyle$pascalLower',
    'settings$pascalKey$pascalLower',
    'settings$pascalLower',
    'profileLifestyle$pascalKey',
    'profileLifestyle$pascalLower',
    'family$pascalLower',
    'religion$pascalLower',
    // specific known patterns
    'lifestyleSmoking$pascalLower',
    'lifestyleDrinking$pascalLower',
    'lifestyleExercise$pascalLower',
    'lifestyleDiet$pascalLower',
    'settingsSmoking$pascalLower',
    'settingsDrinking$pascalLower',
    'settingsExercise$pascalLower',
    'settingsDiet$pascalLower',
    'settingsHasChildren$pascalLower',
    'settingsWantsChildren$pascalLower',
    lower,
    raw,
  ];
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(raw);
}

String _localizeDomainType(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final lower = raw.trim().toLowerCase();
  if (lower == 'personal') {
    final hit = _tryKeys([
      'matchInspectorPersonalInterests',
      'personalInterests',
    ], t);
    if (hit.isNotEmpty) return hit;
  } else if (lower == 'business') {
    final hit = _tryKeys([
      'matchInspectorBusinessInterests',
      'businessInterests',
    ], t);
    if (hit.isNotEmpty) return hit;
  } else if (lower == 'merged') {
    final hit = _tryKeys([
      'matchInspectorInterests',
      'matchInspectorReasonInterests',
    ], t);
    if (hit.isNotEmpty) return hit;
  }
  final pretty = _prettySentence(raw);
  // try generic domain translation if exists
  final hit = _tryKeys(['domain.$lower', 'interest.domain.$lower'], t);
  if (hit.isNotEmpty) return hit;
  return pretty;
}

String _localizeInterestCategory(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  // Primary: authoritative translation_key from interests taxonomy (shared DB)
  final tk =
      _TaxonomyResolver.categoryTranslationKey(trimmed) ??
      _TaxonomyResolver.interestTranslationKey(trimmed);
  if (tk != null && tk.isNotEmpty) {
    final viaTk = t(tk);
    if (!_isMissing(viaTk, tk)) return viaTk;
  }
  final lower = trimmed.toLowerCase();
  final candidates = <String>[
    'interest.$lower',
    'interest.$trimmed',
    lower,
    trimmed,
    'interest_category.$lower',
    'interest_category.$trimmed',
    // DB sometimes stores categories with the interest_category prefix
    // but UI language files use interest.<category> — try both.
    // Also try title-cased and with underscores preserved.
  ];
  // Try additional casing variants for robustness (e.g., business_events vs Business_Events)
  final camel = lower
      .split('_')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
      .join('');
  candidates.add('interestCategory$camel');
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(trimmed);
}

String _localizeInterestSub(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t, {
  String? category,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  // Primary: authoritative translation_key from interests taxonomy (shared DB)
  final tk = _TaxonomyResolver.interestTranslationKey(trimmed);
  if (tk != null && tk.isNotEmpty) {
    final viaTk = t(tk);
    if (!_isMissing(viaTk, tk)) return viaTk;
  }
  final lower = trimmed.toLowerCase().replaceAll(' ', '_');
  final catLower = category?.trim().toLowerCase().replaceAll(' ', '_') ?? '';
  final catRaw = category?.trim() ?? '';
  final candidates = <String>[];
  if (catLower.isNotEmpty) {
    // Try category-qualified translation keys using authoritative category translation_key if known
    final catTk =
        _TaxonomyResolver.categoryTranslationKey(category!) ??
        'interest.$catLower';
    // Derive a dotted form: e.g., interest_category.mentorship -> interest.mentorship.<sub>
    // We add candidates that combine category translation namespace with sub keys.
    candidates.addAll([
      'interest.$catLower.$lower',
      'interest.$catLower.${trimmed.toLowerCase()}',
      'interest.${catLower}_$lower',
      'interest.$catRaw.$trimmed',
      'interest_category.$catLower.$lower',
      'interest_category.$catLower.${trimmed.toLowerCase()}',
      // Use resolved category translation namespace
      '$catTk.$lower',
      '$catTk.${trimmed.toLowerCase()}',
    ]);
  }
  candidates.addAll([
    'interest.$lower',
    'interest.$trimmed',
    lower,
    trimmed,
    'interest_category.$lower',
    'interest_category.$trimmed',
  ]);
  // Also try dotted activity/friendship/romantic/business scopes — main app sometimes
  // stores interest keys under those scopes (e.g., interest.romantic.dancing)
  if (catLower.isNotEmpty) {
    for (final scope in const [
      'romantic',
      'friendship',
      'activity',
      'business',
      'personal',
    ]) {
      candidates.add('interest.$scope.$lower');
      candidates.add('interest.$scope.$catLower.$lower');
    }
  }
  final hit = _tryKeys(candidates, t);
  if (hit.isNotEmpty) return hit;
  return _prettySentence(trimmed);
}

String _formatValueList(
  dynamic val,
  String key,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  final notSet = _tryKeys(['matchInspectorEmpty'], t, fallback: 'Not set');
  final anyStr = _tryKeys(
    ['matchInspectorUnrestricted', 'any', 'generalAny'],
    t,
    fallback: 'Any',
  );
  if (val == null) return notSet;
  if (val is List) {
    if (val.isEmpty) return anyStr;
    final items = val
        .map((e) => _localizeFilterValue(e.toString(), key, t))
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) return anyStr;
    return items.join(', ');
  }
  if (val is Map) {
    if (val.containsKey('min') || val.containsKey('max')) {
      final min = val['min']?.toString() ?? '';
      final max = val['max']?.toString() ?? '';
      final unit = _tryKeys(
        ['matchInspectorHeightUnit', 'cm'],
        t,
        fallback: 'cm',
      );
      if (min.isNotEmpty && max.isNotEmpty) return '$min – $max $unit';
      if (min.isNotEmpty) return '≥ $min $unit';
      if (max.isNotEmpty) return '≤ $max $unit';
      return anyStr;
    }
    return val.toString();
  }
  final s = val.toString().trim();
  if (s.isEmpty) return notSet;
  return _localizeFilterValue(s, key, t);
}

String _formatAgePref(
  dynamic val,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  if (val is List && val.length >= 2) {
    return '${val[0]} – ${val[1]}';
  }
  return '';
}

/// Localizes a system-level visibility status value (visible / hidden / ghosted / etc.)
String _localizeVisSys(
  String raw,
  String Function(String, {Map<String, String>? params, String? pluralParam}) t,
) {
  switch (raw.trim().toLowerCase()) {
    case 'visible':
      return _tryKeys(['matchInspectorVisible'], t, fallback: 'Visible');
    case 'hidden':
      return _tryKeys(['matchInspectorHidden'], t, fallback: 'Hidden');
    case 'ghosted':
      return _tryKeys(['matchInspectorGhosted'], t, fallback: 'Ghosted');
    default:
      return _prettySentence(raw);
  }
}

// ---------- Main Screen Widget ----------
class AdminMatchComparisonDashboard extends ConsumerStatefulWidget {
  const AdminMatchComparisonDashboard({
    super.key,
    required this.t,
    required this.localeCode,
  });

  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;
  final String localeCode;

  @override
  ConsumerState<AdminMatchComparisonDashboard> createState() =>
      _AdminMatchComparisonDashboardState();
}

class _AdminMatchComparisonDashboardState
    extends ConsumerState<AdminMatchComparisonDashboard> {
  Map<String, dynamic>? _userA;
  Map<String, dynamic>? _userB;
  bool _isComparing = false;
  String? _compareErrorKey;
  String _compareErrorDetail = '';
  Map<String, dynamic>? _compareResult;
  String? _selectedIntent;

  String tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = widget.t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) {
          s = s.replaceAll('{$k}', v);
        });
      }
    }
    return s;
  }

  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    final res = await Supabase.instance.client
        .rpc(
          'admin_search_match_users',
          params: {'p_query': query.trim(), 'p_limit': 20},
        )
        .timeout(const Duration(seconds: 8));
    if (res is List) {
      return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    if (res == null) return [];
    throw Exception('Unexpected response type ${res.runtimeType}: $res');
  }

  Future<void> _compare() async {
    if (_userA == null || _userB == null) return;
    final aId = _userA!['id']?.toString();
    final bId = _userB!['id']?.toString();
    if (aId == null || bId == null) return;
    if (aId == bId) {
      setState(() {
        _compareErrorKey = 'matchInspectorSameUser';
        _compareErrorDetail = '';
        _compareResult = null;
      });
      return;
    }
    setState(() {
      _isComparing = true;
      _compareErrorKey = null;
      _compareErrorDetail = '';
    });
    try {
      final res = await Supabase.instance.client
          .rpc(
            'admin_compare_users',
            params: {'p_user_a': aId, 'p_user_b': bId},
          )
          .timeout(const Duration(seconds: 12));

      final historyRes = await Supabase.instance.client
          .rpc(
            'admin_get_match_pair_status',
            params: {'p_user_a': aId, 'p_user_b': bId},
          )
          .timeout(const Duration(seconds: 8));

      Map<String, dynamic> data;
      if (res is Map<String, dynamic>) {
        data = res;
      } else if (res is Map) {
        data = Map<String, dynamic>.from(res);
      } else {
        throw Exception('Unexpected response');
      }
      if (historyRes is Map) {
        data.addAll(Map<String, dynamic>.from(historyRes));
      }
      if (!mounted) return;
      setState(() {
        _compareResult = data;
        _isComparing = false;
        if (data.containsKey('error')) {
          _compareErrorKey = 'matchInspectorErrorLoadFailed';
          _compareErrorDetail = data['error']?.toString() ?? 'unknown';
        } else {
          final shared =
              (data['shared_intents'] as List?)?.cast<String>() ?? [];
          if (shared.isNotEmpty) {
            _selectedIntent = shared.first;
          } else {
            _selectedIntent = null;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isComparing = false;
        _compareErrorKey = 'matchInspectorErrorLoadFailed';
        _compareErrorDetail = e.toString();
      });
    }
  }

  void _swap() {
    setState(() {
      final tmp = _userA;
      _userA = _userB;
      _userB = tmp;
      _compareResult = null;
      _compareErrorKey = null;
      _compareErrorDetail = '';
    });
  }

  void _clear() {
    setState(() {
      _userA = null;
      _userB = null;
      _compareResult = null;
      _compareErrorKey = null;
      _compareErrorDetail = '';
    });
  }

  Future<void> _pickUser(bool isA) async {
    final String? excludeId = isA
        ? (_userB == null ? null : _userB!['id']?.toString())
        : (_userA == null ? null : _userA!['id']?.toString());
    Future<List<Map<String, dynamic>>> filteredSearch(String q) async {
      final list = await _searchUsers(q);
      if (excludeId == null || excludeId.isEmpty) {
        return list;
      }
      return list.where((u) => u['id']?.toString() != excludeId).toList();
    }

    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) =>
          _UserSearchDialog(t: widget.t, searchUsers: filteredSearch),
    );
    if (selected != null) {
      setState(() {
        if (isA) {
          _userA = selected;
        } else {
          _userB = selected;
        }
        _compareResult = null;
        _compareErrorKey = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCompare =
        _userA != null &&
        _userB != null &&
        _userA!['id'] != _userB!['id'] &&
        !_isComparing;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Card with Gradient Accent
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.7),
                      theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                    ],
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.analytics_rounded,
                        color: theme.colorScheme.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(
                              'matchInspectorTitle',
                              fallback: 'Match Inspector',
                            ),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            tr(
                              'matchInspectorSubtitle',
                              fallback:
                                  'Compare two users to see why they match or not.',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Pickers Layout (User A & User B with floating swap)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 640;
                  final pickerA = _UserPickerCard(
                    label: tr('matchInspectorUserA', fallback: 'User A'),
                    badgeColor: theme.colorScheme.primary,
                    user: _userA,
                    hint: tr(
                      'matchInspectorSearchHint',
                      fallback: 'Select a user to inspect...',
                    ),
                    t: widget.t,
                    onTap: () => _pickUser(true),
                    onClear: _userA == null
                        ? null
                        : () => setState(() {
                            _userA = null;
                            _compareResult = null;
                          }),
                  );
                  final pickerB = _UserPickerCard(
                    label: tr('matchInspectorUserB', fallback: 'User B'),
                    badgeColor: theme.colorScheme.secondary,
                    user: _userB,
                    hint: tr(
                      'matchInspectorSearchHint',
                      fallback: 'Select a user to inspect...',
                    ),
                    t: widget.t,
                    onTap: () => _pickUser(false),
                    onClear: _userB == null
                        ? null
                        : () => setState(() {
                            _userB = null;
                            _compareResult = null;
                          }),
                  );

                  if (isNarrow) {
                    return Column(
                      children: [
                        pickerA,
                        const SizedBox(height: 8),
                        Center(
                          child: Material(
                            color: theme.colorScheme.surfaceContainerHighest,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: (_userA == null && _userB == null)
                                  ? null
                                  : _swap,
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Icon(
                                  Icons.swap_vert_rounded,
                                  size: 22,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        pickerB,
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: pickerA),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 40,
                        ),
                        child: Material(
                          color: theme.colorScheme.surfaceContainerHighest,
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: (_userA == null && _userB == null)
                                ? null
                                : _swap,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Icon(
                                Icons.swap_horiz_rounded,
                                size: 22,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: pickerB),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),

              // Action Buttons Row
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: canCompare ? 2 : 0,
                      ),
                      onPressed: canCompare ? _compare : null,
                      icon: _isComparing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.compare_arrows_rounded, size: 20),
                      label: Text(
                        _isComparing
                            ? tr(
                                'matchInspectorLoading',
                                fallback: 'Analyzing...',
                              )
                            : tr(
                                'matchInspectorCompareButton',
                                fallback: 'Compare Profiles',
                              ),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed:
                          (_userA == null &&
                              _userB == null &&
                              _compareResult == null)
                          ? null
                          : _clear,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(tr('matchInspectorClear', fallback: 'Clear')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Error banner
              if (_compareErrorKey != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(
                      alpha: 0.8,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: theme.colorScheme.onErrorContainer,
                        size: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          _compareErrorDetail.isEmpty
                              ? tr(
                                  _compareErrorKey!,
                                  fallback: 'Failed to compare users.',
                                )
                              : tr(
                                  _compareErrorKey!,
                                  params: {'error': _compareErrorDetail},
                                  fallback:
                                      'Failed to compare users: $_compareErrorDetail',
                                ),
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Empty Selection State
              if (_compareResult == null &&
                  _compareErrorKey == null &&
                  !_isComparing &&
                  (_userA == null || _userB == null))
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 36,
                    horizontal: 20,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.6,
                      ),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.08,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.person_search_rounded,
                          size: 40,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        tr(
                          'matchInspectorSelectHint',
                          fallback: 'Select two users to compare',
                        ),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tr(
                          'matchInspectorSelectInstructions',
                          fallback:
                              'Select User A and User B above, then tap Compare Profiles to see compatibility.',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

              // Comparison Results View
              if (_compareResult != null && _compareErrorKey == null)
                _EnhancedComparisonView(
                  result: _compareResult!,
                  selectedIntent: _selectedIntent,
                  onSelectIntent: (intent) =>
                      setState(() => _selectedIntent = intent),
                  t: widget.t,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Modern User Picker Card ----------
class _UserPickerCard extends StatelessWidget {
  const _UserPickerCard({
    required this.label,
    required this.badgeColor,
    required this.user,
    required this.hint,
    required this.t,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final Color badgeColor;
  final Map<String, dynamic>? user;
  final String hint;
  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  String _displayAge(Map<String, dynamic> u) {
    final dob = u['date_of_birth']?.toString();
    if (dob == null || dob.isEmpty) return '';
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      var age = now.year - d.year;
      if (now.month < d.month || (now.month == d.month && now.day < d.day)) {
        age--;
      }
      return '$age';
    } catch (_) {
      return '';
    }
  }

  String? _firstPhotoUrl(Map<String, dynamic> u) {
    final photos = u['photos'];
    if (photos is List && photos.isNotEmpty) {
      final p = photos[0];
      if (p is String && p.isNotEmpty) return p;
      if (p is Map && p['url'] != null) return p['url'].toString();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUser = user != null;
    final photoUrl = hasUser ? _firstPhotoUrl(user!) : null;

    return Container(
      decoration: BoxDecoration(
        color: hasUser
            ? theme.colorScheme.surface
            : theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: hasUser
              ? badgeColor.withValues(alpha: 0.35)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
          width: hasUser ? 1.5 : 1.0,
        ),
        boxShadow: hasUser
            ? [
                BoxShadow(
                  color: badgeColor.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: Avatar + Label Pill + Clear button
                Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: badgeColor.withValues(alpha: 0.15),
                          backgroundImage:
                              (photoUrl != null && photoUrl.startsWith('http'))
                              ? NetworkImage(photoUrl)
                              : null,
                          child:
                              (photoUrl == null || !photoUrl.startsWith('http'))
                              ? Icon(
                                  hasUser
                                      ? Icons.person
                                      : Icons.person_add_alt_1_rounded,
                                  size: 20,
                                  color: badgeColor,
                                )
                              : null,
                        ),
                        if (hasUser)
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: badgeColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (onClear != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: _tr('matchInspectorClear', fallback: 'Clear'),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: onClear,
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                // Content
                if (!hasUser)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.touch_app_rounded,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            hint,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (hasUser) ...[
                  Builder(
                    builder: (context) {
                      final rawName =
                          (user!['name']?.toString().isEmpty ?? true)
                          ? (user!['id']?.toString() ?? '')
                          : user!['name'].toString();
                      final isRtl = _isRtlText(rawName);
                      return Directionality(
                        textDirection: isRtl
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        child: SafeText(
                          rawName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                          textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: SafeText(
                      user!['id']?.toString() ?? '',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if ((user!['gender']?.toString().isNotEmpty ?? false))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _localizeGender(user!['gender'].toString(), t),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      if (_displayAge(user!).isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Builder(
                            builder: (context) {
                              final ageLabel = _tr(
                                'profileAgeLabel',
                                fallback: 'Age',
                              );
                              return Text(
                                '$ageLabel: ${_displayAge(user!)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
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

// ---------- Modern User Search Modal ----------
class _UserSearchDialog extends StatefulWidget {
  const _UserSearchDialog({required this.t, required this.searchUsers});

  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;
  final Future<List<Map<String, dynamic>>> Function(String) searchUsers;

  @override
  State<_UserSearchDialog> createState() => _UserSearchDialogState();
}

class _UserSearchDialogState extends State<_UserSearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  bool _hasSearched = false;
  String? _error;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = widget.t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = null;
      _hasSearched = true;
    });
    try {
      final list = await widget.searchUsers(q);
      if (!mounted) return;
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _age(Map<String, dynamic> u) {
    final dob = u['date_of_birth']?.toString();
    if (dob == null || dob.isEmpty) return '';
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      var age = now.year - d.year;
      if (now.month < d.month || (now.month == d.month && now.day < d.day)) {
        age--;
      }
      return '$age';
    } catch (_) {
      return '';
    }
  }

  String? _firstPhotoUrl(Map<String, dynamic> u) {
    final photos = u['photos'];
    if (photos is List && photos.isNotEmpty) {
      final p = photos[0];
      if (p is String && p.isNotEmpty) return p;
      if (p is Map && p['url'] != null) return p['url'].toString();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      actionsPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      title: Row(
        children: [
          Icon(
            Icons.person_search_rounded,
            color: theme.colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 10),
          Text(
            _tr(
              'matchInspectorSearchHint',
              fallback: 'Select a user to inspect...',
            ),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: _tr(
                  'matchInspectorSearchFieldHint',
                  fallback: 'Search by name, email, or user ID...',
                ),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _controller.clear();
                          _search('');
                        },
                      ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                color: theme.colorScheme.error,
                                size: 36,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => _search(_controller.text),
                                child: Text(
                                  _tr('generalRetry', fallback: 'Retry'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _results.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _hasSearched
                                ? _tr(
                                    'matchInspectorSearchNoResults',
                                    fallback:
                                        'No users found matching your search',
                                  )
                                : _tr('generalLoading', fallback: 'Loading...'),
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final u = _results[i];
                          final rawName =
                              (u['name']?.toString().isEmpty ?? true)
                              ? '—'
                              : u['name'].toString();
                          final isRtlName = _isRtlText(rawName);
                          final localizedGender =
                              (u['gender']?.toString().isNotEmpty ?? false)
                              ? _localizeGender(
                                  u['gender'].toString(),
                                  widget.t,
                                )
                              : '';
                          final photoUrl = _firstPhotoUrl(u);
                          final userAge = _age(u);
                          final ageLabel = _tr(
                            'profileAgeLabel',
                            fallback: 'Age',
                          );

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            leading: CircleAvatar(
                              radius: 20,
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              backgroundImage:
                                  (photoUrl != null &&
                                      photoUrl.startsWith('http'))
                                  ? NetworkImage(photoUrl)
                                  : null,
                              child:
                                  (photoUrl == null ||
                                      !photoUrl.startsWith('http'))
                                  ? const Icon(Icons.person_rounded)
                                  : null,
                            ),
                            title: Directionality(
                              textDirection: isRtlName
                                  ? TextDirection.rtl
                                  : TextDirection.ltr,
                              child: Text(
                                rawName,
                                textAlign: isRtlName
                                    ? TextAlign.right
                                    : TextAlign.left,
                                textDirection: isRtlName
                                    ? TextDirection.rtl
                                    : TextDirection.ltr,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            subtitle: Directionality(
                              textDirection: TextDirection.ltr,
                              child: SafeText(
                                '${u['id']}\n${[u['email'], localizedGender, if (userAge.isNotEmpty) '$ageLabel: $userAge'].where((e) => e != null && e.toString().isNotEmpty).join(' • ')}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                            ),
                            onTap: () => Navigator.of(context).pop(u),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_tr('generalCancel', fallback: 'Cancel')),
        ),
      ],
    );
  }
}

// ---------- Enhanced Comparison View ----------
class _EnhancedComparisonView extends StatelessWidget {
  const _EnhancedComparisonView({
    required this.result,
    required this.selectedIntent,
    required this.onSelectIntent,
    required this.t,
  });

  final Map<String, dynamic> result;
  final String? selectedIntent;
  final ValueChanged<String> onSelectIntent;
  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompatible = result['is_compatible'] == true;
    final alreadyMatched = result['already_matched'] == true;
    final isUnmatched = result['is_unmatched_pair'] == true;
    final opportunitiesExhausted =
        result['match_opportunities_exhausted'] == true;
    final sharedIntents =
        (result['shared_intents'] as List?)?.cast<String>() ?? [];
    final compatibleIntents =
        (result['compatible_intents'] as List?)?.cast<String>() ?? [];
    final perIntent = (result['per_intent'] as List?) ?? [];
    final userA = (result['user_a'] as Map?) ?? {};
    final userB = (result['user_b'] as Map?) ?? {};
    final env = (result['environmental'] as Map?) ?? {};

    // Collect all blockers across all intents
    final allBlockerLines = <String>[];
    if (sharedIntents.isEmpty) {
      allBlockerLines.add(
        _tr(
          'matchInspectorNoSharedIntents',
          fallback: 'No shared active intents between these users',
        ),
      );
    } else {
      for (final item in perIntent) {
        final m = Map<String, dynamic>.from(item as Map);
        final intentName = _localizeIntent(m['intent']?.toString() ?? '', t);
        final blockers = (m['blockers'] as List?)?.cast<String>() ?? [];
        for (final b in blockers) {
          if (b == 'gender') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonGender', fallback: 'Gender Preference')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'age') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonAge', fallback: 'Age Preference')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'lifestyle') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonLifestyle', fallback: 'Lifestyle Habits')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'family') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonFamily', fallback: 'Family & Children')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'religion') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonReligion', fallback: 'Religion')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'height') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonHeight', fallback: 'Height Range')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'interests') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonInterests', fallback: 'Shared Interests')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          } else if (b == 'sub_intents') {
            allBlockerLines.add(
              '[$intentName] ${_tr('matchInspectorReasonSubIntents', fallback: 'Sub-Intents Overlap')}: ${_tr('matchInspectorMismatch', fallback: 'Mismatch')}',
            );
          }
        }
      }
    }

    // Active Intent Card Data
    final activeIntentData = perIntent.firstWhere(
      (e) => (e as Map)['intent'] == selectedIntent,
      orElse: () => perIntent.isNotEmpty ? perIntent.first : null,
    );
    final activeIntentMap = activeIntentData != null
        ? Map<String, dynamic>.from(activeIntentData as Map)
        : null;

    final bannerColor = isCompatible
        ? const Color(0xFF10B981)
        : const Color(0xFFEF4444);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Executive Verdict Banner
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isCompatible
                  ? [const Color(0xFF059669), const Color(0xFF10B981)]
                  : [const Color(0xFFDC2626), const Color(0xFFF87171)],
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: bannerColor.withValues(alpha: 0.28),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isCompatible
                          ? Icons.check_circle_rounded
                          : Icons.highlight_off_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      isCompatible
                          ? _tr(
                              'matchInspectorResultCompatible',
                              fallback: 'Compatible Match',
                            )
                          : _tr(
                              'matchInspectorResultNotCompatible',
                              fallback: 'Not Compatible',
                            ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Badges & Metrics
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  if (alreadyMatched)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.link_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            [
                              _tr(
                                'matchInspectorAlreadyMatched',
                                fallback: 'Already Matched',
                              ),
                              if ((result['match_type']
                                      ?.toString()
                                      .isNotEmpty ??
                                  false))
                                _localizeMatchType(
                                  result['match_type'].toString(),
                                  t,
                                ),
                              if ((result['matched_intent']
                                      ?.toString()
                                      .isNotEmpty ??
                                  false))
                                _localizeIntent(
                                  result['matched_intent'].toString(),
                                  t,
                                ),
                            ].join(' • ').trim(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (isUnmatched)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.block_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _tr(
                              'matchInspectorUnmatchedPair',
                              fallback: 'Unmatched Pair',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (opportunitiesExhausted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.hourglass_disabled_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _tr(
                              'matchInspectorOpportunitiesExhausted',
                              params: {
                                'count':
                                    (result['match_opportunity_count'] ?? 3)
                                        .toString(),
                              },
                              fallback:
                                  'No chat after ${result['match_opportunity_count'] ?? 3} match opportunities; will not match again',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (isCompatible && compatibleIntents.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.stars_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _tr(
                              'matchInspectorCompatibleIntents',
                              params: {
                                'intents': _localizeIntentList(
                                  compatibleIntents,
                                  t,
                                ),
                              },
                              fallback:
                                  'Compatible in ${_localizeIntentList(compatibleIntents, t)}',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 2. Executive Blocker Box (when incompatible)
        if (!isCompatible && allBlockerLines.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: Colors.red[700],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _tr(
                        'matchInspectorBlockersTitle',
                        fallback: 'Blockers preventing match',
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.red[800],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...allBlockerLines.map(
                  (line) => Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.cancel_rounded,
                          size: 14,
                          color: Colors.red[600],
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            line,
                            style: TextStyle(
                              color: Colors.red[900],
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!isCompatible && allBlockerLines.isNotEmpty)
          const SizedBox(height: 14),

        // 3. Environmental & Proximity Metrics Card
        _EnvironmentalStatusCard(env: env, userA: userA, userB: userB, t: t),
        const SizedBox(height: 16),

        // 4. Intent Selector Tabs
        if (sharedIntents.isNotEmpty) ...[
          Row(
            children: [
              Icon(
                Icons.layers_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                _tr(
                  'matchInspectorPerIntentHeader',
                  fallback: 'Active Intent Comparison',
                ),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: sharedIntents.map((intentKey) {
                final isSelected = selectedIntent == intentKey;
                final isPassed = compatibleIntents.contains(intentKey);
                final label = _localizeIntent(intentKey, t);
                final icon = _intentIcon(intentKey);

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    selected: isSelected,
                    showCheckmark: false,
                    avatar: Icon(
                      icon,
                      size: 16,
                      color: isSelected
                          ? (isPassed ? Colors.white : Colors.white)
                          : (isPassed ? Colors.green[700] : Colors.red[700]),
                    ),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: isSelected ? Colors.white : null,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          isPassed
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                          size: 14,
                          color: isSelected
                              ? Colors.white70
                              : (isPassed
                                    ? Colors.green[700]
                                    : Colors.red[700]),
                        ),
                      ],
                    ),
                    selectedColor: isPassed
                        ? const Color(0xFF059669)
                        : const Color(0xFFDC2626),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected
                            ? Colors.transparent
                            : (isPassed
                                  ? Colors.green.withValues(alpha: 0.3)
                                  : Colors.red.withValues(alpha: 0.3)),
                      ),
                    ),
                    onSelected: (_) => onSelectIntent(intentKey),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 5. Side-by-Side Comparison Matrix for selected Intent
        if (activeIntentMap != null)
          _IntentMatrixCard(
            intentData: activeIntentMap,
            userA: userA,
            userB: userB,
            t: t,
          ),
      ],
    );
  }
}

// ---------- Environmental Status HUD Card ----------
class _EnvironmentalStatusCard extends StatelessWidget {
  const _EnvironmentalStatusCard({
    required this.env,
    required this.userA,
    required this.userB,
    required this.t,
  });

  final Map env;
  final Map userA;
  final Map userB;
  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final distanceKm = env['distance_km'];
    final aRadiusM = userA['match_radius_meters'] ?? 10000;
    final bRadiusM = userB['match_radius_meters'] ?? 10000;
    final aRadiusKm = (aRadiusM / 1000.0).toStringAsFixed(0);
    final bRadiusKm = (bRadiusM / 1000.0).toStringAsFixed(0);

    final aOnline = userA['is_online'] == true;
    final bOnline = userB['is_online'] == true;
    final aVisUser = userA['visibility_user'] == true;
    final bVisUser = userB['visibility_user'] == true;
    final aVisSys = userA['visibility_system']?.toString() ?? 'visible';
    final bVisSys = userB['visibility_system']?.toString() ?? 'visible';

    final proximityPass = env['proximity_pass'] == true;

    final visibleStr = _tr('matchInspectorVisible', fallback: 'Visible');
    final incognitoStr = _tr('matchInspectorIncognito', fallback: 'Incognito');
    final onlineStr = _tr('matchInspectorOnline', fallback: 'Online');
    final offlineStr = _tr('matchInspectorOffline', fallback: 'Offline');
    final kmUnit = _tr('matchInspectorKmUnit', fallback: 'km');

    // Localized system visibility values
    final aVisSysLoc = _localizeVisSys(aVisSys, t);
    final bVisSysLoc = _localizeVisSys(bVisSys, t);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.sensors_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                _tr(
                  'matchInspectorEnvironmentalHeader',
                  fallback: 'Environment & System Status',
                ),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 600;
              final items = [
                // Distance HUD item
                _HudItem(
                  icon: proximityPass
                      ? Icons.radar_rounded
                      : Icons.radar_outlined,
                  iconColor: proximityPass ? Colors.green : Colors.amber[800]!,
                  title: _tr('matchInspectorDistance', fallback: 'Distance'),
                  value: distanceKm != null
                      ? '$distanceKm $kmUnit'
                      : _tr(
                          'matchInspectorDistanceUnknown',
                          fallback: 'Location not reported',
                        ),
                  subtitle: _tr(
                    'matchInspectorRadiusHint',
                    params: {
                      'a': '$aRadiusKm $kmUnit',
                      'b': '$bRadiusKm $kmUnit',
                    },
                    fallback: 'A: $aRadiusKm$kmUnit • B: $bRadiusKm$kmUnit',
                  ),
                  statusPass: proximityPass,
                ),
                // Visibility HUD item
                _HudItem(
                  icon:
                      (aVisUser &&
                          aVisSys == 'visible' &&
                          bVisUser &&
                          bVisSys == 'visible')
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  iconColor:
                      (aVisUser &&
                          aVisSys == 'visible' &&
                          bVisUser &&
                          bVisSys == 'visible')
                      ? Colors.green
                      : Colors.amber[800]!,
                  title: _tr(
                    'matchInspectorVisibilityHeader',
                    fallback: 'Visibility',
                  ),
                  value: _tr(
                    'matchInspectorVisibilityValue',
                    params: {
                      'a': aVisUser ? visibleStr : incognitoStr,
                      'b': bVisUser ? visibleStr : incognitoStr,
                    },
                    fallback:
                        'A: ${aVisUser ? visibleStr : incognitoStr} • B: ${bVisUser ? visibleStr : incognitoStr}',
                  ),
                  subtitle: _tr(
                    'matchInspectorSysVisibilityHint',
                    params: {'a': aVisSysLoc, 'b': bVisSysLoc},
                    fallback: 'Sys: A[$aVisSysLoc] • B[$bVisSysLoc]',
                  ),
                  statusPass:
                      (aVisUser &&
                      aVisSys == 'visible' &&
                      bVisUser &&
                      bVisSys == 'visible'),
                ),
                // Online Status HUD item
                _HudItem(
                  icon: Icons.wifi_tethering_rounded,
                  iconColor: (aOnline && bOnline) ? Colors.green : Colors.grey,
                  title: _tr(
                    'matchInspectorLiveActivity',
                    fallback: 'Live Activity',
                  ),
                  value: _tr(
                    'matchInspectorActivityValue',
                    params: {'status': aOnline ? onlineStr : offlineStr},
                    fallback: 'A: ${aOnline ? onlineStr : offlineStr}',
                  ),
                  subtitle: _tr(
                    'matchInspectorActivitySubtitle',
                    params: {'status': bOnline ? onlineStr : offlineStr},
                    fallback: 'B: ${bOnline ? onlineStr : offlineStr}',
                  ),
                  statusPass: aOnline || bOnline,
                ),
              ];

              if (isNarrow) {
                return Column(
                  children: items
                      .map(
                        (w) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: w,
                        ),
                      )
                      .toList(),
                );
              }
              return Row(
                children: items
                    .map(
                      (w) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: w,
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HudItem extends StatelessWidget {
  const _HudItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.statusPass,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String value;
  final String subtitle;
  final bool statusPass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: iconColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                SafeText(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SafeText(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Intent Side-by-Side Matrix Card ----------
class _IntentMatrixCard extends StatelessWidget {
  const _IntentMatrixCard({
    required this.intentData,
    required this.userA,
    required this.userB,
    required this.t,
  });

  final Map<String, dynamic> intentData;
  final Map userA;
  final Map userB;
  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final intentKey = intentData['intent']?.toString() ?? '';
    final intentName = _localizeIntent(intentKey, t);
    final allPassed = intentData['all_passed'] == true;

    final sub = intentData['sub_intent'] is Map
        ? intentData['sub_intent'] as Map
        : {};
    final gender = intentData['gender'] is Map
        ? intentData['gender'] as Map
        : {};
    final age = intentData['age'] is Map ? intentData['age'] as Map : {};
    final lifestyle = intentData['lifestyle'] is Map
        ? intentData['lifestyle'] as Map
        : {};
    final family = intentData['family'] is Map
        ? intentData['family'] as Map
        : {};
    final religion = intentData['religion'] is Map
        ? intentData['religion'] as Map
        : {};
    final height = intentData['height'] is Map
        ? intentData['height'] as Map
        : {};
    final interests = intentData['interests'] is Map
        ? intentData['interests'] as Map
        : {};

    // Height is only collected for Romantic profiles and is ignored by
    // public.are_filters_compatible for every other intent. The RPC reports
    // this as height.applies; fall back to a local check so the row still
    // behaves correctly against a database that has not been migrated yet.
    final heightApplies = height['applies'] is bool
        ? height['applies'] as bool
        : intentKey.toLowerCase().trim().split('::').first == 'romantic';

    // Zebra striping: the isEven flags below are hardcoded for a fixed row
    // layout that includes the Height row. When that row is hidden, every
    // later row shifts by one, so their parity has to flip.
    bool stripe(bool even) => heightApplies ? even : !even;

    // Domain Interests Map
    final domainType = intentData['domain_type']?.toString() ?? 'personal';
    final aInterestsMap =
        (domainType == 'business'
                ? userA['business_interests']
                : userA['personal_interests'])
            as Map? ??
        userA['interests'] as Map? ??
        {};
    final bInterestsMap =
        (domainType == 'business'
                ? userB['business_interests']
                : userB['personal_interests'])
            as Map? ??
        userB['interests'] as Map? ??
        {};
    final overlapCats =
        (interests['overlap_categories'] as List?)?.cast<String>() ?? [];
    int visibleCount(Map m) {
      int c = 0;
      for (final e in m.entries) {
        final raw = e.value;
        final subs = (raw is List)
            ? raw.map((x) => x.toString()).toList()
            : <String>[];
        final norm = e.key
            .toString()
            .toLowerCase()
            .replaceAll('_', ' ')
            .replaceAll(' ', '')
            .trim();
        final filtered = subs
            .where(
              (s) =>
                  s
                          .toLowerCase()
                          .replaceAll('_', ' ')
                          .replaceAll(' ', '')
                          .trim() !=
                      norm &&
                  s.trim().isNotEmpty,
            )
            .toList();
        if (filtered.isNotEmpty) c++;
      }
      return c;
    }

    final aVisibleCount = visibleCount(aInterestsMap);
    final bVisibleCount = visibleCount(bInterestsMap);

    final userAName = (userA['name']?.toString().isNotEmpty ?? false)
        ? userA['name'].toString()
        : _tr('matchInspectorUserA', fallback: 'User A');
    final userBName = (userB['name']?.toString().isNotEmpty ?? false)
        ? userB['name'].toString()
        : _tr('matchInspectorUserB', fallback: 'User B');

    final matrixSuffix = _tr(
      'matchInspectorMatrixHeaderSuffix',
      fallback: 'Matrix',
    );
    final sharedSuffix = _tr(
      'matchInspectorSharedCount',
      params: {'count': overlapCats.length.toString()},
      fallback: '${overlapCats.length} Shared',
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title & Intent Verdict Badge
          Row(
            children: [
              Icon(
                _intentIcon(intentKey),
                color: theme.colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$intentName $matrixSuffix',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: allPassed
                      ? Colors.green.withValues(alpha: 0.12)
                      : Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: allPassed
                        ? Colors.green.withValues(alpha: 0.3)
                        : Colors.red.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      allPassed
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      size: 14,
                      color: allPassed ? Colors.green[700] : Colors.red[700],
                    ),
                    const SizedBox(width: 5),
                    Text(
                      allPassed
                          ? _tr('matchInspectorPass', fallback: 'Pass')
                          : _tr('matchInspectorFail', fallback: 'Fail'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: allPassed ? Colors.green[800] : Colors.red[800],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Structured Side-by-Side Comparison Table
          // Wrapped in horizontal SingleChildScrollView to guarantee the criteria
          // column never becomes so narrow that words are broken mid-word
          // (e.g. "Preferenc" + "e"). FixedColumnWidth(132) ensures the longest
          // label ("Preference") fits; ConstrainedBox keeps the table at least
          // 560 logical pixels wide while allowing horizontal scroll on narrow screens.
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 560),
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(132),
                    1: FlexColumnWidth(1.4),
                    2: FlexColumnWidth(1.4),
                    3: FixedColumnWidth(92),
                  },
                  defaultColumnWidth: const FlexColumnWidth(1.0),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    // Table Header
                    TableRow(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.08,
                        ),
                      ),
                      children: [
                        _TableHead(
                          _tr(
                            'matchInspectorMatrixParam',
                            fallback: 'Criteria / Filter',
                          ),
                        ),
                        _TableHead(userAName),
                        _TableHead(userBName),
                        _TableHead(
                          _tr(
                            'matchInspectorMatrixVerdict',
                            fallback: 'Match Verdict',
                          ),
                        ),
                      ],
                    ),

                    // 1. Sub-Intents
                    _buildTableRow(
                      icon: Icons.checklist_rounded,
                      label: _tr(
                        'matchInspectorSubIntents',
                        fallback: 'Sub-Intents',
                      ),
                      aText:
                          (sub['a_values'] as List?)
                              ?.map((e) => _localizeSubIntent(e.toString(), t))
                              .join(', ') ??
                          _tr(
                            'matchInspectorUnrestricted',
                            fallback: 'Unrestricted / Any',
                          ),
                      bText:
                          (sub['b_values'] as List?)
                              ?.map((e) => _localizeSubIntent(e.toString(), t))
                              .join(', ') ??
                          _tr(
                            'matchInspectorUnrestricted',
                            fallback: 'Unrestricted / Any',
                          ),
                      passed: sub['passed'] == true,
                      t: t,
                      theme: theme,
                      isEven: false,
                    ),

                    // 2. Gender Preferences
                    _buildTableRow(
                      icon: Icons.wc_rounded,
                      label: _tr(
                        'matchInspectorReasonGender',
                        fallback: 'Gender Preference',
                      ),
                      aText:
                          '${_localizeGender(gender['a_gender']?.toString() ?? '', t)}\n(${_tr('matchInspectorWants', params: {'val': _formatValueList(gender['a_pref'], 'gender', t)}, fallback: 'Wants: ${_formatValueList(gender['a_pref'], 'gender', t)}')})',
                      bText:
                          '${_localizeGender(gender['b_gender']?.toString() ?? '', t)}\n(${_tr('matchInspectorWants', params: {'val': _formatValueList(gender['b_pref'], 'gender', t)}, fallback: 'Wants: ${_formatValueList(gender['b_pref'], 'gender', t)}')})',
                      passed: gender['passed'] == true,
                      t: t,
                      theme: theme,
                      isEven: true,
                    ),

                    // 3. Age Preferences
                    _buildTableRow(
                      icon: Icons.cake_rounded,
                      label: _tr(
                        'matchInspectorReasonAge',
                        fallback: 'Age Preference',
                      ),
                      aText: () {
                        final ageLabel = _tr(
                          'profileAgeLabel',
                          fallback: 'Age',
                        );
                        final agePref = _formatAgePref(age['a_pref'], t);
                        return '$ageLabel: ${gender['a_age'] ?? userA['age'] ?? '—'}\n(${_tr('matchInspectorWants', params: {'val': agePref}, fallback: 'Wants: $agePref')})';
                      }(),
                      bText: () {
                        final ageLabel = _tr(
                          'profileAgeLabel',
                          fallback: 'Age',
                        );
                        final agePref = _formatAgePref(age['b_pref'], t);
                        return '$ageLabel: ${gender['b_age'] ?? userB['age'] ?? '—'}\n(${_tr('matchInspectorWants', params: {'val': agePref}, fallback: 'Wants: $agePref')})';
                      }(),
                      passed: age['passed'] == true,
                      t: t,
                      theme: theme,
                      isEven: false,
                    ),

                    // 4. Height — only a criterion for the Romantic intent, so the
                    // row is hidden for friendship / activity_partner /
                    // business_networking rather than implying a live filter.
                    if (heightApplies)
                      _buildTableRow(
                        icon: Icons.height_rounded,
                        label: _tr('matchInspectorHeight', fallback: 'Height'),
                        aText: () {
                          final htUnit = _tr(
                            'matchInspectorHeightUnit',
                            fallback: 'cm',
                          );
                          final htPref = _formatValueList(
                            height['a_pref'],
                            'height',
                            t,
                          );
                          return '${height['a_val'] ?? userA['height'] ?? '—'} $htUnit\n(${_tr('matchInspectorWants', params: {'val': htPref}, fallback: 'Wants: $htPref')})';
                        }(),
                        bText: () {
                          final htUnit = _tr(
                            'matchInspectorHeightUnit',
                            fallback: 'cm',
                          );
                          final htPref = _formatValueList(
                            height['b_pref'],
                            'height',
                            t,
                          );
                          return '${height['b_val'] ?? userB['height'] ?? '—'} $htUnit\n(${_tr('matchInspectorWants', params: {'val': htPref}, fallback: 'Wants: $htPref')})';
                        }(),
                        passed: height['passed'] == true,
                        t: t,
                        theme: theme,
                        isEven: true,
                      ),

                    // 5. Smoking
                    _buildGranularRow(
                      icon: Icons.smoking_rooms_rounded,
                      label: _tr('matchInspectorSmoking', fallback: 'Smoking'),
                      data: lifestyle['smoking'] as Map?,
                      keyName: 'smoking',
                      t: t,
                      theme: theme,
                      isEven: stripe(false),
                    ),

                    // 6. Drinking
                    _buildGranularRow(
                      icon: Icons.local_bar_rounded,
                      label: _tr(
                        'matchInspectorDrinking',
                        fallback: 'Drinking',
                      ),
                      data: lifestyle['drinking'] as Map?,
                      keyName: 'drinking',
                      t: t,
                      theme: theme,
                      isEven: stripe(true),
                    ),

                    // 7. Diet
                    _buildGranularRow(
                      icon: Icons.restaurant_rounded,
                      label: _tr('matchInspectorDiet', fallback: 'Diet'),
                      data: lifestyle['diet'] as Map?,
                      keyName: 'diet',
                      t: t,
                      theme: theme,
                      isEven: stripe(false),
                    ),

                    // 8. Exercise
                    _buildGranularRow(
                      icon: Icons.fitness_center_rounded,
                      label: _tr(
                        'matchInspectorExercise',
                        fallback: 'Exercise',
                      ),
                      data: lifestyle['exercise'] as Map?,
                      keyName: 'exercise',
                      t: t,
                      theme: theme,
                      isEven: stripe(true),
                    ),

                    // 9. Has Children
                    _buildGranularRow(
                      icon: Icons.child_care_rounded,
                      label: _tr(
                        'matchInspectorHasChildren',
                        fallback: 'Has Children',
                      ),
                      data: family['has_children'] as Map?,
                      keyName: 'has_children',
                      t: t,
                      theme: theme,
                      isEven: stripe(false),
                    ),

                    // 10. Wants Children
                    _buildGranularRow(
                      icon: Icons.family_restroom_rounded,
                      label: _tr(
                        'matchInspectorWantsChildren',
                        fallback: 'Wants Children',
                      ),
                      data: family['wants_children'] as Map?,
                      keyName: 'wants_children',
                      t: t,
                      theme: theme,
                      isEven: stripe(true),
                    ),

                    // 11. Religion
                    _buildGranularRow(
                      icon: Icons.church_rounded,
                      label: _tr(
                        'matchInspectorReligion',
                        fallback: 'Religion',
                      ),
                      data: religion,
                      keyName: 'religion',
                      t: t,
                      theme: theme,
                      isEven: stripe(false),
                    ),

                    // 12. Interests Overlap
                    _buildTableRow(
                      icon: Icons.interests_rounded,
                      label: _tr(
                        'matchInspectorInterests',
                        fallback: 'Interests Overlap',
                      ),
                      aText: _tr(
                        'matchInspectorCategories',
                        params: {'count': aVisibleCount.toString()},
                        fallback: '$aVisibleCount categories',
                      ),
                      bText: _tr(
                        'matchInspectorCategories',
                        params: {'count': bVisibleCount.toString()},
                        fallback: '$bVisibleCount categories',
                      ),
                      passed: interests['passed'] == true,
                      customVerdict: overlapCats.isNotEmpty
                          ? sharedSuffix
                          : null,
                      t: t,
                      theme: theme,
                      isEven: stripe(true),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Detailed Interests Breakdown Section
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                color: theme.colorScheme.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                '${_tr('matchInspectorReasonInterests', fallback: 'Shared Interests')} (${_localizeDomainType(domainType, t)})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _InterestsDetail(
            aInterests: aInterestsMap,
            bInterests: bInterestsMap,
            overlapCats: overlapCats,
            userAName: userAName,
            userBName: userBName,
            t: t,
          ),
        ],
      ),
    );
  }

  TableRow _buildTableRow({
    required IconData icon,
    required String label,
    required String aText,
    required String bText,
    required bool passed,
    String? customVerdict,
    required String Function(String key, {Map<String, String>? params, String? pluralParam}) t,
    required ThemeData theme,
    required bool isEven,
  }) {
    final bgColor = isEven
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25)
        : Colors.transparent;
    final unrestricted = _tr(
      'matchInspectorUnrestricted',
      fallback: 'Unrestricted / Any',
    );
    final passStr = _tr('matchInspectorPass', fallback: 'Pass');
    final failStr = _tr('matchInspectorFail', fallback: 'Fail');

    return TableRow(
      decoration: BoxDecoration(color: bgColor),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  icon,
                  size: 14,
                  color: theme.colorScheme.primary.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  softWrap: true,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Text(
            aText.isEmpty ? unrestricted : aText,
            style: const TextStyle(fontSize: 12, height: 1.3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Text(
            bText.isEmpty ? unrestricted : bText,
            style: const TextStyle(fontSize: 12, height: 1.3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: _VerdictPill(
            passed: passed,
            label: customVerdict ?? (passed ? passStr : failStr),
          ),
        ),
      ],
    );
  }

  TableRow _buildGranularRow({
    required IconData icon,
    required String label,
    required Map? data,
    required String keyName,
    required String Function(String key, {Map<String, String>? params, String? pluralParam}) t,
    required ThemeData theme,
    required bool isEven,
  }) {
    if (data == null) {
      return _buildTableRow(
        icon: icon,
        label: label,
        aText: '—',
        bText: '—',
        passed: true,
        t: t,
        theme: theme,
        isEven: isEven,
      );
    }
    final aVal = data['a_val']?.toString() ?? '';
    final bVal = data['b_val']?.toString() ?? '';
    final aPref = data['a_pref'];
    final bPref = data['b_pref'];
    final passed = data['passed'] == true;

    final aFormatted =
        '${_formatValueList(aVal, keyName, t)}\n(${_tr('matchInspectorWants', params: {'val': _formatValueList(aPref, keyName, t)}, fallback: 'Wants: ${_formatValueList(aPref, keyName, t)}')})';
    final bFormatted =
        '${_formatValueList(bVal, keyName, t)}\n(${_tr('matchInspectorWants', params: {'val': _formatValueList(bPref, keyName, t)}, fallback: 'Wants: ${_formatValueList(bPref, keyName, t)}')})';

    return _buildTableRow(
      icon: icon,
      label: label,
      aText: aFormatted,
      bText: bFormatted,
      passed: passed,
      t: t,
      theme: theme,
      isEven: isEven,
    );
  }
}

class _TableHead extends StatelessWidget {
  const _TableHead(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Text(
        text,
        softWrap: true,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 12,
          height: 1.2,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _VerdictPill extends StatelessWidget {
  const _VerdictPill({required this.passed, required this.label});
  final bool passed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: passed
            ? const Color(0xFF10B981).withValues(alpha: 0.12)
            : const Color(0xFFEF4444).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: passed
              ? const Color(0xFF10B981).withValues(alpha: 0.3)
              : const Color(0xFFEF4444).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 12,
            color: passed ? const Color(0xFF059669) : const Color(0xFFDC2626),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: ShrinkText(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: passed
                    ? const Color(0xFF059669)
                    : const Color(0xFFDC2626),
              ),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Interests Deep Dive Detail Cards ----------
class _InterestsDetail extends StatelessWidget {
  const _InterestsDetail({
    required this.aInterests,
    required this.bInterests,
    required this.overlapCats,
    required this.userAName,
    required this.userBName,
    required this.t,
  });
  final Map? aInterests;
  final Map? bInterests;
  final List? overlapCats;
  final String userAName;
  final String userBName;
  final String Function(String key, {Map<String, String>? params, String? pluralParam}) t;

  String _tr(String key, {Map<String, String>? params, String? fallback}) {
    var s = t(key, params: params);
    if (_isMissing(s, key)) {
      s = fallback ?? key;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) => s = s.replaceAll('{$k}', v));
      }
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aMap = aInterests ?? {};
    final bMap = bInterests ?? {};
    final allCats = <String>{
      ...aMap.keys.map((e) => e.toString()),
      ...bMap.keys.map((e) => e.toString()),
    }.toList()..sort();
    final overlapSet = (overlapCats ?? [])
        .map((e) => e.toString().toLowerCase())
        .toSet();
    // Filter out phantom categories where both users have no effective sub-interests after stripping category-as-sub echo.
    final visibleCats = allCats.where((cat) {
      var aRaw = (aMap[cat] is List)
          ? (aMap[cat] as List).map((e) => e.toString()).toList()
          : <String>[];
      var bRaw = (bMap[cat] is List)
          ? (bMap[cat] as List).map((e) => e.toString()).toList()
          : <String>[];
      final catNorm = cat
          .toLowerCase()
          .replaceAll('_', ' ')
          .replaceAll(' ', '')
          .trim();
      aRaw = aRaw
          .where(
            (s) =>
                s
                    .toLowerCase()
                    .replaceAll('_', ' ')
                    .replaceAll(' ', '')
                    .trim() !=
                catNorm,
          )
          .toList();
      bRaw = bRaw
          .where(
            (s) =>
                s
                    .toLowerCase()
                    .replaceAll('_', ' ')
                    .replaceAll(' ', '')
                    .trim() !=
                catNorm,
          )
          .toList();
      return aRaw.isNotEmpty || bRaw.isNotEmpty;
    }).toList()..sort();
    if (visibleCats.isEmpty) {
      return Text(
        _tr('matchInspectorEmpty', fallback: 'Not set'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cat in visibleCats) ...[
          Builder(
            builder: (context) {
              final catLabel = _localizeInterestCategory(cat, t);
              var aSubs = (aMap[cat] is List)
                  ? (aMap[cat] as List).map((e) => e.toString()).toList()
                  : <String>[];
              var bSubs = (bMap[cat] is List)
                  ? (bMap[cat] as List).map((e) => e.toString()).toList()
                  : <String>[];
              final catNorm = cat
                  .toLowerCase()
                  .replaceAll('_', ' ')
                  .replaceAll(' ', '')
                  .trim();
              aSubs = aSubs
                  .where(
                    (s) =>
                        s
                            .toLowerCase()
                            .replaceAll('_', ' ')
                            .replaceAll(' ', '')
                            .trim() !=
                        catNorm,
                  )
                  .toList();
              bSubs = bSubs
                  .where(
                    (s) =>
                        s
                            .toLowerCase()
                            .replaceAll('_', ' ')
                            .replaceAll(' ', '')
                            .trim() !=
                        catNorm,
                  )
                  .toList();

              final isOverlapCat = overlapSet.contains(cat.toLowerCase());
              final bSet = bSubs.map((s) => s.toLowerCase()).toSet();
              final matchingSubs = aSubs
                  .where((s) => bSet.contains(s.toLowerCase()))
                  .toList();

              final aLocalized = aSubs
                  .map((s) => _localizeInterestSub(s, t, category: cat))
                  .toList();
              final bLocalized = bSubs
                  .map((s) => _localizeInterestSub(s, t, category: cat))
                  .toList();
              final matchingLocalized = matchingSubs
                  .map((s) => _localizeInterestSub(s, t, category: cat))
                  .toList();

              final sharedBadgeText = _tr(
                'matchInspectorSharedCount',
                params: {
                  'count': (matchingSubs.isNotEmpty ? matchingSubs.length : 1)
                      .toString(),
                },
                fallback:
                    '${matchingSubs.isNotEmpty ? matchingSubs.length : 1} Shared',
              );
              final noMatchText = _tr(
                'matchInspectorNoMatch',
                fallback: 'No match',
              );
              final emptyText = _tr('matchInspectorEmpty', fallback: 'Not set');

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isOverlapCat
                      ? const Color(0xFF10B981).withValues(alpha: 0.05)
                      : theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.3,
                        ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isOverlapCat
                        ? const Color(0xFF10B981).withValues(alpha: 0.3)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: isOverlapCat
                                ? const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.15)
                                : theme.colorScheme.outlineVariant.withValues(
                                    alpha: 0.3,
                                  ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isOverlapCat
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 14,
                            color: isOverlapCat
                                ? const Color(0xFF059669)
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            catLabel,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: isOverlapCat
                                ? const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.12)
                                : Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isOverlapCat
                                  ? const Color(
                                      0xFF10B981,
                                    ).withValues(alpha: 0.3)
                                  : Colors.red.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            isOverlapCat ? sharedBadgeText : noMatchText,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: isOverlapCat
                                  ? const Color(0xFF059669)
                                  : Colors.red[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // User A Sub-interests
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            userAName,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        if (aLocalized.isEmpty)
                          Text(
                            emptyText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          )
                        else
                          ...aLocalized.map((s) {
                            final isMatch = matchingLocalized.contains(s);
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isMatch
                                    ? const Color(
                                        0xFF10B981,
                                      ).withValues(alpha: 0.15)
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isMatch
                                      ? const Color(
                                          0xFF10B981,
                                        ).withValues(alpha: 0.4)
                                      : theme.colorScheme.outlineVariant
                                            .withValues(alpha: 0.6),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isMatch) ...[
                                    const Icon(
                                      Icons.check_rounded,
                                      size: 12,
                                      color: Color(0xFF059669),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    s,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isMatch
                                          ? const Color(0xFF059669)
                                          : theme.colorScheme.onSurface,
                                      fontWeight: isMatch
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // User B Sub-interests
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondary.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            userBName,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                        if (bLocalized.isEmpty)
                          Text(
                            emptyText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          )
                        else
                          ...bLocalized.map((s) {
                            final isMatch = matchingLocalized.contains(s);
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isMatch
                                    ? const Color(
                                        0xFF10B981,
                                      ).withValues(alpha: 0.15)
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isMatch
                                      ? const Color(
                                          0xFF10B981,
                                        ).withValues(alpha: 0.4)
                                      : theme.colorScheme.outlineVariant
                                            .withValues(alpha: 0.6),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isMatch) ...[
                                    const Icon(
                                      Icons.check_rounded,
                                      size: 12,
                                      color: Color(0xFF059669),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    s,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isMatch
                                          ? const Color(0xFF059669)
                                          : theme.colorScheme.onSurface,
                                      fontWeight: isMatch
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}
