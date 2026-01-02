// lib/screens/profile/profile_edit_screen.dart
// Legacy entry point kept for backwards-compatibility.
// Immediately redirects to ProfileWizardScreen so all edits use the wizard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:matchme/providers/locale_provider.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  final String userId;
  const ProfileEditScreen({super.key, required this.userId});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    // Defer navigation to next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_navigated) return;
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        _navigated = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => ProfileWizardScreen(user: user, isEditing: true))
        );
      } else {
        // No current user available - stay on this screen and show an error UI below
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    // Fallback UI in case navigation fails (no auth user)
    return Scaffold(
      appBar: AppBar(title: Text(l10n.getString('profileEditTitle'))),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(l10n.getString('generalErrorLoadingProfile')),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                final user = Supabase.instance.client.auth.currentUser;
                if (user != null) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => ProfileWizardScreen(user: user, isEditing: true))
                  );
                }
              },
              child: Text(l10n.getString('generalRetry')),
            ),
          ],
        ),
      ),
    );
  }
}
