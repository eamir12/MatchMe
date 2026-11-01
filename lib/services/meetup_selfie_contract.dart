import 'dart:typed_data';

/// Outcome of a Spot me selfie capture. A null [bytes] with a null [error]
/// means the user backed out; [error] carries `unavailable`, `denied` or
/// `failed` so the composer can show the matching localized message.
class MeetupSelfieResult {
  final Uint8List? bytes;
  final String? error;

  const MeetupSelfieResult({this.bytes, this.error});

  const MeetupSelfieResult.cancelled() : this();

  const MeetupSelfieResult.failed(String error) : this(error: error);

  bool get isCaptured => bytes != null && bytes!.isNotEmpty;

  bool get isCancelled => bytes == null && error == null;
}
