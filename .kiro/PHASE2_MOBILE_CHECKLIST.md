# Phase 2: Mobile Implementation - Checklist

## Overview
Phase 2 focuses on implementing mobile ad display and Google AdMob integration for iOS and Android platforms.

## Dependencies to Add

### pubspec.yaml
```yaml
dependencies:
  # Ad Networks
  google_mobile_ads: ^5.0.0
  
  # Firebase (for AdMob analytics)
  firebase_core: ^2.24.0
  firebase_analytics: ^10.7.0
  
  # Privacy (iOS)
  app_tracking_transparency: ^2.8.0
  
  # Consent Management
  user_messaging_platform: ^1.0.0  # For Google UMP SDK
```

## Task Breakdown

### 2.1: Add Dependencies ✓
- [ ] Add google_mobile_ads to pubspec.yaml
- [ ] Add firebase_core to pubspec.yaml
- [ ] Add firebase_analytics to pubspec.yaml
- [ ] Add app_tracking_transparency to pubspec.yaml
- [ ] Add user_messaging_platform to pubspec.yaml
- [ ] Run `flutter pub get`
- [ ] Verify no dependency conflicts

### 2.2: Platform Configuration

#### Android Setup
- [ ] Add Google Mobile Ads App ID to AndroidManifest.xml
- [ ] Add required permissions to AndroidManifest.xml
- [ ] Configure Firebase in android/build.gradle
- [ ] Add google-services.json to android/app/
- [ ] Update minSdkVersion if needed (AdMob requires API 21+)

#### iOS Setup
- [ ] Add Google Mobile Ads App ID to Info.plist
- [ ] Add SKAdNetwork identifiers to Info.plist
- [ ] Configure Firebase in ios/Podfile
- [ ] Add GoogleService-Info.plist to ios/Runner/
- [ ] Update iOS deployment target if needed (AdMob requires iOS 12+)

### 2.3: Create Mobile Ad Models
**File:** `lib/models/mobile_ad.dart`

```dart
class MobileAd {
  final String adUnitId;
  final String adFormat; // 'banner', 'interstitial', 'rewarded', 'native'
  final String placement;
  final String platform;
}

class BannerAdConfig {
  final String adUnitId;
  final int width;
  final int height;
}

class InterstitialAdConfig {
  final String adUnitId;
}

class RewardedAdConfig {
  final String adUnitId;
}

class NativeAdConfig {
  final String adUnitId;
  final String templateType;
}
```

### 2.4: Create MobileAdService
**File:** `lib/services/mobile_ad_service.dart`

- [ ] Initialize Google Mobile Ads SDK
- [ ] Implement banner ad loading/display
- [ ] Implement interstitial ad loading/display
- [ ] Implement rewarded ad loading/display
- [ ] Implement native ad loading/display
- [ ] Add error handling
- [ ] Add lifecycle management
- [ ] Add revenue callback handling

### 2.5: Create Consent UI Components

#### AdConsentDialog
**File:** `lib/widgets/ad_consent_dialog.dart`

- [ ] Create consent dialog widget
- [ ] Add personalized ads checkbox
- [ ] Add general ads checkbox
- [ ] Add privacy policy link
- [ ] Add accept/decline buttons
- [ ] Implement consent saving
- [ ] Add translations

#### AdSettingsScreen
**File:** `lib/screens/ad_settings_screen.dart`

- [ ] Create settings screen
- [ ] Add personalized ads toggle
- [ ] Add general ads toggle
- [ ] Add opt-out button
- [ ] Implement preference saving
- [ ] Add translations

### 2.6: Create Ad Display Widgets

#### BannerAdWidget
**File:** `lib/widgets/banner_ad_widget.dart`

- [ ] Create banner ad widget
- [ ] Implement ad loading
- [ ] Handle ad lifecycle
- [ ] Track impressions
- [ ] Handle errors gracefully
- [ ] Support different sizes

#### InterstitialAdWidget
**File:** `lib/widgets/interstitial_ad_widget.dart`

- [ ] Create interstitial wrapper
- [ ] Implement ad loading
- [ ] Implement ad display
- [ ] Track impressions/clicks
- [ ] Handle dismissal

#### RewardedAdWidget
**File:** `lib/widgets/rewarded_ad_widget.dart`

- [ ] Create rewarded ad wrapper
- [ ] Implement ad loading
- [ ] Implement ad display
- [ ] Handle reward callback
- [ ] Track completions

#### NativeAdWidget
**File:** `lib/widgets/native_ad_widget.dart`

- [ ] Create native ad widget
- [ ] Implement ad loading
- [ ] Create custom template
- [ ] Track impressions
- [ ] Handle clicks

### 2.7: Integrate with Existing Ad System

- [ ] Update AdSlot to support external ads
- [ ] Update SponsoredCard to work with external ads
- [ ] Implement fallback logic (internal → external)
- [ ] Update ad provider to use mediation service
- [ ] Add external ad tracking to existing flows

### 2.8: Implement Revenue Tracking

- [ ] Set up AdMob revenue callback
- [ ] Implement revenue event recording
- [ ] Add server-side revenue sync
- [ ] Implement daily aggregation
- [ ] Add analytics dashboard integration

### 2.9: Add Privacy Features

#### iOS App Tracking Transparency
- [ ] Request ATT permission on iOS 14+
- [ ] Handle permission response
- [ ] Pass consent to AdMob SDK
- [ ] Update privacy policy

#### Google User Messaging Platform
- [ ] Implement UMP SDK
- [ ] Create consent form
- [ ] Handle consent responses
- [ ] Store consent preferences

### 2.10: Testing

#### Unit Tests
- [ ] Test MobileAdService initialization
- [ ] Test ad loading logic
- [ ] Test revenue tracking
- [ ] Test consent management

#### Integration Tests
- [ ] Test ad display on Android
- [ ] Test ad display on iOS
- [ ] Test ad clicks
- [ ] Test revenue events
- [ ] Test consent flow

#### Manual Testing
- [ ] Test banner ads on Android
- [ ] Test banner ads on iOS
- [ ] Test interstitial ads
- [ ] Test rewarded ads
- [ ] Test native ads
- [ ] Test consent dialog
- [ ] Test settings screen
- [ ] Verify revenue tracking

## Implementation Order

1. **Add Dependencies** (30 min)
2. **Platform Configuration** (1 hour)
3. **Create Models** (30 min)
4. **Create MobileAdService** (2 hours)
5. **Create Consent UI** (1.5 hours)
6. **Create Ad Widgets** (2 hours)
7. **Integrate with Existing System** (1 hour)
8. **Implement Revenue Tracking** (1 hour)
9. **Add Privacy Features** (1 hour)
10. **Testing** (2 hours)

**Total: 12-14 hours**

## Key Considerations

### Performance
- Load ads asynchronously
- Cache ad units
- Implement ad preloading
- Monitor memory usage

### User Experience
- Show consent dialog on first launch
- Don't interrupt user flow with ads
- Respect user consent preferences
- Provide easy opt-out

### Revenue Optimization
- Use mediation for multiple networks
- Optimize ad placement
- A/B test placements
- Monitor fill rates

### Privacy & Compliance
- Respect user consent
- Implement GDPR compliance
- Implement CCPA compliance
- Implement COPPA compliance
- Provide transparent privacy policy

## AdMob Setup

### Create AdMob Account
1. Go to admob.google.com
2. Sign in with Google account
3. Create new app
4. Get App ID

### Create Ad Units
1. Create banner ad unit (320x50, 300x250)
2. Create interstitial ad unit
3. Create rewarded ad unit
4. Create native ad unit
5. Note ad unit IDs

### Configure in App
1. Add App ID to AndroidManifest.xml
2. Add App ID to Info.plist
3. Add ad unit IDs to database via admin dashboard
4. Enable AdMob in app config

## Testing Ad Units

**Use these test ad unit IDs for development:**

```dart
// Android
const String BANNER_AD_UNIT_ID = 'ca-app-pub-3940256099942544/6300978111';
const String INTERSTITIAL_AD_UNIT_ID = 'ca-app-pub-3940256099942544/1033173712';
const String REWARDED_AD_UNIT_ID = 'ca-app-pub-3940256099942544/5224354917';
const String NATIVE_AD_UNIT_ID = 'ca-app-pub-3940256099942544/2247696110';

// iOS
const String BANNER_AD_UNIT_ID = 'ca-app-pub-3940256099942544/2934735716';
const String INTERSTITIAL_AD_UNIT_ID = 'ca-app-pub-3940256099942544/4411468910';
const String REWARDED_AD_UNIT_ID = 'ca-app-pub-3940256099942544/1712485313';
const String NATIVE_AD_UNIT_ID = 'ca-app-pub-3940256099942544/3986624511';
```

## Deployment Checklist

- [ ] All dependencies added and resolved
- [ ] Platform configuration complete
- [ ] All services implemented
- [ ] All widgets implemented
- [ ] All tests passing
- [ ] Privacy features implemented
- [ ] Revenue tracking working
- [ ] AdMob account created
- [ ] Ad units created
- [ ] App IDs configured
- [ ] Consent flow tested
- [ ] Ad display tested on both platforms
- [ ] Revenue events verified
- [ ] Privacy policy updated
- [ ] Ready for beta testing

## Success Criteria

- ✅ Ads display on both iOS and Android
- ✅ Revenue events tracked accurately
- ✅ User consent respected
- ✅ No crashes or errors
- ✅ Ad fill rate > 80%
- ✅ User retention not negatively impacted
- ✅ Privacy compliance verified

## Resources

- [Google Mobile Ads Flutter Plugin](https://pub.dev/packages/google_mobile_ads)
- [AdMob Documentation](https://support.google.com/admob)
- [Firebase Flutter Setup](https://firebase.flutter.dev/)
- [App Tracking Transparency](https://pub.dev/packages/app_tracking_transparency)
- [User Messaging Platform](https://pub.dev/packages/user_messaging_platform)

## Notes

- Start with test ad units during development
- Switch to production ad units before release
- Monitor ad performance in AdMob dashboard
- Adjust mediation priorities based on fill rates
- Regularly review revenue metrics
- Keep privacy policy updated

## Next Phase

After Phase 2 completion, proceed to Phase 3: Web Implementation
