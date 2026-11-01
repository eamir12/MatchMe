import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:matchme/utils/lat_lng_smoother.dart';

void main() {
  testWidgets('snaps the first update', (tester) async {
    final updates = <LatLng>[];
    final smoother = LatLngSmoother(
      vsync: const TestVSync(),
      onChanged: updates.add,
    );
    addTearDown(smoother.dispose);

    const first = LatLng(10, 20);
    smoother.update(first);

    expect(updates, [first]);
    expect(smoother.current, first);
  });

  testWidgets('snaps large jumps and immediate updates', (tester) async {
    final updates = <LatLng>[];
    final smoother = LatLngSmoother(
      vsync: const TestVSync(),
      onChanged: updates.add,
    );
    addTearDown(smoother.dispose);

    smoother.update(const LatLng(0, 0));
    smoother.update(const LatLng(0, 1));

    expect(updates.last, const LatLng(0, 1));
    expect(smoother.current, const LatLng(0, 1));

    smoother.update(const LatLng(10, 10), immediate: true);

    expect(updates.last, const LatLng(10, 10));
    expect(smoother.current, const LatLng(10, 10));
  });

  testWidgets('animates across the antimeridian via the short path', (
    tester,
  ) async {
    final updates = <LatLng>[];
    final smoother = LatLngSmoother(
      vsync: const TestVSync(),
      onChanged: updates.add,
    );
    addTearDown(smoother.dispose);

    smoother.update(const LatLng(0, 179.999));
    smoother.update(const LatLng(0, -179.999));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(updates.last.longitude, lessThan(-179.99));

    await tester.pump(const Duration(milliseconds: 500));

    expect(updates.last.longitude, closeTo(-179.999, 0.000001));
    expect(smoother.current, const LatLng(0, -179.999));
  });
}
