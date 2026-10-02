import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/event_venue_utils.dart';

void main() {
  test('recognizes online meeting venues', () {
    expect(isVirtualMeetingLocation('Zoom'), isTrue);
    expect(isVirtualMeetingLocation('https://meet.google.com/abc'), isTrue);
    expect(isVirtualMeetingLocation('Microsoft Teams'), isTrue);
    expect(isVirtualMeetingLocation('online meeting'), isTrue);
  });

  test('keeps physical venues available for maps', () {
    expect(isVirtualMeetingLocation('Central Station'), isFalse);
    expect(isVirtualMeetingLocation('https://example.com/venue'), isTrue);
    expect(isVirtualMeetingLocation(null), isFalse);
  });
}
