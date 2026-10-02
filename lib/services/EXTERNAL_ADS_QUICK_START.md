# External Ads System - Quick Start Guide

## Overview
This guide explains how to use the external ad network system in your Flutter app.

## Services

### 1. ExternalAdService
Core service for ad operations.

```dart
final adService = ref.read(externalAdServiceProvider);

// Get ad for placement
final ad = await adService.getExternalAdForPlacement(
  placement: 'home_inline',
  platform: 'android',
);

// Record impression
await adService.recordImpression(
  networkId: ad.networkId,
  adUnitId: ad.id,
  placement: ad.placement,
  platform: 'android',
  adFormat: ad.adFormat,
);

// Record click
await adService.recordClick(
  networkId: ad.networkId,
  adUnitId: ad.id,
  placement: ad.placement,
  platform: 'android',
  adFormat: ad.adFormat,
);
```

### 2. AdMediationService
Intelligent ad selection across networks.

```dart
final mediationService = ref.read(adMediationServiceProvider);

// Get best ad with mediation
final ad = await mediationService.getBestAdForPlacement(
  placement: 'home_inline',
  platform: 'android',
);

// Record impression for mediated ad
await mediationService.recordImpressionForAd(ad);

// Record click for mediated ad
await mediationService.recordClickForAd(ad);

// Get mediation info
final info = await mediationService.getMediationInfo();
print('Enabled networks: ${info['enabled_networks']}');
```

### 3. AdRevenueService
Analytics and revenue tracking.

```dart
final revenueService = ref.read(adRevenueServiceProvider);

// Get total revenue
final revenue = await revenueService.getTotalRevenue(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
);

// Get revenue by placement
final byPlacement = await revenueService.getRevenueByPlacement(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
);

// Get metrics
final cpm = await revenueService.getAverageCpm(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
);
final cpc = await revenueService.getAverageCpc(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
);
final ctr = await revenueService.getClickThroughRate(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
);
```

### 4. AdConsentService
User privacy preferences.

```dart
final consentService = ref.read(adConsentServiceProvider);

// Get user consent
final consent = await consentService.getUserConsent(userId);

// Update consent
await consentService.updateUserConsent(
  personalizedAds: true,
  nonPersonalizedAds: true,
);

// Check if user allows personalized ads
final allowsPersonalized = await consentService.allowsPersonalizedAds(userId);

// Opt in/out
await consentService.optInToPersonalizedAds();
await consentService.optOutOfPersonalizedAds();

// Get consent summary
final summary = await consentService.getConsentSummary(userId);
```

### 5. AdMobService
Google AdMob integration.

```dart
final admobService = ref.read(adMobServiceProvider);

// Initialize AdMob
await admobService.initialize();

// Load ads
await admobService.loadBannerAd(adUnitId);
await admobService.loadInterstitialAd(adUnitId);
await admobService.loadRewardedAd(adUnitId);
await admobService.loadNativeAd(adUnitId);

// Show ads
await admobService.showInterstitialAd();
await admobService.showRewardedAd();

// Set user consent
await admobService.setUserConsent(personalizedAds: true);
```

## Riverpod Providers

### Get External Ad
```dart
final ad = await ref.watch(externalAdProvider('home_inline').future);
```

### Get User Consent
```dart
final consent = await ref.watch(userAdConsentProvider(userId).future);
```

## Models

### AdUnit
```dart
class AdUnit {
  final String id;
  final String networkId;
  final String placement;
  final String platform; // 'android', 'ios', 'web'
  final String adUnitId;
  final String adFormat; // 'banner', 'interstitial', 'rewarded', 'native'
  final bool isActive;
  final int priority;
}
```

### AdConsent
```dart
class AdConsent {
  final String userId;
  final bool personalizedAds;
  final bool nonPersonalizedAds;
  final DateTime consentGivenAt;
  final String consentVersion;
}
```

### AdRevenueAnalytics
```dart
class AdRevenueAnalytics {
  final DateTime date;
  final String placement;
  final String platform;
  final int impressions;
  final int clicks;
  final int conversions;
  final double revenueUsd;
  
  // Calculated properties
  double get cpm => (revenueUsd / impressions) * 1000;
  double get cpc => revenueUsd / clicks;
  double get ctr => (clicks / impressions) * 100;
}
```

## Common Patterns

### Display Ad with Mediation
```dart
class AdWidget extends ConsumerStatefulWidget {
  final String placement;
  
  @override
  ConsumerState<AdWidget> createState() => _AdWidgetState();
}

class _AdWidgetState extends ConsumerState<AdWidget> {
  @override
  void initState() {
    super.initState();
    _trackImpression();
  }

  void _trackImpression() {
    final mediationService = ref.read(adMediationServiceProvider);
    final ad = ref.read(externalAdProvider(widget.placement));
    
    ad.whenData((adUnit) {
      if (adUnit != null) {
        mediationService.recordImpressionForAd(adUnit);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final adAsync = ref.watch(externalAdProvider(widget.placement));
    
    return adAsync.when(
      data: (ad) {
        if (ad == null) return SizedBox.shrink();
        return _buildAdWidget(ad);
      },
      loading: () => SizedBox.shrink(),
      error: (_, __) => SizedBox.shrink(),
    );
  }

  Widget _buildAdWidget(AdUnit ad) {
    // TODO: Implement ad display based on ad.adFormat
    return Container();
  }
}
```

### Show Consent Dialog
```dart
Future<void> _showConsentDialog(BuildContext context) async {
  final consentService = ref.read(adConsentServiceProvider);
  
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Ad Preferences'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            title: Text('Personalized ads'),
            value: true,
            onChanged: (value) {},
          ),
          CheckboxListTile(
            title: Text('General ads'),
            value: true,
            onChanged: (value) {},
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Save'),
        ),
      ],
    ),
  );

  if (result == true) {
    await consentService.updateUserConsent(
      personalizedAds: true,
      nonPersonalizedAds: true,
    );
  }
}
```

### Get Revenue Dashboard Data
```dart
class RevenueDashboard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revenueService = ref.read(adRevenueServiceProvider);
    
    return FutureBuilder<double>(
      future: revenueService.getTotalRevenue(
        startDate: DateTime.now().subtract(Duration(days: 30)),
        endDate: DateTime.now(),
      ),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Text('Revenue: \$${snapshot.data?.toStringAsFixed(2)}');
        }
        return CircularProgressIndicator();
      },
    );
  }
}
```

## Configuration

### Enable External Ads
```dart
// Via admin dashboard or direct database update
UPDATE app_config 
SET config_value = 'true'::jsonb 
WHERE config_key = 'ads.external_enabled';
```

### Add Ad Network
```dart
INSERT INTO ad_networks (provider, display_name, is_enabled, priority, config)
VALUES (
  'admob',
  'Google AdMob',
  true,
  100,
  '{"app_id": "ca-app-pub-xxxxxxxxxxxxxxxx"}'::jsonb
);
```

### Add Ad Unit
```dart
INSERT INTO ad_units (
  network_id,
  placement,
  platform,
  ad_unit_id,
  ad_format,
  is_active,
  priority
)
VALUES (
  'network-uuid',
  'home_inline',
  'android',
  'ca-app-pub-3940256099942544/6300978111',
  'banner',
  true,
  100
);
```

## Troubleshooting

### No ads showing
1. Check if `ads.external_enabled` is true
2. Verify ad networks are enabled
3. Check if ad units exist for placement/platform
4. Verify user consent is given
5. Check logs for RPC errors

### Revenue not tracking
1. Verify `record_external_ad_impression()` is called
2. Check `ad_revenue_events` table for entries
3. Verify network/ad_unit IDs are correct
4. Check RLS policies allow writes

### Consent not saving
1. Verify user is authenticated
2. Check `ad_consent` table for entries
3. Verify at least one consent option is selected
4. Check RLS policies allow writes

## Next Steps

1. **Phase 2**: Implement mobile ad display widgets
2. **Phase 3**: Add web ad support
3. **Phase 4**: Build admin dashboard
4. **Phase 5**: Test and optimize

## Support

For issues or questions:
1. Check the spec: `.kiro/specs/external-ad-network-integration.md`
2. Review implementation: `.kiro/specs/PHASE1_IMPLEMENTATION_COMPLETE.md`
3. Check database schema in migrations
4. Review service documentation in code comments
