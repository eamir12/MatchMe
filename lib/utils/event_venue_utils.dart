bool isVirtualMeetingLocation(String? raw) {
  final value = raw?.toLowerCase().trim() ?? '';
  if (value.isEmpty) return false;
  if (value == 'online' || value == 'virtual') return true;
  if (value.contains('http://') || value.contains('https://')) return true;
  if (value.contains('zoom.us') ||
      value.contains('zoom.com') ||
      value.contains('zoom')) {
    return true;
  }
  if (value.contains('meet.google.com') || value.contains('google meet')) {
    return true;
  }
  if (value.contains('teams.microsoft.com') ||
      value.contains('microsoft teams') ||
      value.contains('ms teams')) {
    return true;
  }
  if (value.contains('webex') ||
      value.contains('gotomeeting') ||
      value.contains('go to meeting') ||
      value.contains('skype') ||
      value.contains('hangouts') ||
      value.contains('discord.gg') ||
      value.contains('discord.com')) {
    return true;
  }
  if (value.contains('online meeting') ||
      value.contains('virtual meeting') ||
      value.contains('video call') ||
      value.contains('conference call')) {
    return true;
  }
  return false;
}
