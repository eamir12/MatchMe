import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Dialog for collecting user consent for ads
class AdConsentDialog extends ConsumerStatefulWidget {
  const AdConsentDialog({
    super.key,
    this.onConsent,
    this.privacyPolicyUrl = 'https://example.com/privacy',
  });

  final Function(bool personalizedAds, bool nonPersonalizedAds)? onConsent;
  final String privacyPolicyUrl;

  @override
  ConsumerState<AdConsentDialog> createState() => _AdConsentDialogState();
}

class _AdConsentDialogState extends ConsumerState<AdConsentDialog> {
  bool _personalizedAds = false;
  bool _nonPersonalizedAds = true;
  bool _isLoading = false;

  Future<void> _handleConsent() async {
    // Validate at least one option is selected
    if (!_personalizedAds && !_nonPersonalizedAds) {
      _showError(
        ref.read(localizationProvider).getString('externalAdsAtLeastOneOption'),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final consentService = ref.read(adConsentServiceProvider);
      final result = await consentService.updateUserConsent(
        personalizedAds: _personalizedAds,
        nonPersonalizedAds: _nonPersonalizedAds,
      );

      if (result != null && mounted) {
        widget.onConsent?.call(_personalizedAds, _nonPersonalizedAds);
        Navigator.of(context).pop(true);
      } else if (mounted) {
        _showError(
          ref.read(localizationProvider).getString('externalAdsSaveFailed'),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError(
          '${ref.read(localizationProvider).getString('generalError')}: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openPrivacyPolicy() async {
    try {
      final uri = Uri.tryParse(widget.privacyPolicyUrl);
      if (uri != null && uri.hasScheme) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _showError(
        ref
            .read(localizationProvider)
            .getString('externalAdsCouldNotOpenPrivacy'),
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      title: Text(l10n.getString('externalAdsConsentTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Text(
              l10n.getString('externalAdsConsentBody'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),

            // Personalized ads checkbox
            CheckboxListTile(
              title: Text(l10n.getString('externalAdsPersonalizedOption')),
              value: _personalizedAds,
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() => _personalizedAds = value ?? false);
                    },
              contentPadding: EdgeInsets.zero,
            ),

            // Non-personalized ads checkbox
            CheckboxListTile(
              title: Text(l10n.getString('externalAdsNonPersonalizedOption')),
              value: _nonPersonalizedAds,
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() => _nonPersonalizedAds = value ?? false);
                    },
              contentPadding: EdgeInsets.zero,
            ),

            const SizedBox(height: 12),

            // Privacy policy link
            TextButton(
              onPressed: _isLoading ? null : _openPrivacyPolicy,
              child: Text(l10n.getString('externalAdsPrivacyLink')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.getString('generalCancel')),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleConsent,
          child: _isLoading
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.onPrimary,
                    ),
                  ),
                )
              : Text(l10n.getString('externalAdsAcceptButton')),
        ),
      ],
    );
  }
}
