/// One match's live/pending meet-up activity, as returned by
/// `meetup_activity_by_match`.
///
/// The server resolves priority and counts distinct tools, so the chip only
/// has to translate the winning kind. No history is included on purpose.
class MeetupActivity {
  const MeetupActivity({
    required this.topKind,
    required this.topOwn,
    required this.toolCount,
    this.topLabel,
    this.topGesture,
    this.nextExpiry,
  });

  final String topKind;
  final bool topOwn;
  final int toolCount;

  /// The chosen place label while a meet-up is active, so the banner can say
  /// "Meet-up active — Dizengoff Square". Only set for active sessions.
  final String? topLabel;

  /// The gesture behind a winning wave (`wave`, `hands_up`, `jumping`,
  /// `arms_wide`), so the card can say what was actually sent. A beacon has no
  /// gesture, and a wave stored before the gesture was recorded has none
  /// either, so this is null whenever the caller must fall back to the generic
  /// wave copy.
  final String? topGesture;
  final DateTime? nextExpiry;

  factory MeetupActivity.fromJson(Map<String, dynamic> json) {
    final rawExpiry = json['next_expiry']?.toString();
    final rawLabel = json['top_label']?.toString().trim();
    final rawGesture = json['top_gesture']?.toString().trim();
    return MeetupActivity(
      topKind: json['top_kind']?.toString() ?? '',
      topOwn: json['top_own'] == true,
      toolCount: (json['tool_count'] as num?)?.toInt() ?? 1,
      topLabel: rawLabel == null || rawLabel.isEmpty ? null : rawLabel,
      topGesture: rawGesture == null || rawGesture.isEmpty ? null : rawGesture,
      nextExpiry: rawExpiry == null
          ? null
          : DateTime.tryParse(rawExpiry)?.toUtc(),
    );
  }
}

class MeetupActivityKind {
  MeetupActivityKind._();

  static const String placeChange = 'place_change';
  static const String proposal = 'proposal';
  static const String live = 'live';
  static const String beacon = 'beacon';
  static const String spot = 'spot';
  static const String wave = 'wave';
  static const String active = 'active';
}
