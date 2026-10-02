import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/widgets/pinned_map_status_banner.dart';

/// Test double for visibility: the real IsVisible.build wires up GPS and
/// prefs, which widget tests must not touch.
class _FakeIsVisible extends IsVisible {
  _FakeIsVisible(this._value);
  final bool _value;

  @override
  bool build() => _value;
}

Future<void> _pumpBanner(
  WidgetTester tester, {
  required PinnedLocationState pin,
  required LocalizationState l10n,
  bool isVisible = true,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [isVisibleProvider.overrideWith(() => _FakeIsVisible(isVisible))],
      child: MaterialApp(
        home: Scaffold(body: PinnedMapStatusBanner(pin: pin, l10n: l10n)),
      ),
    ),
  );
}

void main() {
  testWidgets('pinned map status explains GPS pause without coordinates', (
    tester,
  ) async {
    final l10n = LocalizationState.loading();
    const pin = PinnedLocationState(
      isActive: true,
      label: 'Home',
      latitude: 51.5074,
      longitude: -0.1278,
    );

    await _pumpBanner(tester, pin: pin, l10n: l10n, isVisible: true);

    expect(find.textContaining('GPS paused'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(PinnedMapStatusBanner));
    expect(semantics.label, contains('GPS paused'));
    expect(semantics.label, isNot(contains('51.5074')));
    expect(semantics.label, isNot(contains('-0.1278')));
  });

  testWidgets('inactive pin renders no map status banner', (tester) async {
    await _pumpBanner(
      tester,
      pin: const PinnedLocationState(),
      l10n: LocalizationState.loading(),
    );

    expect(find.byType(PinnedMapStatusBanner), findsOneWidget);
    expect(find.textContaining('GPS paused'), findsNothing);
  });

  testWidgets('banner stays hidden while the user is invisible', (
    tester,
  ) async {
    const pin = PinnedLocationState(
      isActive: true,
      label: 'Home',
      latitude: 51.5074,
      longitude: -0.1278,
    );

    await _pumpBanner(
      tester,
      pin: pin,
      l10n: LocalizationState.loading(),
      isVisible: false,
    );

    expect(find.byType(PinnedMapStatusBanner), findsOneWidget);
    expect(find.textContaining('GPS paused'), findsNothing);
  });
}
