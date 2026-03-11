import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/match_rating_service.dart';

final matchRatingServiceProvider = Provider<MatchRatingService>((ref) {
  return MatchRatingService();
});

final ratingQuestionsProvider = FutureProvider<List<RatingQuestion>>((ref) async {
  final service = ref.read(matchRatingServiceProvider);
  return service.getQuestions();
});

final userRatingSummaryProvider = FutureProvider.family<UserRatingSummary, String>((ref, userId) async {
  final service = ref.read(matchRatingServiceProvider);
  return service.getUserRatingSummary(userId);
});

