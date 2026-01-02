// lib/providers/auth_provider.dart
// ...existing code...
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// This creates a stream that notifies the app when the auth state changes
final authStateProvider = StreamProvider<AuthState>((ref) {
  // Call Supabase.instance.client directly
  return Supabase.instance.client.auth.onAuthStateChange.map((authState) {
    return authState;
  }).handleError((error, stackTrace) {
    // Handle specific auth errors gracefully
    if (error is AuthException) {
      if (error.message.contains('Code verifier could not be found')) {
        // Check if this is a deep link scenario by looking at the URL
        final currentUrl = Uri.base.toString();
        final hasAuthCode = currentUrl.contains('code=');

        if (hasAuthCode) {
          // This is likely a password reset deep link issue - let it propagate to show error screen
          throw error;
        } else {
          // This is a normal PKCE issue, ignore it
          return; // Skip emitting the error
        }
      } else if (error.message.contains('sign out') || error.message.contains('logout') ||
                 error.message.contains('session') || error.message.contains('token') ||
                 error.message.contains('invalid') || error.message.contains('expired')) {
        // Handle logout/session related errors by ignoring them
        // This allows the auth state to naturally transition to signed out
        return;
      }
    }
    // Re-throw other errors
    throw error;
  });
});
