/// Configuration for web banner ads
class WebBannerAdConfig {
  const WebBannerAdConfig({
    required this.adUnitId,
    this.width = 728,
    this.height = 90,
    this.responsive = true,
  });

  final String adUnitId;
  final int width;
  final int height;
  final bool responsive;

  factory WebBannerAdConfig.fromMap(Map<String, dynamic> data) {
    return WebBannerAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      width: (data['width'] ?? 728) as int,
      height: (data['height'] ?? 90) as int,
      responsive: data['responsive'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ad_unit_id': adUnitId,
      'width': width,
      'height': height,
      'responsive': responsive,
    };
  }
}

/// Configuration for web display ads
class WebDisplayAdConfig {
  const WebDisplayAdConfig({
    required this.adUnitId,
    this.width = 300,
    this.height = 250,
    this.responsive = true,
  });

  final String adUnitId;
  final int width;
  final int height;
  final bool responsive;

  factory WebDisplayAdConfig.fromMap(Map<String, dynamic> data) {
    return WebDisplayAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      width: (data['width'] ?? 300) as int,
      height: (data['height'] ?? 250) as int,
      responsive: data['responsive'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ad_unit_id': adUnitId,
      'width': width,
      'height': height,
      'responsive': responsive,
    };
  }
}

/// Configuration for web in-feed ads
class WebInFeedAdConfig {
  const WebInFeedAdConfig({
    required this.adUnitId,
    this.width = 100,
    this.height = 100,
    this.responsive = true,
  });

  final String adUnitId;
  final int width;
  final int height;
  final bool responsive;

  factory WebInFeedAdConfig.fromMap(Map<String, dynamic> data) {
    return WebInFeedAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      width: (data['width'] ?? 100) as int,
      height: (data['height'] ?? 100) as int,
      responsive: data['responsive'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ad_unit_id': adUnitId,
      'width': width,
      'height': height,
      'responsive': responsive,
    };
  }
}

/// Configuration for web article ads
class WebArticleAdConfig {
  const WebArticleAdConfig({
    required this.adUnitId,
    this.width = 300,
    this.height = 600,
    this.responsive = true,
  });

  final String adUnitId;
  final int width;
  final int height;
  final bool responsive;

  factory WebArticleAdConfig.fromMap(Map<String, dynamic> data) {
    return WebArticleAdConfig(
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      width: (data['width'] ?? 300) as int,
      height: (data['height'] ?? 600) as int,
      responsive: data['responsive'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ad_unit_id': adUnitId,
      'width': width,
      'height': height,
      'responsive': responsive,
    };
  }
}

/// Web ad event
class WebAdEvent {
  const WebAdEvent({
    required this.type,
    required this.adUnitId,
    required this.adFormat,
    this.error,
  });

  final String type; // 'impression', 'click', 'loaded', 'failed'
  final String adUnitId;
  final String adFormat; // 'banner', 'display', 'in_feed', 'article'
  final String? error;

  @override
  String toString() =>
      'WebAdEvent(type: $type, adFormat: $adFormat, error: $error)';
}

/// Web ad configurations holder
class WebAdConfigs {
  const WebAdConfigs({
    required this.bannerConfigs,
    required this.displayConfigs,
    required this.inFeedConfigs,
    required this.articleConfigs,
  });

  final Map<String, WebBannerAdConfig> bannerConfigs;
  final Map<String, WebDisplayAdConfig> displayConfigs;
  final Map<String, WebInFeedAdConfig> inFeedConfigs;
  final Map<String, WebArticleAdConfig> articleConfigs;

  /// Get banner config for placement
  WebBannerAdConfig? getBannerConfig(String placement) {
    return bannerConfigs[placement];
  }

  /// Get display config for placement
  WebDisplayAdConfig? getDisplayConfig(String placement) {
    return displayConfigs[placement];
  }

  /// Get in-feed config for placement
  WebInFeedAdConfig? getInFeedConfig(String placement) {
    return inFeedConfigs[placement];
  }

  /// Get article config for placement
  WebArticleAdConfig? getArticleConfig(String placement) {
    return articleConfigs[placement];
  }

  factory WebAdConfigs.empty() {
    return const WebAdConfigs(
      bannerConfigs: {},
      displayConfigs: {},
      inFeedConfigs: {},
      articleConfigs: {},
    );
  }
}
