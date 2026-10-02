import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Web-specific ad consent banner
///
/// This banner appears at the bottom of the web page to collect
/// user consent for personalized ads, as required by GDPR and other regulations.
///
/// Features:
/// - Sticky positioning at bottom of screen
/// - Accept/Reject buttons
/// - Link to privacy policy
/// - Dismissible after user choice
class WebAdConsentBanner extends ConsumerStatefulWidget {
  const WebAdConsentBanner({super.key, this.onConsentChanged});

  final Function(bool personalizedAds)? onConsentChanged;

  @override
  ConsumerState<WebAdConsentBanner> createState() => _WebAdConsentBannerState();
}

class _WebAdConsentBannerState extends ConsumerState<WebAdConsentBanner> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _checkConsentStatus();
  }

  Future<void> _checkConsentStatus() async {
    // For now, we'll assume no consent has been given
    // In a real app, you'd check the current user's consent status
    setState(() {
      _dismissed = false;
    });
  }

  Future<void> _handleAccept() async {
    final consentService = ref.read(adConsentServiceProvider);
    await consentService.optInToPersonalizedAds();
    widget.onConsentChanged?.call(true);
    setState(() {
      _dismissed = true;
    });
  }

  Future<void> _handleReject() async {
    final consentService = ref.read(adConsentServiceProvider);
    await consentService.optOutOfPersonalizedAds();
    widget.onConsentChanged?.call(false);
    setState(() {
      _dismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const SizedBox.shrink();
    }

    final l10n = ref.watch(localizationProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.getString('adConsentTitle'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.getString('adConsentDescription'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[300]),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    // TODO: Navigate to privacy policy
                  },
                  child: Text(
                    l10n.getString('adConsentPrivacyLink'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.blue[300],
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: _handleAccept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                child: Text(l10n.getString('adConsentAccept')),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _handleReject,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.grey),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                child: Text(l10n.getString('actionReject')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact web ad consent banner (for mobile web)
class CompactWebAdConsentBanner extends ConsumerStatefulWidget {
  const CompactWebAdConsentBanner({super.key, this.onConsentChanged});

  final Function(bool personalizedAds)? onConsentChanged;

  @override
  ConsumerState<CompactWebAdConsentBanner> createState() =>
      _CompactWebAdConsentBannerState();
}

class _CompactWebAdConsentBannerState
    extends ConsumerState<CompactWebAdConsentBanner> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _checkConsentStatus();
  }

  Future<void> _checkConsentStatus() async {
    // For now, we'll assume no consent has been given
    // In a real app, you'd check the current user's consent status
    setState(() {
      _dismissed = false;
    });
  }

  Future<void> _handleAccept() async {
    final consentService = ref.read(adConsentServiceProvider);
    await consentService.optInToPersonalizedAds();
    widget.onConsentChanged?.call(true);
    setState(() {
      _dismissed = true;
    });
  }

  Future<void> _handleReject() async {
    final consentService = ref.read(adConsentServiceProvider);
    await consentService.optOutOfPersonalizedAds();
    widget.onConsentChanged?.call(false);
    setState(() {
      _dismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const SizedBox.shrink();
    }

    final l10n = ref.watch(localizationProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.getString('adConsentCompactDescription'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey[300]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: _handleAccept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                child: Text(
                  l10n.getString('adConsentAccept'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _handleReject,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.grey),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                child: Text(
                  l10n.getString('actionReject'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
