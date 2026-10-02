enum MatchingBackgroundStatus {
  on,
  off,
  permissionNeeded,
  checking,
  webUnavailable,
}

MatchingBackgroundStatus resolveMatchingBackgroundStatus({
  required bool isWeb,
  required bool isAndroid,
  required bool preferenceEnabled,
  required bool permissionCheckComplete,
  required bool? permissionGranted,
}) {
  if (isWeb) return MatchingBackgroundStatus.webUnavailable;
  if (!preferenceEnabled) return MatchingBackgroundStatus.off;
  if (isAndroid && !permissionCheckComplete) {
    return MatchingBackgroundStatus.checking;
  }
  if (isAndroid && permissionGranted != true) {
    return MatchingBackgroundStatus.permissionNeeded;
  }
  return MatchingBackgroundStatus.on;
}
