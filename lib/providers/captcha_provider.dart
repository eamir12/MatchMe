import 'package:flutter_riverpod/flutter_riverpod.dart';

class CaptchaState {
  final bool isVerified;
  final String? token;

  CaptchaState({required this.isVerified, this.token});

  CaptchaState copyWith({bool? isVerified, String? token}) {
    return CaptchaState(
      isVerified: isVerified ?? this.isVerified,
      token: token ?? this.token,
    );
  }
}

class CaptchaNotifier extends Notifier<CaptchaState> {
  @override
  CaptchaState build() {
    return CaptchaState(isVerified: false);
  }

  void setVerified(String token) {
    state = state.copyWith(isVerified: true, token: token);
  }

  void reset() {
    state = CaptchaState(isVerified: false);
  }
}

final captchaProvider = NotifierProvider<CaptchaNotifier, CaptchaState>(() {
  return CaptchaNotifier();
});
