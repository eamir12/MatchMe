import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/screens/matches/match_rating_screen.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/widgets/due_rating_prompt_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _supabase = Supabase.instance.client;

class RatingPromptWatcher extends ConsumerStatefulWidget {
  const RatingPromptWatcher({super.key});

  @override
  ConsumerState<RatingPromptWatcher> createState() =>
      _RatingPromptWatcherState();
}

class _RatingPromptWatcherState extends ConsumerState<RatingPromptWatcher> {
  RealtimeChannel? _promptChannel;
  final Set<String> _dismissedMatchIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  Future<void> _initialize() async {
    if (shouldSkipSupabaseCalls()) return;
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    await _processExistingPrompts(userId);
    _subscribeToPrompts(userId);
  }

  Future<void> _processExistingPrompts(String userId) async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final rows = await _supabase
          .from('pending_rating_prompts')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: true);

      for (final row in rows) {
        await _handlePrompt(row);
      }
    } catch (e) {
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        print('Error processing existing rating prompts: $e');
      }
    }
  }

  void _subscribeToPrompts(String userId) {
    if (shouldSkipSupabaseCalls()) return;
    _promptChannel = _supabase
        .channel('rating_prompt_watcher_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pending_rating_prompts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            if (!mounted) return;
            _handlePrompt(payload.newRecord);
          },
        )
        .subscribe();
  }

  Future<void> _handlePrompt(Map<String, dynamic> row) async {
    if (!mounted) return;

    final matchId = (row['match_id'] ?? '').toString();
    if (_dismissedMatchIds.contains(matchId)) return;

    final otherUserId = (row['other_user_id'] ?? '').toString();
    final otherName = (row['other_name'] ?? '').toString();

    _dismissedMatchIds.add(matchId);

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DueRatingPromptDialog(
        matchId: matchId,
        otherUserId: otherUserId,
        otherName: otherName,
      ),
    );

    if (!mounted) return;

    final service = ref.read(matchRatingServiceProvider);

    if (result == 'yes') {
      try {
        await service.setMetAnswer(matchId: matchId, met: true);
        // Do NOT delete pending here - keep it until rating is submitted.
        // submit_match_rating (202618 migration) deletes pending server-side.
        // Keeping pending makes "Back" on rating screen act like "Later":
        // row stays, _dismissedMatchIds blocks same-session re-prompt,
        // _processExistingPrompts will show again next launch.
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MatchRatingScreen(
              matchId: matchId,
              otherUserId: otherUserId,
              otherUserName: otherName,
            ),
          ),
        );
      } catch (e) {
        print('Error processing rating prompt (yes): $e');
      }
    } else if (result == 'no') {
      try {
        await service.setMetAnswer(matchId: matchId, met: false);
        await _deletePendingRow(matchId);
      } catch (e) {
        print('Error processing rating prompt (no): $e');
      }
    }
    // 'later' — row stays in DB; cron will re-insert on next run.
    // In-memory _dismissedMatchIds prevents re-prompting this session.
  }

  Future<void> _deletePendingRow(String matchId) async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      await _supabase
          .from('pending_rating_prompts')
          .delete()
          .eq('user_id', userId)
          .eq('match_id', matchId);
    } catch (e) {
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        print('Error deleting pending rating prompt: $e');
      }
    }
  }

  @override
  void dispose() {
    _promptChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
