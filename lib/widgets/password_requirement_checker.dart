import 'package:flutter/material.dart';

class PasswordRequirementChecker extends StatelessWidget {
  final String password;
  final String locale;

  const PasswordRequirementChecker({
    required this.password,
    required this.locale,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.shrink();
  }
}
