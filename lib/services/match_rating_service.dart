import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/app_config_service.dart';

final _supabase = Supabase.instance.client;

class RatingQuestion {
  final String id;
  final String translationKey;
  final int order;
  final bool enabled;

  const RatingQuestion({
    required this.id,
    required this.translationKey,
    required this.order,
    required this.enabled,
  });

  factory RatingQuestion.fromJson(Map<String, dynamic> json) {
    return RatingQuestion(
      id: (json['id'] ?? '').toString(),
      translationKey: (json['translationKey'] ?? '').toString(),
      order: int.tryParse((json['order'] ?? '').toString()) ?? 0,
      enabled: (json['enabled'] is bool) ? json['enabled'] as bool : true,
    );
  }
}

class UserRatingSummary {
  final int ratedByCount;
  final double? q1Avg;
  final double? q2Avg;
  final double? q3Avg;
  final double? q4Avg;
  final double? q5Avg;
  final double? overallAvg;

  const UserRatingSummary({
    required this.ratedByCount,
    required this.q1Avg,
    required this.q2Avg,
    required this.q3Avg,
    required this.q4Avg,
    required this.q5Avg,
    required this.overallAvg,
  });

  factory UserRatingSummary.fromRpcRow(Map<String, dynamic> row) {
    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return UserRatingSummary(
      ratedByCount: int.tryParse((row['rated_by_count'] ?? 0).toString()) ?? 0,
      q1Avg: toDouble(row['q1_avg']),
      q2Avg: toDouble(row['q2_avg']),
      q3Avg: toDouble(row['q3_avg']),
      q4Avg: toDouble(row['q4_avg']),
      q5Avg: toDouble(row['q5_avg']),
      overallAvg: toDouble(row['overall_avg']),
    );
  }
}

class DueRatingPrompt {
  final String matchId;
  final String otherUserId;
  final String otherName;
  final DateTime matchCreatedAt;
  final bool otherUserMetConfirmed;
  final bool selfMetConfirmed;

  const DueRatingPrompt({
    required this.matchId,
    required this.otherUserId,
    required this.otherName,
    required this.matchCreatedAt,
    required this.otherUserMetConfirmed,
    required this.selfMetConfirmed,
  });

  factory DueRatingPrompt.fromRpcRow(Map<String, dynamic> row) {
    String maskName(String raw) {
      final s = raw.toString().trim();
      if (s.isEmpty) return s;
      final parts = s.split(RegExp(r'\s+')).where((p) => p.trim().isNotEmpty).toList(growable: false);
      if (parts.isEmpty) return s;
      if (parts.length == 1) return parts.first;
      final first = parts.first;
      final last = parts.last;
      if (last.isEmpty) return first;
      return '$first ${last[0].toUpperCase()}.';
    }

    return DueRatingPrompt(
      matchId: (row['match_id'] ?? '').toString(),
      otherUserId: (row['other_user_id'] ?? '').toString(),
      otherName: maskName(row['other_name'] ?? ''),
      matchCreatedAt: row['match_created_at'] != null
          ? DateTime.parse(row['match_created_at'].toString())
          : DateTime.now(),
      otherUserMetConfirmed: (row['other_user_met_confirmed'] is bool)
          ? row['other_user_met_confirmed'] as bool
          : false,
      selfMetConfirmed:
          (row['self_met_confirmed'] is bool) ? row['self_met_confirmed'] as bool : false,
    );
  }
}

class MatchRatingService {
  static final Map<String, double?> _myMatchOverallRatingCache = <String, double?>{};
  static final Set<String> _myMatchOverallRatingLoaded = <String>{};

  Future<bool> hasUserRatedMatch(String matchId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return false;
    final row = await _supabase
        .from('match_ratings')
        .select('id')
        .eq('match_id', matchId)
        .eq('rater_id', userId)
        .maybeSingle();
    return row != null;
  }

  Future<double?> getMyOverallRatingForMatch(String matchId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return null;

    if (_myMatchOverallRatingLoaded.contains(matchId)) {
      return _myMatchOverallRatingCache[matchId];
    }

    final row = await _supabase
        .from('match_ratings')
        .select('q1,q2,q3,q4,q5')
        .eq('match_id', matchId)
        .eq('rater_id', userId)
        .maybeSingle();

    _myMatchOverallRatingLoaded.add(matchId);
    if (row == null) {
      _myMatchOverallRatingCache[matchId] = null;
      return null;
    }

    final q1 = int.tryParse((row['q1'] ?? '').toString()) ?? 0;
    final q2 = int.tryParse((row['q2'] ?? '').toString()) ?? 0;
    final q3 = int.tryParse((row['q3'] ?? '').toString()) ?? 0;
    final q4 = int.tryParse((row['q4'] ?? '').toString()) ?? 0;
    final q5 = int.tryParse((row['q5'] ?? '').toString()) ?? 0;
    final avg = (q1 + q2 + q3 + q4 + q5) / 5.0;
    _myMatchOverallRatingCache[matchId] = avg;
    return avg;
  }

  Future<bool> isEnabled() async {
    return appConfigService.getBool('ratings.enabled', defaultValue: true);
  }

  Future<int> getScaleMin() async {
    return appConfigService.getInt('ratings.scale_min', defaultValue: 1);
  }

  Future<int> getScaleMax() async {
    return appConfigService.getInt('ratings.scale_max', defaultValue: 5);
  }

  Future<int> getPromptInitialDelaySeconds() async {
    return appConfigService.getInt('ratings.prompt_initial_delay_seconds', defaultValue: 20 * 60 * 60);
  }

  Future<int> getPromptRepeatDelaySeconds() async {
    return appConfigService.getInt('ratings.prompt_repeat_delay_seconds', defaultValue: 72 * 60 * 60);
  }

  Future<int> getDisplayMinCount() async {
    return appConfigService.getInt('ratings.display_min_count', defaultValue: 5);
  }

  Future<int?> getAggregateLastN() async {
    final raw = await appConfigService.getInt('ratings.aggregate_last_n', defaultValue: 0);
    if (raw <= 0) return null;
    return raw;
  }

  Future<List<RatingQuestion>> getQuestions() async {
    final raw = await appConfigService.getList('ratings.questions', defaultValue: const []);
    final questions = <RatingQuestion>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        questions.add(RatingQuestion.fromJson(item));
      } else if (item is Map) {
        questions.add(RatingQuestion.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    questions.sort((a, b) => a.order.compareTo(b.order));
    return questions.where((q) => q.enabled && q.translationKey.isNotEmpty).toList();
  }

  Future<DueRatingPrompt?> getNextDuePrompt({int limit = 1}) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return null;
    final enabled = await isEnabled();
    if (!enabled) return null;

    final initialDelaySeconds = await getPromptInitialDelaySeconds();
    final result = await _supabase.rpc(
      'get_due_match_rating_prompts',
      params: {
        'p_user_id': userId,
        'p_initial_delay_seconds': initialDelaySeconds,
        'p_limit': limit,
      },
    );

    final rows = (result is List) ? result : <dynamic>[];
    if (rows.isEmpty) return null;
    return DueRatingPrompt.fromRpcRow(Map<String, dynamic>.from(rows.first as Map));
  }

  Future<void> setMetAnswer({
    required String matchId,
    required bool met,
  }) async {
    final repeatDelaySeconds = await getPromptRepeatDelaySeconds();
    await _supabase.rpc(
      'set_match_met_answer',
      params: {
        'p_match_id': matchId,
        'p_met': met,
        'p_repeat_delay_seconds': repeatDelaySeconds,
      },
    );
  }

  Future<void> submitRating({
    required String matchId,
    required List<int> answers,
  }) async {
    if (answers.length < 5) {
      throw ArgumentError('answers_must_have_5_values');
    }
    await _supabase.rpc(
      'submit_match_rating',
      params: {
        'p_match_id': matchId,
        'p_q1': answers[0],
        'p_q2': answers[1],
        'p_q3': answers[2],
        'p_q4': answers[3],
        'p_q5': answers[4],
      },
    );

    _myMatchOverallRatingLoaded.add(matchId);
    _myMatchOverallRatingCache[matchId] =
        (answers[0] + answers[1] + answers[2] + answers[3] + answers[4]) / 5.0;
  }

  Future<UserRatingSummary> getUserRatingSummary(String userId) async {
    final minCount = await getDisplayMinCount();
    final lastN = await getAggregateLastN();
    final params = <String, dynamic>{
      'p_user_id': userId,
      'p_min_count': minCount,
    };
    if (lastN != null) {
      params['p_last_n'] = lastN;
    }

    final result = await _supabase.rpc('get_user_rating_summary', params: params);
    final rows = (result is List) ? result : <dynamic>[];
    if (rows.isEmpty) {
      return const UserRatingSummary(
        ratedByCount: 0,
        q1Avg: null,
        q2Avg: null,
        q3Avg: null,
        q4Avg: null,
        q5Avg: null,
        overallAvg: null,
      );
    }
    return UserRatingSummary.fromRpcRow(Map<String, dynamic>.from(rows.first as Map));
  }
}
