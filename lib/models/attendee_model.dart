// lib/models/event/attendee_model.dart
class AttendeeModel {
  final String userId;
  final String fullName; // Stored as Jane Smith
  
  AttendeeModel({
    required this.userId,
    required this.fullName,
  });

  factory AttendeeModel.fromJson(Map<String, dynamic> json) {
    final raw = (json['user_name'] ?? 'Unknown User').toString();
    final parts = raw.trim().split(RegExp(r'\s+'));
    String masked;
    if (parts.isEmpty) {
      masked = 'Unknown User';
    } else if (parts.length > 1 && parts.last != parts.first) {
      masked = '${parts.first} ${parts.last.substring(0,1).toUpperCase()}.';
    } else {
      masked = parts.first;
    }

    return AttendeeModel(
      userId: json['user_id'],
      fullName: masked,
    );
  }

  // --- Formatting for Privacy (First L.) ---
  String get formattedName {
    if (fullName.isEmpty || fullName == 'Unknown User') return 'User...';

    final parts = fullName.trim().split(' ');
    if (parts.length > 1 && parts[1].isNotEmpty) {
      return '${parts[0]} ${parts[1][0].toUpperCase()}.';
    }
    return parts[0];
  }
}
