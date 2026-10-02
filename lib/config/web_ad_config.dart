import 'package:matchme/models/web_ad.dart';

/// Web ad configuration for the application
///
/// This file contains all web ad unit IDs and configurations
/// for different placements and ad formats.
///
/// To use:
/// 1. Replace placeholder ad unit IDs with your actual Google AdSense/AdMob ad unit IDs
/// 2. Adjust dimensions and responsive settings as needed
/// 3. Add new placements as required
class WebAdConfig {
  /// Get web ad configurations for the app
  static WebAdConfigs getConfigs() {
    return WebAdConfigs(
      bannerConfigs: {
        'home_inline': const WebBannerAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 728,
          height: 90,
          responsive: true,
        ),
        'matches_inline': const WebBannerAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 728,
          height: 90,
          responsive: true,
        ),
        'chats_inline': const WebBannerAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 728,
          height: 90,
          responsive: true,
        ),
        'events_inline': const WebBannerAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 728,
          height: 90,
          responsive: true,
        ),
      },
      displayConfigs: {
        'home_inline': const WebDisplayAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 250,
          responsive: true,
        ),
        'matches_inline': const WebDisplayAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 250,
          responsive: true,
        ),
        'chats_inline': const WebDisplayAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 250,
          responsive: true,
        ),
        'events_inline': const WebDisplayAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 250,
          responsive: true,
        ),
      },
      inFeedConfigs: {
        'home_inline': const WebInFeedAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 100,
          height: 100,
          responsive: true,
        ),
        'matches_inline': const WebInFeedAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 100,
          height: 100,
          responsive: true,
        ),
        'chats_inline': const WebInFeedAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 100,
          height: 100,
          responsive: true,
        ),
        'events_inline': const WebInFeedAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 100,
          height: 100,
          responsive: true,
        ),
      },
      articleConfigs: {
        'home_inline': const WebArticleAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 600,
          responsive: true,
        ),
        'matches_inline': const WebArticleAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 600,
          responsive: true,
        ),
        'chats_inline': const WebArticleAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 600,
          responsive: true,
        ),
        'events_inline': const WebArticleAdConfig(
          adUnitId:
              'ca-pub-xxxxxxxxxxxxxxxx/xxxxxxxx', // TODO: Replace with actual ad unit ID
          width: 300,
          height: 600,
          responsive: true,
        ),
      },
    );
  }

  /// Get web ad configurations from environment variables
  ///
  /// This allows for dynamic configuration without code changes
  static WebAdConfigs getConfigsFromEnv({required Map<String, String> env}) {
    return WebAdConfigs(
      bannerConfigs: {
        'home_inline': WebBannerAdConfig(
          adUnitId: env['WEB_BANNER_HOME'] ?? '',
          width: int.tryParse(env['WEB_BANNER_WIDTH'] ?? '728') ?? 728,
          height: int.tryParse(env['WEB_BANNER_HEIGHT'] ?? '90') ?? 90,
          responsive: env['WEB_BANNER_RESPONSIVE'] != 'false',
        ),
        'matches_inline': WebBannerAdConfig(
          adUnitId: env['WEB_BANNER_MATCHES'] ?? '',
          width: int.tryParse(env['WEB_BANNER_WIDTH'] ?? '728') ?? 728,
          height: int.tryParse(env['WEB_BANNER_HEIGHT'] ?? '90') ?? 90,
          responsive: env['WEB_BANNER_RESPONSIVE'] != 'false',
        ),
        'chats_inline': WebBannerAdConfig(
          adUnitId: env['WEB_BANNER_CHATS'] ?? '',
          width: int.tryParse(env['WEB_BANNER_WIDTH'] ?? '728') ?? 728,
          height: int.tryParse(env['WEB_BANNER_HEIGHT'] ?? '90') ?? 90,
          responsive: env['WEB_BANNER_RESPONSIVE'] != 'false',
        ),
        'events_inline': WebBannerAdConfig(
          adUnitId: env['WEB_BANNER_EVENTS'] ?? '',
          width: int.tryParse(env['WEB_BANNER_WIDTH'] ?? '728') ?? 728,
          height: int.tryParse(env['WEB_BANNER_HEIGHT'] ?? '90') ?? 90,
          responsive: env['WEB_BANNER_RESPONSIVE'] != 'false',
        ),
      },
      displayConfigs: {},
      inFeedConfigs: {},
      articleConfigs: {},
    );
  }
}
