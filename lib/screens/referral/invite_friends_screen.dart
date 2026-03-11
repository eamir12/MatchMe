import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/referral_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/providers/locale_provider.dart';

class InviteFriendsScreen extends ConsumerStatefulWidget {
  const InviteFriendsScreen({super.key});

  @override
  ConsumerState<InviteFriendsScreen> createState() => _InviteFriendsScreenState();
}

class _InviteFriendsScreenState extends ConsumerState<InviteFriendsScreen> {
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Defer the check to next frame to avoid provider issues during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureReferralCode();
    });
  }

  Future<void> _ensureReferralCode() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    
    final userProfile = await ref.read(userProfileProvider(user.id).future);
    
    if (userProfile != null && (userProfile.referralCode == null || userProfile.referralCode!.isEmpty)) {
      if (mounted) setState(() => _isLoading = true);
      await ref.read(referralServiceProvider).generateReferralCodeIfNeeded(user.id, userProfile.referralCode);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _shareLink(String code) async {
    final l10n = ref.read(localizationProvider);
    // Fetch base URL from app config, default to custom scheme if not set
    final appConfig = AppConfigService();
    final baseUrl = await appConfig.getString('referral.base_url', defaultValue: 'matchme://invite');
    
    final separator = baseUrl.contains('?') ? '&' : '?';
    final link = '$baseUrl${separator}code=$code'; 
    
    await SharePlus.instance.share(
      ShareParams(
        text: l10n.getString(
          'inviteFriendsShareMessage',
          params: {'code': code, 'link': link},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      return Scaffold(
        body: Center(child: Text(l10n.getString('commonPleaseLogIn'))),
      );
    }

    final userProfileAsync = ref.watch(userProfileProvider(userId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.getString('inviteFriendsTitle'))),
      body: userProfileAsync.when(
        data: (profile) {
          if (profile == null) {
            return Center(child: Text(l10n.getString('commonProfileNotFound')));
          }
          
          final code = profile.referralCode;

          if (_isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          
          if (code == null) {
             // This happens if _ensureReferralCode hasn't finished or failed
             return Center(
               child: Padding(
                 padding: const EdgeInsets.all(24.0),
                 child: Column(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                     const SizedBox(height: 16),
                     Text(
                       l10n.getString('inviteFriendsError'),
                       style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                     ),
                     const SizedBox(height: 8),
                     Text(
                       l10n.getString('inviteFriendsCheckConnection'),
                       textAlign: TextAlign.center,
                       style: const TextStyle(color: Colors.grey),
                     ),
                     const SizedBox(height: 24),
                     ElevatedButton(
                       onPressed: () {
                         if (mounted) setState(() => _isLoading = true);
                         _ensureReferralCode();
                       },
                       child: Text(l10n.getString('inviteFriendsRetry')),
                     ),
                   ],
                 ),
               ),
             );
          }

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                Icon(Icons.card_giftcard, size: 80, color: Theme.of(context).colorScheme.secondary),
                const SizedBox(height: 24),
                Text(
                  l10n.getString('inviteFriendsSubtitle'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.getString('inviteFriendsDescription'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        code,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.getString('inviteFriendsCopied'))),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _shareLink(code),
                    icon: const Icon(Icons.share),
                    label: Text(l10n.getString('inviteFriendsShareBtn')),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                 Text(
                  l10n.getString('inviteFriendsCredits', params: {'0': profile.credits.toString()}),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
              ],
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(
          child: Text(
            l10n.getString(
              'commonErrorWithDetails',
              params: {'error': e.toString()},
            ),
          ),
        ),
      ),
    );
  }
}
