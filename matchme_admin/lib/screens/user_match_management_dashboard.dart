import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';

/// Admin dashboard for permanently deleting users and matches.
///
/// - Users tab: global search via `admin_search_match_users`, then a
///   confirmed `admin_delete_user` call which wipes the user and ALL
///   related data (matches, chats, messages, ratings, profile data,
///   activity, ads, keys, storage metadata, public + auth rows).
/// - Matches tab: global search via `admin_search_matches`, then a
///   confirmed `admin_delete_match` call which wipes the match and ALL
///   match-scoped data (messages, chats rows, ratings, prompts) while
///   keeping both users. At confirmation time the admin chooses whether
///   the pair may be rematched by the system in the future or is blocked
///   permanently (unmatched_pairs.is_permanent).
///
/// Every user-facing string comes from the Supabase `translations` table
/// through [t], with an English fallback hard-coded here so the UI never
/// shows a raw key.

// ---------- Localization helpers (same rules as Match Inspector) ----------
// Kept local (instead of importing the inspector's privates) so each
// dashboard stays self-contained. Resolution order per field matches
// match_comparison_dashboard.dart: translation-table lookup first,
// pretty-printed English fallback last.
String _mmPrettySentence(String raw) {
  if (raw.trim().isEmpty) return '';
  var s = raw.replaceAll('::', ' ').replaceAll('_', ' ').trim().toLowerCase();
  if (s.isEmpty) return '';
  s = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  if (s.isEmpty) return '';
  return s[0].toUpperCase() + s.substring(1);
}

bool _mmIsMissing(String value, String key) {
  if (value.trim().isEmpty) return true;
  if (value == key) return true;
  if (value == '$key...') return true;
  return false;
}

String _mmTryKeys(
  List<String> keys,
  String Function(String, {Map<String, String>? params}) t,
) {
  for (final k in keys) {
    final v = t(k);
    if (!_mmIsMissing(v, k)) return v;
  }
  return '';
}

String _mmLocalizeGender(
  String raw,
  String Function(String, {Map<String, String>? params}) t,
) {
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final hit = _mmTryKeys(<String>[
    'gender_$trimmed',
    'gender.$trimmed',
    trimmed,
  ], t);
  if (hit.isNotEmpty) return hit;
  final withHyphen = trimmed.replaceAll('_', '-');
  return _mmPrettySentence(
    withHyphen,
  ).replaceAll(' -', '-').replaceAll('- ', '-');
}

String _mmLocalizeIntent(
  String raw,
  String Function(String, {Map<String, String>? params}) t,
) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final pascal = trimmed
      .split('_')
      .map(
        (w) =>
            w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join('');
  final hit = _mmTryKeys(<String>[
    trimmed,
    'intent.$trimmed',
    'intentCategory$pascal',
    'intent.category.$trimmed',
  ], t);
  if (hit.isNotEmpty) return hit;
  return _mmPrettySentence(trimmed);
}

String _mmLocalizeMatchType(
  String raw,
  String Function(String, {Map<String, String>? params}) t,
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
  final hit = _mmTryKeys(<String>[
    'matchInspectorMatchType$pascal',
    'matchType$pascal',
    trimmed,
  ], t);
  if (hit.isNotEmpty) return hit;
  return _mmPrettySentence(trimmed);
}

class AdminUserMatchManagementDashboard extends ConsumerStatefulWidget {
  const AdminUserMatchManagementDashboard({
    super.key,
    required this.t,
    required this.localeCode,
  });

  final String Function(String key, {Map<String, String>? params}) t;
  final String localeCode;

  @override
  ConsumerState<AdminUserMatchManagementDashboard> createState() =>
      _AdminUserMatchManagementDashboardState();
}

class _AdminUserMatchManagementDashboardState
    extends ConsumerState<AdminUserMatchManagementDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _userSearchController = TextEditingController();
  final _matchSearchController = TextEditingController();
  Timer? _userDebounce;
  Timer? _matchDebounce;

  List<Map<String, dynamic>> _userResults = const [];
  List<Map<String, dynamic>> _matchResults = const [];
  bool _usersLoading = false;
  bool _matchesLoading = false;
  bool _usersSearched = false;
  bool _matchesSearched = false;
  String? _usersError;
  String? _matchesError;
  String? _deletingUserId;
  String? _deletingMatchId;

  /// Translation with English fallback (mirrors match inspector's `tr`).
  /// [widget.t] reads the Supabase translations table; when the value is
  /// missing we fall back to the hard-coded English [fallback].
  String tr(
    String key, {
    Map<String, String>? params,
    required String fallback,
  }) {
    var s = widget.t(key, params: params);
    if (s.trim().isEmpty || s == key || s == '$key...') {
      s = fallback;
      if (params != null && params.isNotEmpty) {
        params.forEach((k, v) {
          s = s.replaceAll('{$k}', v);
        });
      }
    }
    return s;
  }

  String get _localeCode {
    final trimmed = widget.localeCode.trim().toLowerCase();
    return trimmed.isEmpty ? 'en' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Load an initial page so the admin sees content immediately.
    unawaited(_searchUsers(''));
    unawaited(_searchMatches(''));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _userDebounce?.cancel();
    _matchDebounce?.cancel();
    _userSearchController.dispose();
    _matchSearchController.dispose();
    super.dispose();
  }

  void _onUserQueryChanged(String v) {
    _userDebounce?.cancel();
    _userDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchUsers(v),
    );
  }

  void _onMatchQueryChanged(String v) {
    _matchDebounce?.cancel();
    _matchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchMatches(v),
    );
  }

  Future<void> _searchUsers(String query) async {
    if (!mounted) return;
    setState(() {
      _usersLoading = true;
      _usersError = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc(
            'admin_search_match_users',
            params: {'p_query': query.trim(), 'p_limit': 20},
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      final list = (res is List)
          ? res
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(growable: false)
          : const <Map<String, dynamic>>[];
      setState(() {
        _userResults = list;
        _usersLoading = false;
        _usersSearched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usersLoading = false;
        _usersSearched = true;
        _usersError = e.toString();
      });
    }
  }

  Future<void> _searchMatches(String query) async {
    if (!mounted) return;
    setState(() {
      _matchesLoading = true;
      _matchesError = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc(
            'admin_search_matches',
            params: {'p_query': query.trim(), 'p_limit': 20},
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      final list = (res is List)
          ? res
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(growable: false)
          : const <Map<String, dynamic>>[];
      setState(() {
        _matchResults = list;
        _matchesLoading = false;
        _matchesSearched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _matchesLoading = false;
        _matchesSearched = true;
        _matchesError = e.toString();
      });
    }
  }

  String _userDisplayName(Map<String, dynamic> u) {
    final name = (u['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    return (u['id'] ?? '').toString();
  }

  String _userAge(Map<String, dynamic> u) {
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

  String _formatDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    try {
      return DateFormat.yMMMd(_localeCode).add_jm().format(dt.toLocal());
    } catch (_) {
      return dt.toLocal().toString();
    }
  }

  Future<void> _confirmAndDeleteUser(Map<String, dynamic> user) async {
    final userId = (user['id'] ?? '').toString();
    if (userId.isEmpty || !mounted) return;

    // Offline guard: destructive RPCs must not run without connectivity.
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'adminUserMatchOfflineError',
              fallback: 'Cannot delete while offline.',
            ),
          ),
        ),
      );
      return;
    }

    // Self-delete guard: never let an admin wipe their own login.
    final currentId = Supabase.instance.client.auth.currentUser?.id;
    if (currentId != null && currentId == userId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'adminDeleteUserSelfError',
              fallback: 'You cannot delete your own admin account.',
            ),
          ),
        ),
      );
      return;
    }

    final name = _userDisplayName(user);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          size: 32,
          color: Colors.red,
        ),
        title: Text(
          tr('adminDeleteUserConfirmTitle', fallback: 'Delete user?'),
        ),
        content: Text(
          tr(
            'adminDeleteUserConfirmBody',
            params: {'name': name},
            fallback:
                'Permanently delete {name} and ALL related data (matches, chats, messages, photos, and settings)? This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('generalCancel', fallback: 'Cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('generalDelete', fallback: 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingUserId = userId);
    try {
      await Supabase.instance.client
          .rpc('admin_delete_user', params: {'p_user_id': userId})
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _deletingUserId = null;
        _userResults = _userResults
            .where((u) => (u['id'] ?? '').toString() != userId)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('adminDeleteUserSuccess', fallback: 'User deleted.'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingUserId = null);
      final rawError = e is PostgrestException ? e.message : e.toString();
      final msg = _friendlyRpcError(rawError);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'adminDeleteUserFailed',
              params: {'error': msg},
              fallback: 'Failed to delete user: {error}',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _confirmAndDeleteMatch(Map<String, dynamic> match) async {
    final matchId = (match['match_id'] ?? '').toString();
    if (matchId.isEmpty || !mounted) return;

    if (adminOfflineCacheManager.shouldUseCachedData()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'adminUserMatchOfflineError',
              fallback: 'Cannot delete while offline.',
            ),
          ),
        ),
      );
      return;
    }

    final a = (match['user1_name'] ?? '').toString().trim();
    final b = (match['user2_name'] ?? '').toString().trim();
    final info = (a.isNotEmpty && b.isNotEmpty)
        ? '$a ↔ $b'
        : matchId.length > 8
        ? matchId.substring(0, 8)
        : matchId;
    // Rematch choice, selected inside the confirmation dialog.
    // false = the system may match them again (default);
    // true = permanent block, they will never be matched again.
    var permanent = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            size: 32,
            color: Colors.red,
          ),
          title: Text(
            tr('adminDeleteMatchConfirmTitle', fallback: 'Delete match?'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'adminDeleteMatchConfirmBody',
                    params: {'info': info},
                    fallback:
                        'Permanently delete this match ({info}) and ALL related data (chats, messages, ratings)? The users will remain. This cannot be undone.',
                  ),
                ),
                const SizedBox(height: 12),
                RadioGroup<bool>(
                  groupValue: permanent,
                  onChanged: (v) =>
                      setDialogState(() => permanent = v ?? false),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<bool>(
                        value: false,
                        title: Text(
                          tr(
                            'adminDeleteMatchOptionRematch',
                            fallback: 'Allow future rematch',
                          ),
                        ),
                        subtitle: Text(
                          tr(
                            'adminDeleteMatchOptionRematchDesc',
                            fallback: 'The system may match these users again.',
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                      RadioListTile<bool>(
                        value: true,
                        title: Text(
                          tr(
                            'adminDeleteMatchOptionPermanent',
                            fallback: 'Never match again',
                          ),
                        ),
                        subtitle: Text(
                          tr(
                            'adminDeleteMatchOptionPermanentDesc',
                            fallback:
                                'These users will never be matched again.',
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('generalCancel', fallback: 'Cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('generalDelete', fallback: 'Delete')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingMatchId = matchId);
    try {
      await Supabase.instance.client
          .rpc(
            'admin_delete_match',
            params: {'p_match_id': matchId, 'p_permanent': permanent},
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _deletingMatchId = null;
        _matchResults = _matchResults
            .where((m) => (m['match_id'] ?? '').toString() != matchId)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            permanent
                ? tr(
                    'adminDeleteMatchSuccessPermanent',
                    fallback:
                        'Match deleted. The users will never be matched again.',
                  )
                : tr('adminDeleteMatchSuccess', fallback: 'Match deleted.'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingMatchId = null);
      final rawError = e is PostgrestException ? e.message : e.toString();
      final msg = _friendlyRpcError(rawError);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'adminDeleteMatchFailed',
              params: {'error': msg},
              fallback: 'Failed to delete match: {error}',
            ),
          ),
        ),
      );
    }
  }

  /// Shorten raw RPC/PostgREST errors for display in the failure snackbar.
  String _friendlyRpcError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('cannot delete own admin account')) {
      return tr(
        'adminDeleteUserSelfError',
        fallback: 'You cannot delete your own admin account.',
      );
    }
    if (lower.contains('user not found')) {
      return tr('adminUserMatchNoUsersFound', fallback: 'No users found.');
    }
    if (lower.contains('match not found')) {
      return tr('adminUserMatchNoMatchesFound', fallback: 'No matches found.');
    }
    if (lower.contains('not authorized')) {
      return 'not authorized';
    }
    // Keep it short: first line, capped.
    final first = raw.split('\n').first.trim();
    return first.length > 160 ? '${first.substring(0, 157)}...' : first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.errorContainer.withValues(alpha: 0.7),
                    theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                  ],
                  begin: AlignmentDirectional.topStart,
                  end: AlignmentDirectional.bottomEnd,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.error.withValues(alpha: 0.2),
                ),
              ),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.delete_forever_outlined,
                      color: theme.colorScheme.error,
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
                            'adminNavUserMatchManagement',
                            fallback: 'Users & Matches',
                          ),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  text: tr('adminUserMatchTabUsers', fallback: 'Users'),
                  icon: const Icon(Icons.person_outline, size: 20),
                ),
                Tab(
                  text: tr('adminUserMatchTabMatches', fallback: 'Matches'),
                  icon: const Icon(Icons.compare_arrows_outlined, size: 20),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildUsersTab(theme), _buildMatchesTab(theme)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersTab(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _userSearchController,
            onChanged: _onUserQueryChanged,
            decoration: InputDecoration(
              hintText: tr(
                'adminUserMatchSearchUsersHint',
                fallback: 'Search by name, email, or user ID...',
              ),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _userSearchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _userSearchController.clear();
                        _searchUsers('');
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
          const SizedBox(height: 12),
          Expanded(child: _buildUsersList(theme)),
        ],
      ),
    );
  }

  Widget _buildUsersList(ThemeData theme) {
    if (_usersLoading && !_usersSearched) {
      return Center(child: Text(tr('generalLoading', fallback: 'Loading...')));
    }
    if (_usersError != null && _userResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _usersError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
          ),
        ),
      );
    }
    if (_userResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
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
              _usersSearched
                  ? tr(
                      'adminUserMatchNoUsersFound',
                      fallback: 'No users found.',
                    )
                  : tr(
                      'adminUserMatchSearchPromptUsers',
                      fallback: 'Search for a user above to manage or delete.',
                    ),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        ListView.separated(
          itemCount: _userResults.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final user = _userResults[index];
            final userId = (user['id'] ?? '').toString();
            final name = _userDisplayName(user);
            final email = (user['email'] ?? '').toString().trim();
            final gender = (user['gender'] ?? '').toString().trim();
            final age = _userAge(user);
            final isDeleting = _deletingUserId == userId;
            final currentId = Supabase.instance.client.auth.currentUser?.id;
            final isSelf =
                currentId != null &&
                currentId.isNotEmpty &&
                currentId == userId;
            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                title: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (email.isNotEmpty)
                      _FieldRow(
                        header: tr('authEmail', fallback: 'Email'),
                        value: email,
                        forceLtrValue: true,
                      ),
                    _FieldRow(
                      header: tr('adminUserId', fallback: 'User ID'),
                      value: userId,
                      monospace: true,
                      forceLtrValue: true,
                    ),
                    if (gender.isNotEmpty)
                      _FieldRow(
                        header: tr('profileGender', fallback: 'Gender'),
                        value: _mmLocalizeGender(gender, widget.t),
                      ),
                    if (age.isNotEmpty)
                      _FieldRow(
                        header: tr('profileAgeLabel', fallback: 'Age'),
                        value: age,
                      ),
                  ],
                ),
                trailing: isDeleting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: isSelf
                              ? theme.disabledColor
                              : theme.colorScheme.error,
                        ),
                        tooltip: tr(
                          'adminUserMatchDeleteUserButton',
                          fallback: 'Delete user',
                        ),
                        onPressed: isSelf
                            ? () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr(
                                        'adminDeleteUserSelfError',
                                        fallback:
                                            'You cannot delete your own admin account.',
                                      ),
                                    ),
                                  ),
                                );
                              }
                            : () => _confirmAndDeleteUser(user),
                      ),
              ),
            );
          },
        ),
        if (_usersLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _buildMatchesTab(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _matchSearchController,
            onChanged: _onMatchQueryChanged,
            decoration: InputDecoration(
              hintText: tr(
                'adminUserMatchSearchMatchesHint',
                fallback: 'Search by match ID, user name, or user ID...',
              ),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _matchSearchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _matchSearchController.clear();
                        _searchMatches('');
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
          const SizedBox(height: 12),
          Expanded(child: _buildMatchesList(theme)),
        ],
      ),
    );
  }

  Widget _buildMatchesList(ThemeData theme) {
    if (_matchesLoading && !_matchesSearched) {
      return Center(child: Text(tr('generalLoading', fallback: 'Loading...')));
    }
    if (_matchesError != null && _matchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _matchesError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
          ),
        ),
      );
    }
    if (_matchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.compare_arrows_rounded,
                size: 40,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _matchesSearched
                  ? tr(
                      'adminUserMatchNoMatchesFound',
                      fallback: 'No matches found.',
                    )
                  : tr(
                      'adminUserMatchSearchPromptMatches',
                      fallback: 'Search for a match above to manage or delete.',
                    ),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        ListView.separated(
          itemCount: _matchResults.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final match = _matchResults[index];
            final matchId = (match['match_id'] ?? '').toString();
            final a = (match['user1_name'] ?? '').toString().trim();
            final b = (match['user2_name'] ?? '').toString().trim();
            final title = (a.isNotEmpty && b.isNotEmpty)
                ? '$a ↔ $b'
                : (matchId.length > 8
                      ? 'Match ${matchId.substring(0, 8)}…'
                      : 'Match $matchId');
            final type = (match['match_type'] ?? '').toString().trim();
            final intent = (match['matched_intent'] ?? '').toString().trim();
            final created = _formatDateTime(match['created_at']?.toString());
            final msgCount = (match['message_count'] is num)
                ? (match['message_count'] as num).toInt()
                : int.tryParse('${match['message_count'] ?? ''}') ?? 0;
            final isDeleting = _deletingMatchId == matchId;
            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FieldRow(
                      header: tr(
                        'adminUserMatchLabelMatchId',
                        fallback: 'Match ID',
                      ),
                      value: matchId,
                      monospace: true,
                      forceLtrValue: true,
                    ),
                    if (type.isNotEmpty)
                      _FieldRow(
                        header: tr('adminUserMatchLabelType', fallback: 'Type'),
                        value: _mmLocalizeMatchType(type, widget.t),
                      ),
                    if (intent.isNotEmpty)
                      _FieldRow(
                        header: tr(
                          'adminDrilldownSharedIntent',
                          fallback: 'Shared intent',
                        ),
                        value: _mmLocalizeIntent(intent, widget.t),
                      ),
                    _FieldRow(
                      header: tr(
                        'adminDrilldownMessages',
                        fallback: 'Messages',
                      ),
                      value: '$msgCount',
                    ),
                    if (created.isNotEmpty)
                      _FieldRow(
                        header: tr(
                          'adminDrilldownMatchedAt',
                          fallback: 'Matched',
                        ),
                        value: created,
                      ),
                  ],
                ),
                trailing: isDeleting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: theme.colorScheme.error,
                        ),
                        tooltip: tr(
                          'adminUserMatchDeleteMatchButton',
                          fallback: 'Delete match',
                        ),
                        onPressed: () => _confirmAndDeleteMatch(match),
                      ),
              ),
            );
          },
        ),
        if (_matchesLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// A single labeled field row: "Header: value".
/// Headers are localized labels; values wrap onto multiple lines so long
/// IDs are never truncated. Set [forceLtrValue] for IDs/emails so they
/// always render left-to-right, even in RTL locales.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.header,
    required this.value,
    this.monospace = false,
    this.forceLtrValue = false,
  });

  final String header;
  final String value;
  final bool monospace;
  final bool forceLtrValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayValue = forceLtrValue ? '\u2066$value\u2069' : value;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$header: ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: displayValue,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ],
        ),
        softWrap: true,
      ),
    );
  }
}
