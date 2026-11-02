// lib/utils/meetup_alert_card.dart
//
// The meet-up tool alert vocabulary shared by the surfaces that show alerts and
// the notification layer that posts and removes their OS cards: the kind of
// each tool event, how long each one stays news, and the identity a tool event
// carries in the notification shade.
//
// The identity has two halves, both derived from the same payload keys so the
// side that removes a card always names what the side that posted it used: the
// id the app's own card was shown under, and the collapse tag the push carried.
// The tag rules mirror the server contract in
// supabase/functions/cron-jobs (collapseTag) and web/firebase-messaging-sw.js.

const String kMeetupAlertSignal = 'meetup_signal';
const String kMeetupAlertBeacon = 'meetup_beacon';
const String kMeetupAlertSpot = 'meetup_spot';
const String kMeetupAlertProposal = 'meetup_proposal';
const String kMeetupAlertPlaceChange = 'meetup_place_change';

const Set<String> kMeetupAlertKinds = {
  kMeetupAlertSignal,
  kMeetupAlertBeacon,
  kMeetupAlertSpot,
  kMeetupAlertProposal,
  kMeetupAlertPlaceChange,
};

/// How long each tool event stays news, before the app_config values are
/// loaded and as the fallback when they cannot be.
const Map<String, Duration> kMeetupAlertDefaultTtl = {
  kMeetupAlertSignal: Duration(seconds: 60),
  kMeetupAlertBeacon: Duration(seconds: 120),
  kMeetupAlertSpot: Duration(minutes: 120),
  kMeetupAlertProposal: Duration(minutes: 240),
  kMeetupAlertPlaceChange: Duration(minutes: 240),
};

/// A wave or beacon is a live row the sender replaces on resend, so both
/// directions key its card on sender + match rather than on the row id, which
/// changes with every resend. Proposals, place-change requests and Spot cards
/// are single-shot events keyed on their own row.
bool isLiveMeetupSignal(String kind) =>
    kind == kMeetupAlertSignal || kind == kMeetupAlertBeacon;

String _payload(Map<String, dynamic> data, String key) =>
    (data[key] ?? '').toString().trim();

String _id(Map<String, dynamic> data, String camel, String snake) {
  final value = _payload(data, camel);
  return value.isNotEmpty ? value : _payload(data, snake);
}

/// The tool row this event came from: the signal, the Spot card, or the meet-up
/// session a proposal / place-change request belongs to.
String meetupAlertRowId(Map<String, dynamic> data) {
  for (final key in const [
    'meetup_signal_id',
    'meetup_spot_id',
    'meetup_session_id',
  ]) {
    final value = _payload(data, key);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _matchId(Map<String, dynamic> data) => _id(data, 'matchId', 'match_id');

String _senderId(Map<String, dynamic> data) =>
    _id(data, 'senderId', 'sender_id');

String _eventKey(String kind, Map<String, dynamic> data) {
  if (isLiveMeetupSignal(kind)) {
    final matchId = _matchId(data);
    final senderId = _senderId(data);
    if (matchId.isNotEmpty && senderId.isNotEmpty) {
      return '${matchId}_$senderId';
    }
  }
  final row = meetupAlertRowId(data);
  if (row.isNotEmpty) return row;
  return _matchId(data);
}

/// The id `MobileLocalNotificationService.showMeetupNotification` posts this
/// event's card under, so the same key cancels it. Empty when the payload names
/// no event at all.
String meetupAlertCardKey(String kind, Map<String, dynamic> data) {
  final event = _eventKey(kind, data);
  return event.isEmpty ? '' : '${kind}_$event';
}

/// The collapse tag this event's push carries: what `cancelServerCard` needs to
/// drop the card the FCM SDK posted while the app was backgrounded or killed.
///
/// Live-signal uuid segments are truncated to 8 hex chars because the full pair
/// is too long for a collapse key; two participants per match and an 8-char
/// prefix keep it unique for every direction that actually exists.
String meetupAlertServerTag(String kind, Map<String, dynamic> data) {
  final row = meetupAlertRowId(data);
  if (isLiveMeetupSignal(kind)) {
    final matchId = _matchId(data);
    final senderId = _senderId(data);
    if (matchId.isNotEmpty && senderId.isNotEmpty) {
      return '${kind}_${_prefix(matchId)}_${_prefix(senderId)}';
    }
    return row.isEmpty ? '' : '${kind}_$row';
  }
  final key = row.isNotEmpty ? row : _matchId(data);
  return key.isEmpty ? '' : '${kind}_$key';
}

String _prefix(String value) =>
    value.length <= 8 ? value : value.substring(0, 8);
