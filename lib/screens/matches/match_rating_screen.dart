import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MatchRatingScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;

  const MatchRatingScreen({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
  });

  @override
  ConsumerState<MatchRatingScreen> createState() => _MatchRatingScreenState();
}

class _MatchRatingScreenState extends ConsumerState<MatchRatingScreen> {
  final _service = MatchRatingService();

  bool _submitting = false;
  bool _checkingAlreadyRated = true;
  List<RatingQuestion> _questions = const [];
  List<int?> _answers = const [];
  bool _bypassLaterHandler = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final alreadyRated = await _service.hasUserRatedMatch(widget.matchId);
    if (alreadyRated) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _bypassLaterHandler = true;
        Navigator.of(context).pop(false);
      });
      return;
    }

    final enabled = await _service.isEnabled();
    if (!enabled) {
      if (!mounted) return;
      setState(() => _checkingAlreadyRated = false);
      return;
    }

    final questions = await _service.getQuestions();
    final firstFive = questions.take(5).toList();
    if (!mounted) return;
    setState(() {
      _questions = firstFive;
      _answers = List<int?>.filled(firstFive.length, null);
      _checkingAlreadyRated = false;
    });
  }

  bool get _canSubmit {
    if (_submitting) return false;
    if (_questions.length != 5) return false;
    return _answers.length == 5 && _answers.every((a) => a != null);
  }

  Future<void> _handleBackAsLater() async {
    // Back on rating questions should act like "Later" on Did-you-meet dialog:
    // keep pending for next session / re-make it due if it was already deleted.
    if (_submitting) return;
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null || widget.matchId.isEmpty) return;
      final hasRated = await _service.hasUserRatedMatch(widget.matchId);
      if (hasRated) return;
      // Make the prompt due again so check_all_due_rating_prompts can re-insert pending.
      // This covers legacy stranded rows where Yes+Back deleted pending and left next_prompt_at=NULL.
      try {
        await Supabase.instance.client
            .from('match_rating_prompts')
            .update({'next_prompt_at': DateTime.now().toIso8601String()})
            .eq('match_id', widget.matchId)
            .eq('user_id', userId);
      } catch (_) {}
      // Trigger immediate pending recreation (zero-arg overload after 20260702000001 fix).
      try {
        await Supabase.instance.client.rpc('check_all_due_rating_prompts');
      } catch (_) {
        // Fallback for envs where integer overload still exists
        try {
          await Supabase.instance.client.rpc(
            'check_all_due_rating_prompts',
            params: {'p_initial_delay_seconds': 259200},
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    final l10n = ref.read(localizationProvider);
    try {
      final answers = _answers.map((e) => e ?? 1).toList();
      await _service.submitRating(matchId: widget.matchId, answers: answers);
      // Refresh the rated user's aggregate immediately on this device; other
      // matched viewers are notified via the rating_updates broadcast sent
      // inside submitRating (+ the DB trigger on any match_ratings write).
      try {
        if (widget.otherUserId.isNotEmpty) {
          ref.invalidate(userRatingSummaryProvider(widget.otherUserId));
        }
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.getString('ratingThanks'))));
      _bypassLaterHandler = true;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.getString('generalError'))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final title = l10n
        .getString('ratingScreenTitle')
        .replaceAll('{name}', widget.otherUserName);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) return;
        // didPop true means route already popped - run Later logic after.
        // Bypass for submit/alreadyRated which pop with result true/false explicitly
        if (_bypassLaterHandler) {
          _bypassLaterHandler = false;
          return;
        }
        if (_submitting) return;
        // Back without result (system back or AppBar back) -> treat as Later
        if (result == null) {
          await _handleBackAsLater();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_submitting) return;
              Navigator.of(context).pop();
            },
          ),
        ),
        body: SafeArea(
          child: _checkingAlreadyRated
              ? const Center(child: CircularProgressIndicator())
              : _questions.length != 5
              ? Center(child: Text(l10n.getString('generalError')))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (var i = 0; i < _questions.length; i++) ...[
                      Text(
                        l10n.getString(_questions[i].translationKey),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      _StarRatingRow(
                        value: _answers[i],
                        onChanged: _submitting
                            ? null
                            : (v) {
                                setState(() {
                                  final next = [..._answers];
                                  next[i] = v;
                                  _answers = next;
                                });
                              },
                      ),
                      const SizedBox(height: 20),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _canSubmit ? _submit : null,
                        child: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l10n.getString('ratingSubmit')),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _StarRatingRow extends StatelessWidget {
  final int? value;
  final ValueChanged<int>? onChanged;

  const _StarRatingRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const max = 5;
    final current = value ?? 0;

    return Row(
      children: [
        for (var i = 1; i <= max; i++)
          Tooltip(
            message: '$i / $max',
            child: IconButton(
              onPressed: onChanged == null ? null : () => onChanged!(i),
              icon: Icon(
                i <= current ? Icons.star : Icons.star_border,
                color: i <= current ? Colors.amber : null,
              ),
            ),
          ),
      ],
    );
  }
}
