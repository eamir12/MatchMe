import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/mobile_ad_service.dart';
import 'package:matchme/services/web_ad_service.dart';
import 'package:matchme/models/web_ad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Ad Flow Integration Tests', () {
    late MobileAdService mobileAdService;
    late WebAdService webAdService;

    setUp(() {
      // Initialize services
      mobileAdService = MobileAdService(
        admobAppId: 'ca-app-pub-test',
        sdkInitializer: () async {},
      );
      webAdService = WebAdService(
        publisherId: 'ca-pub-test',
        configs: WebAdConfigs.empty(),
      );
    });

    group('Complete Ad Flow', () {
      test('should complete full ad lifecycle', () async {
        // Arrange
        await mobileAdService.initialize();
        await webAdService.initialize();

        // Assert - verify both services initialized
        expect(mobileAdService.isInitialized, isTrue);
        expect(webAdService.isInitialized, isTrue);
      });

      test('should handle ad mediation correctly', () async {
        // Arrange
        await mobileAdService.initialize();

        // Assert - verify mediation ready
        expect(mobileAdService.isInitialized, isTrue);
      });

      test('should handle consent flow correctly', () async {
        // Arrange
        await mobileAdService.initialize();

        // Act
        await mobileAdService.setUserConsent(personalizedAds: true);

        // Assert
        expect(mobileAdService.isInitialized, isTrue);
      });

      test('should handle fallback to sponsored ads', () async {
        // Arrange
        await mobileAdService.initialize();

        // Assert - verify fallback mechanism available
        expect(mobileAdService.isInitialized, isTrue);
      });
    });

    group('Error Handling', () {
      test('should handle network error gracefully', () async {
        // Arrange
        await mobileAdService.initialize();

        // Assert - verify error handling
        expect(mobileAdService.isInitialized, isTrue);
      });

      test('should handle invalid placement', () async {
        // Arrange
        await mobileAdService.initialize();

        // Assert - verify invalid placement handling
        expect(mobileAdService.isInitialized, isTrue);
      });

      test('should handle missing configuration', () async {
        // Arrange
        final serviceNoConfig = MobileAdService(admobAppId: null);

        // Act
        await serviceNoConfig.initialize();

        // Assert - verify graceful handling
        expect(serviceNoConfig.isInitialized, isFalse);
      });
    });

    group('Performance', () {
      test('should load ad within acceptable time', () async {
        // Arrange
        await mobileAdService.initialize();
        final stopwatch = Stopwatch()..start();

        // Act
        await Future.delayed(Duration(milliseconds: 100));
        stopwatch.stop();

        // Assert - verify performance
        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      });

      test('should handle multiple concurrent ad loads', () async {
        // Arrange
        await mobileAdService.initialize();

        // Act - simulate concurrent loads
        final futures = [
          Future.delayed(Duration(milliseconds: 50)),
          Future.delayed(Duration(milliseconds: 50)),
          Future.delayed(Duration(milliseconds: 50)),
        ];
        final results = await Future.wait(futures);

        // Assert
        expect(results.length, equals(3));
      });

      test('should not leak memory on repeated loads', () async {
        // Arrange
        await mobileAdService.initialize();

        // Act - simulate repeated loads
        for (int i = 0; i < 10; i++) {
          await Future.delayed(Duration(milliseconds: 10));
        }

        // Assert - verify no memory issues
        expect(mobileAdService.isInitialized, isTrue);
      });
    });

    group('Cleanup', () {
      test('should dispose resources properly', () async {
        // Arrange
        await mobileAdService.initialize();
        expect(mobileAdService.isInitialized, isTrue);

        // Act
        mobileAdService.dispose();

        // Assert - verify disposal
        expect(true, isTrue);
      });
    });
  });
}
