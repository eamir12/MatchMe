import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/turnstile_challenge_dialog.dart';
import 'package:matchme/widgets/turnstile_challenge_shared.dart';

enum TurnstileAuthAction {
  signUp('sign_up'),
  passwordLogin('password_login');

  const TurnstileAuthAction(this.value);

  final String value;
}

class TurnstileService {
  static const String _verifyFunctionName = 'verify-turnstile';

  static String get siteKey {
    const fromDefine = String.fromEnvironment(
      'TURNSTILE_SITE_KEY',
      defaultValue: '',
    );
    if (fromDefine.trim().isNotEmpty) {
      return fromDefine.trim();
    }
    if (dotenv.isInitialized) {
      return (dotenv.env['TURNSTILE_SITE_KEY'] ?? '').trim();
    }
    return '';
  }

  static bool get isConfigured => siteKey.isNotEmpty;

  static Future<String?> requestToken({
    required BuildContext context,
    required LocalizationState l10n,
    required TurnstileAuthAction action,
  }) async {
    final resolvedSiteKey = siteKey;
    if (resolvedSiteKey.isEmpty) {
      throw Exception(l10n.getString('authCaptchaMissingConfig'));
    }

    final request = TurnstileChallengeRequest(
      siteKey: resolvedSiteKey,
      action: action.value,
      title: l10n.getString('authCaptchaTitle'),
      description: action == TurnstileAuthAction.signUp
          ? l10n.getString('authCaptchaSignUpBody')
          : l10n.getString('authCaptchaLoginBody'),
      cancelLabel: l10n.getString('generalCancel'),
      retryLabel: l10n.getString('generalRetry'),
      preparingMessage: l10n.getString('authCaptchaPreparing'),
      promptMessage: l10n.getString('authCaptchaPrompt'),
      completeMessage: l10n.getString('authCaptchaComplete'),
      failedRetryMessage: l10n.getString('authCaptchaFailedRetry'),
      failedWithErrorMessage: l10n.getString('authCaptchaFailedWithError'),
      expiredRetryMessage: l10n.getString('authCaptchaExpiredRetry'),
      timedOutRetryMessage: l10n.getString('authCaptchaTimedOutRetry'),
      emptyTokenMessage: l10n.getString('authCaptchaEmptyToken'),
    );

    final result = await showTurnstileChallengeDialog(
      context: context,
      request: request,
    );
    return result?.token;
  }

  static Future<void> verifyToken({
    required String token,
    required TurnstileAuthAction action,
    required LocalizationState l10n,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      _verifyFunctionName,
      body: {'token': token, 'action': action.value},
    );

    final ok =
        response.status >= 200 &&
        response.status < 300 &&
        response.data is Map &&
        (response.data as Map)['success'] == true;
    if (ok) {
      return;
    }

    String? message;
    final data = response.data;
    if (data is Map) {
      final raw = data['message'] ?? data['error'];
      if (raw != null) {
        message = raw.toString().trim();
      }
    }

    throw Exception(
      message == null || message.isEmpty
          ? l10n.getString('authCaptchaVerificationFailed')
          : message,
    );
  }
}
