import 'package:flutter/material.dart';

enum CaptchaReason { registration, loginProtection }

class CaptchaWidget extends StatelessWidget {
  final Function(String) onSuccess;
  final Function(String) onError;
  final String locale;
  final CaptchaReason reason;

  const CaptchaWidget({
    required this.onSuccess,
    required this.onError,
    required this.locale,
    required this.reason,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.shrink();
  }
}
