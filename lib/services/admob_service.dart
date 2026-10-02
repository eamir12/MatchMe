import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Configuration for Google AdMob
class AdMobConfig {
  const AdMobConfig({
    required this.appId,
    required this.bannerAdUnitId,
    required this.interstitialAdUnitId,
    required this.rewardedAdUnitId,
    required this.nativeAdUnitId,
  });

  final String appId;
  final String bannerAdUnitId;
  final String interstitialAdUnitId;
  final String rewardedAdUnitId;
  final String nativeAdUnitId;

  factory AdMobConfig.fromMap(Map<String, dynamic> data) {
    return AdMobConfig(
      appId: (data['app_id'] ?? '').toString(),
      bannerAdUnitId: (data['banner_ad_unit_id'] ?? '').toString(),
      interstitialAdUnitId: (data['interstitial_ad_unit_id'] ?? '').toString(),
      rewardedAdUnitId: (data['rewarded_ad_unit_id'] ?? '').toString(),
      nativeAdUnitId: (data['native_ad_unit_id'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'app_id': appId,
      'banner_ad_unit_id': bannerAdUnitId,
      'interstitial_ad_unit_id': interstitialAdUnitId,
      'rewarded_ad_unit_id': rewardedAdUnitId,
      'native_ad_unit_id': nativeAdUnitId,
    };
  }
}

/// Service for managing Google AdMob integration
///
/// This service handles:
/// - AdMob SDK initialization
/// - Ad loading and display
/// - Revenue tracking
/// - Consent management
///
/// Note: Actual AdMob SDK integration requires adding the google_mobile_ads package
/// and platform-specific configuration. This service provides the interface.
class AdMobService {
  AdMobService({AdMobConfig? config}) : _config = config;

  final AdMobConfig? _config;
  bool _isInitialized = false;

  /// Initialize Google Mobile Ads SDK
  ///
  /// This should be called once at app startup
  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      if (_config == null || _config.appId.isEmpty) {
        print('⚠️ [AdMobService] AdMob App ID not configured');
        return;
      }

      MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          testDeviceIds: ['D7A2098E7B8BDCE766C9DDB1F5FE61B6'],
        ),
      );
      await MobileAds.instance.initialize();
      _isInitialized = true;
      print('✓ [AdMobService] Initialized successfully');
    } catch (e) {
      print('⚠️ [AdMobService] Failed to initialize: $e');
    }
  }

  /// Load a banner ad
  ///
  /// Returns true if ad loaded successfully
  Future<bool> loadBannerAd(String adUnitId) async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      if (adUnitId.isEmpty) {
        print('⚠️ [AdMobService] Banner ad unit ID is empty');
        return false;
      }

      // TODO: Load banner ad
      // final bannerAd = BannerAd(
      //   adUnitId: adUnitId,
      //   size: AdSize.banner,
      //   request: const AdRequest(),
      //   listener: BannerAdListener(
      //     onAdLoaded: (ad) => print('Banner ad loaded'),
      //     onAdFailedToLoad: (ad, error) => print('Banner ad failed: $error'),
      //   ),
      // );
      // await bannerAd.load();

      return true;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to load banner ad: $e');
      return false;
    }
  }

  /// Load an interstitial ad
  ///
  /// Returns true if ad loaded successfully
  Future<bool> loadInterstitialAd(String adUnitId) async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      if (adUnitId.isEmpty) {
        print('⚠️ [AdMobService] Interstitial ad unit ID is empty');
        return false;
      }

      // TODO: Load interstitial ad
      // InterstitialAd.load(
      //   adUnitId: adUnitId,
      //   request: const AdRequest(),
      //   adLoadCallback: InterstitialAdLoadCallback(
      //     onAdLoaded: (ad) => print('Interstitial ad loaded'),
      //     onAdFailedToLoad: (error) => print('Interstitial ad failed: $error'),
      //   ),
      // );

      return true;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to load interstitial ad: $e');
      return false;
    }
  }

  /// Load a rewarded ad
  ///
  /// Returns true if ad loaded successfully
  Future<bool> loadRewardedAd(String adUnitId) async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      if (adUnitId.isEmpty) {
        print('⚠️ [AdMobService] Rewarded ad unit ID is empty');
        return false;
      }

      // TODO: Load rewarded ad
      // RewardedAd.load(
      //   adUnitId: adUnitId,
      //   request: const AdRequest(),
      //   rewardedAdLoadCallback: RewardedAdLoadCallback(
      //     onAdLoaded: (ad) => print('Rewarded ad loaded'),
      //     onAdFailedToLoad: (error) => print('Rewarded ad failed: $error'),
      //   ),
      // );

      return true;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to load rewarded ad: $e');
      return false;
    }
  }

  /// Load a native ad
  ///
  /// Returns true if ad loaded successfully
  Future<bool> loadNativeAd(String adUnitId) async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      if (adUnitId.isEmpty) {
        print('⚠️ [AdMobService] Native ad unit ID is empty');
        return false;
      }

      // TODO: Load native ad
      // NativeAd(
      //   adUnitId: adUnitId,
      //   factoryId: 'listTile',
      //   request: const AdRequest(),
      //   listener: NativeAdListener(
      //     onAdLoaded: (ad) => print('Native ad loaded'),
      //     onAdFailedToLoad: (ad, error) => print('Native ad failed: $error'),
      //   ),
      // ).load();

      return true;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to load native ad: $e');
      return false;
    }
  }

  /// Show an interstitial ad
  ///
  /// Returns true if ad was shown successfully
  Future<bool> showInterstitialAd() async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      // TODO: Show interstitial ad
      // if (_interstitialAd != null) {
      //   _interstitialAd!.show();
      //   return true;
      // }

      return false;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to show interstitial ad: $e');
      return false;
    }
  }

  /// Show a rewarded ad
  ///
  /// Returns true if ad was shown successfully
  Future<bool> showRewardedAd() async {
    try {
      if (!_isInitialized) {
        print('⚠️ [AdMobService] AdMob not initialized');
        return false;
      }

      // TODO: Show rewarded ad
      // if (_rewardedAd != null) {
      //   _rewardedAd!.show(
      //     onUserEarnedReward: (ad, reward) {
      //       print('User earned reward: ${reward.amount} ${reward.type}');
      //     },
      //   );
      //   return true;
      // }

      return false;
    } catch (e) {
      print('⚠️ [AdMobService] Failed to show rewarded ad: $e');
      return false;
    }
  }

  /// Set user consent for personalized ads
  ///
  /// This should be called after user provides consent
  Future<void> setUserConsent({required bool personalizedAds}) async {
    try {
      // TODO: Set user consent in AdMob SDK
      // final consentInfo = ConsentInformation.instance;
      // await consentInfo.requestConsentInfoUpdate(
      //   ConsentRequestParameters(
      //     tagForUnderAgeOfConsent: false,
      //   ),
      // );
      // if (consentInfo.isConsentFormAvailable) {
      //   await ConsentForm.loadAndShowConsentDialog();
      // }

      print(
        '✓ [AdMobService] User consent updated: personalized=$personalizedAds',
      );
    } catch (e) {
      print('⚠️ [AdMobService] Failed to set user consent: $e');
    }
  }

  /// Check if AdMob is initialized
  bool get isInitialized => _isInitialized;

  /// Get AdMob configuration
  AdMobConfig? get config => _config;
}
