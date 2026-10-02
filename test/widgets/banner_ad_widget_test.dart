import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/banner_ad_widget.dart';

void main() {
  group('BannerAdWidget', () {
    test('should create widget with default parameters', () {
      final widget = BannerAdWidget(placement: 'home_inline');

      expect(widget, isNotNull);
      expect(widget.placement, equals('home_inline'));
    });

    test('should create widget with custom dimensions', () {
      final widget = BannerAdWidget(
        placement: 'home_inline',
        width: 300,
        height: 50,
      );

      expect(widget, isNotNull);
      expect(widget.width, equals(300));
      expect(widget.height, equals(50));
    });

    test('should create widget with callbacks', () {
      final widget = BannerAdWidget(
        placement: 'home_inline',
        onAdLoaded: () {},
        onAdFailed: (error) {},
      );

      expect(widget, isNotNull);
      expect(widget.placement, equals('home_inline'));
    });

    test('should create widget with different placements', () {
      final placements = ['home_inline', 'matches_inline', 'profile_inline'];

      for (final placement in placements) {
        final widget = BannerAdWidget(placement: placement);
        expect(widget.placement, equals(placement));
      }
    });

    test('should handle null callbacks', () {
      final widget = BannerAdWidget(
        placement: 'home_inline',
        onAdLoaded: null,
        onAdFailed: null,
      );

      expect(widget, isNotNull);
      expect(widget.placement, equals('home_inline'));
    });
  });
}
