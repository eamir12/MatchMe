import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/notification_limits.dart';

void main() {
  group('notification limits', () {
    test('ascii within budget passes', () {
      final r = truncateUtf8Bytes('hello', 200);
      expect(r.truncated, false);
      expect(r.text, 'hello');
    });

    test('hebrew truncates by bytes not chars', () {
      // שלום = 4 chars, 8 bytes. Budget 5 bytes -> 2 chars + ellipsis.
      final r = truncateUtf8Bytes('שלום עולם', 10);
      expect(r.truncated, true);
      expect(notifUtf8Bytes(r.text) <= 10, true);
    });

    test('emoji never splits surrogate', () {
      final r = truncateUtf8Bytes('😀😀😀😀', 10);
      expect(r.truncated, true);
      expect(notifUtf8Bytes(r.text) <= 10, true);
      // No lone surrogate.
      expect(r.text.contains('\uFFFD'), false);
    });

    test('admin validation blocks oversize', () {
      final longTitle = List.filled(61, 'a').join();
      final issues = adminInputViolations(title: longTitle, body: 'ok');
      expect(issues.isNotEmpty, true);
    });

    test('admin validation ok for normal', () {
      final issues = adminInputViolations(title: 'Hi', body: 'Hello world');
      expect(issues.isEmpty, true);
    });

    test('maskFullName mirrors mask_full_name ("John S.")', () {
      expect(maskFullName('John Smith'), 'John S.');
      expect(maskFullName('John Michael Smith'), 'John S.');
      expect(maskFullName('Prince'), 'Prince');
      expect(maskFullName(''), 'Someone');
      // Idempotent: already-masked server/RPC titles pass through unchanged.
      expect(maskFullName('John S.'), 'John S.');
    });

    test('enforceTitleBody caps queue sizes', () {
      final big = List.filled(2000, 'b').join();
      final e = enforceTitleBody(big, big);
      expect(notifUtf8Bytes(e.title) <= NotifLimits.queueTitleMaxBytes, true);
      expect(notifUtf8Bytes(e.body) <= NotifLimits.queueBodyMaxBytes, true);
      expect(e.truncated, true);
    });
  });
}
