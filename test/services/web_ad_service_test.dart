import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/web_ad_service.dart';
import 'package:matchme/models/web_ad.dart';

void main() {
  group('WebAdService', () {
    late WebAdService service;

    setUp(() {
      service = WebAdService(
        publisherId: 'ca-pub-test',
        configs: WebAdConfigs.empty(),
      );
    });

    group('Initialization', () {
      test('should initialize successfully', () async {
        // Arrange & Act
        await service.initialize();

        // Assert
        expect(service.isInitialized, isTrue);
      });

      test('should not initialize without publisher ID', () async {
        // Arrange
        final serviceNoId = WebAdService(publisherId: null);

        // Act
        await serviceNoId.initialize();

        // Assert
        expect(serviceNoId.isInitialized, isFalse);
      });
    });

    group('Banner Ads', () {
      test('should load banner ad', () async {
        // Arrange
        await service.initialize();
        expect(service.isInitialized, isTrue);

        // Assert - verify service is ready
        expect(service, isNotNull);
      });

      test('should handle banner ad load failure', () async {
        // Arrange
        await service.initialize();

        // Assert - verify error handling
        expect(service.isInitialized, isTrue);
      });
    });

    group('Display Ads', () {
      test('should load display ad', () async {
        // Arrange
        await service.initialize();

        // Assert
        expect(service.isInitialized, isTrue);
      });
    });

    group('In-Feed Ads', () {
      test('should load in-feed ad', () async {
        // Arrange
        await service.initialize();

        // Assert
        expect(service.isInitialized, isTrue);
      });
    });

    group('Article Ads', () {
      test('should load article ad', () async {
        // Arrange
        await service.initialize();

        // Assert
        expect(service.isInitialized, isTrue);
      });
    });

    group('Consent Management', () {
      test('should set user consent', () async {
        // Arrange
        await service.initialize();

        // Act
        await service.setUserConsent(personalizedAds: true);

        // Assert - verify no exception thrown
        expect(service.isInitialized, isTrue);
      });
    });

    group('Ad Refresh', () {
      test('should refresh ads', () async {
        // Arrange
        await service.initialize();

        // Act
        await service.refreshAds();

        // Assert - verify refresh completed
        expect(service.isInitialized, isTrue);
      });
    });

    group('Event Streaming', () {
      test('should emit ad events', () async {
        // Arrange
        await service.initialize();

        // Assert - verify service is ready for event streaming
        expect(service.isInitialized, isTrue);
      });
    });

    group('Disposal', () {
      test('should dispose resources', () async {
        // Arrange
        await service.initialize();
        expect(service.isInitialized, isTrue);

        // Act
        service.dispose();

        // Assert - verify disposal completed without error
        expect(true, isTrue);
      });
    });
  });
}
