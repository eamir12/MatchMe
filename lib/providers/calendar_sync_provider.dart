import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/calendar_sync_service.dart';

final calendarSyncServiceProvider = Provider<CalendarSyncService>((ref) {
  final service = CalendarSyncService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
