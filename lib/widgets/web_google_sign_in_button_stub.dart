import 'package:flutter/material.dart';

/// A widget that renders the "Sign In With Google" button on Web.
/// On other platforms, it returns a placeholder or throws.
class WebGoogleSignInButton extends StatelessWidget {
  final Future<void> Function()? onSignIn;

  const WebGoogleSignInButton({super.key, this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
