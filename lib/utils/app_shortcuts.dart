class AppShortcuts {
  AppShortcuts._();

  static int? _pendingTabIndex;

  static void setPendingTabIndex(int index) {
    _pendingTabIndex = index;
  }

  static int? consumePendingTabIndex() {
    final v = _pendingTabIndex;
    _pendingTabIndex = null;
    return v;
  }
}
