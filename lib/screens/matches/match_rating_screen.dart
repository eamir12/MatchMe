import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/match_rating_service.dart';

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

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    final l10n = ref.read(localizationProvider);
    try {
      final answers = _answers.map((e) => e ?? 1).toList();
      await _service.submitRating(matchId: widget.matchId, answers: answers);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('ratingThanks'))),
      );
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('generalError'))),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final title = l10n.getString('ratingScreenTitle').replaceAll('{name}', widget.otherUserName);

    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.getString('ratingSubmit')),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StarRatingRow extends StatelessWidget {
  final int? value;
  final ValueChanged<int>? onChanged;

  const _StarRatingRow({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    const max = 5;
    final current = value ?? 0;

    return Row(
      children: [
        for (var i = 1; i <= max; i++)
          IconButton(
            onPressed: onChanged == null ? null : () => onChanged!(i),
            icon: Icon(
              i <= current ? Icons.star : Icons.star_border,
              color: i <= current ? Colors.amber : null,
            ),
          ),
      ],
    );
  }
}
