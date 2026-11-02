// Regression guard for the shared Realtime hub.
//
// Supabase counts every local `postgres_changes` binding as realtime work.
// Home, the nearby map and the online map used to bind the same tables
// independently, which is what pushed the project over its CPU budget at
// ~8 clients. All other-user bindings for these tables now go through
// SharedRealtimeTables; only own-row subscriptions (already filtered to the
// signed-in user) and offline mutation descriptors may name the table
// elsewhere.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowedFiles = <String, Set<String>>{
  'user_activity': {'lib/services/shared_realtime_tables.dart'},
  'presence_tick': {'lib/services/shared_realtime_tables.dart'},
  'user_locations': {
    'lib/services/shared_realtime_tables.dart',
    // Own pinned-location row: channel filtered to `user_id = me`.
    'lib/providers/pinned_location_provider.dart',
    // Offline mutation descriptors, not realtime subscriptions.
    'lib/services/mutation_wrapper.dart',
  },
  'users': {
    'lib/services/shared_realtime_tables.dart',
    // Own row: channel filtered to `id = me` (settings sync).
    'lib/services/my_user_realtime_service.dart',
    // Offline mutation descriptors, not realtime subscriptions.
    'lib/services/mutation_wrapper.dart',
  },
};

void main() {
  test('only the shared hub binds these tables to realtime', () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final path = file.path.replaceAll(Platform.pathSeparator, '/');
      final source = file.readAsStringSync();
      for (final entry in _allowedFiles.entries) {
        if (entry.value.contains(path)) continue;
        if (source.contains("table: '${entry.key}'")) {
          offenders.add('$path binds ${entry.key}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These tables are watched by more than one screen. Add a listener '
          'through SharedRealtimeTables instead of a new channel. Offenders:\n'
          '${offenders.join('\n')}',
    );
  });
}
