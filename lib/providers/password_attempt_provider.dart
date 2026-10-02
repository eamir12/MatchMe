import 'package:flutter_riverpod/flutter_riverpod.dart';

class PasswordAttemptState {
  final int failedAttempts;
  final bool isCaptchaRequired;

  PasswordAttemptState({
    required this.failedAttempts,
    required this.isCaptchaRequired,
  });

  PasswordAttemptState copyWith({
    int? failedAttempts,
    bool? isCaptchaRequired,
  }) {
    return PasswordAttemptState(
      failedAttempts: failedAttempts ?? this.failedAttempts,
      isCaptchaRequired: isCaptchaRequired ?? this.isCaptchaRequired,
    );
  }
}

class PasswordAttemptNotifier extends Notifier<PasswordAttemptState> {
  @override
  PasswordAttemptState build() {
    return PasswordAttemptState(failedAttempts: 0, isCaptchaRequired: false);
  }

  void incrementFailedAttempts() {
    final newAttempts = state.failedAttempts + 1;
    state = state.copyWith(
      failedAttempts: newAttempts,
      isCaptchaRequired: newAttempts >= 3,
    );
  }

  void resetAttempts() {
    state = PasswordAttemptState(failedAttempts: 0, isCaptchaRequired: false);
  }
}

final passwordAttemptProvider =
    NotifierProvider<PasswordAttemptNotifier, PasswordAttemptState>(() {
      return PasswordAttemptNotifier();
    });
