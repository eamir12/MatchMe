/// Configuration for banner ads
class BannerAdConfig {
  const BannerAdConfig({
    required this.adUnitId,
    this.width = 320,
    this.height = 50,
  });

  final String adUnitId;
  final int width;
  final int height;

  factory BannerAdConfig.fromMap(Map<String, dynamic> data) {
    return BannerAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      width: (data['width'] ?? 320) as int,
      height: (data['height'] ?? 50) as int,
    );
  }

  Map<String, dynamic> toMap() {
    return {'ad_unit_id': adUnitId, 'width': width, 'height': height};
  }
}

/// Configuration for interstitial ads
class InterstitialAdConfig {
  const InterstitialAdConfig({required this.adUnitId});

  final String adUnitId;

  factory InterstitialAdConfig.fromMap(Map<String, dynamic> data) {
    return InterstitialAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {'ad_unit_id': adUnitId};
  }
}

/// Configuration for rewarded ads
class RewardedAdConfig {
  const RewardedAdConfig({required this.adUnitId});

  final String adUnitId;

  factory RewardedAdConfig.fromMap(Map<String, dynamic> data) {
    return RewardedAdConfig(adUnitId: (data['ad_unit_id'] ?? '').toString());
  }

  Map<String, dynamic> toMap() {
    return {'ad_unit_id': adUnitId};
  }
}

/// Configuration for native ads
class NativeAdConfig {
  const NativeAdConfig({required this.adUnitId, this.templateType = 'medium'});

  final String adUnitId;
  final String templateType; // 'small', 'medium', 'large'

  factory NativeAdConfig.fromMap(Map<String, dynamic> data) {
    return NativeAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      templateType: (data['template_type'] ?? 'medium').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {'ad_unit_id': adUnitId, 'template_type': templateType};
  }
}

/// Reward earned from rewarded ad
class AdReward {
  const AdReward({required this.type, required this.amount});

  final String type;
  final int amount;

  @override
  String toString() => 'AdReward(type: $type, amount: $amount)';
}

/// Ad load state
enum AdLoadState { idle, loading, loaded, failed }

/// Ad display state
enum AdDisplayState { hidden, showing, dismissed, clicked, completed }

/// Mobile ad event
class MobileAdEvent {
  const MobileAdEvent({
    required this.type,
    required this.adUnitId,
    required this.adFormat,
    this.error,
    this.reward,
  });

  final String
  type; // 'impression', 'click', 'loaded', 'failed', 'dismissed', 'completed'
  final String adUnitId;
  final String adFormat; // 'banner', 'interstitial', 'rewarded', 'native'
  final String? error;
  final AdReward? reward;

  @override
  String toString() =>
      'MobileAdEvent(type: $type, adFormat: $adFormat, error: $error)';
}

/// Mobile ad configuration holder
class MobileAdConfigs {
  const MobileAdConfigs({
    required this.bannerConfigs,
    required this.interstitialConfigs,
    required this.rewardedConfigs,
    required this.nativeConfigs,
  });

  final Map<String, BannerAdConfig> bannerConfigs;
  final Map<String, InterstitialAdConfig> interstitialConfigs;
  final Map<String, RewardedAdConfig> rewardedConfigs;
  final Map<String, NativeAdConfig> nativeConfigs;

  /// Get banner config for placement
  BannerAdConfig? getBannerConfig(String placement) {
    return bannerConfigs[placement];
  }

  /// Get interstitial config for placement
  InterstitialAdConfig? getInterstitialConfig(String placement) {
    return interstitialConfigs[placement];
  }

  /// Get rewarded config for placement
  RewardedAdConfig? getRewardedConfig(String placement) {
    return rewardedConfigs[placement];
  }

  /// Get native config for placement
  NativeAdConfig? getNativeConfig(String placement) {
    return nativeConfigs[placement];
  }

  factory MobileAdConfigs.empty() {
    return const MobileAdConfigs(
      bannerConfigs: {},
      interstitialConfigs: {},
      rewardedConfigs: {},
      nativeConfigs: {},
    );
  }
}
