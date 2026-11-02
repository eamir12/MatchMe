// Channel mapping shared with the server. The literal ids are asserted here so a
// rename cannot silently break the FCM channel routing implemented in
// supabase/migrations/20260925000000_admin_broadcast_alert_preferences.sql
// (public.admin_broadcast_channel_id).

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/notification_channels.dart';

void main() {
  group('javaStringHashCode', () {
    test('matches Java UTF-16 string hashing', () {
      expect(javaStringHashCode('abc'), 96354);
      expect(javaStringHashCode('😀'), 1772899);
    });
  });

  group('AdminBroadcastChannels', () {
    test('maps every alert preference combination to its channel', () {
      expect(
        AdminBroadcastChannels.idFor(soundEnabled: true, vibrateEnabled: true),
        'admin_broadcasts',
      );
      expect(
        AdminBroadcastChannels.idFor(soundEnabled: true, vibrateEnabled: false),
        'admin_broadcasts_sound',
      );
      expect(
        AdminBroadcastChannels.idFor(soundEnabled: false, vibrateEnabled: true),
        'admin_broadcasts_vibrate',
      );
      expect(
        AdminBroadcastChannels.idFor(
          soundEnabled: false,
          vibrateEnabled: false,
        ),
        'admin_broadcasts_silent',
      );
    });

    test('all holds exactly the four server-targetable ids', () {
      expect(AdminBroadcastChannels.all.toSet(), {
        'admin_broadcasts',
        'admin_broadcasts_sound',
        'admin_broadcasts_vibrate',
        'admin_broadcasts_silent',
      });
    });

    test('channel traits match the id semantics', () {
      for (final id in AdminBroadcastChannels.all) {
        final expectedSound =
            id == 'admin_broadcasts' || id == 'admin_broadcasts_sound';
        final expectedVibration =
            id == 'admin_broadcasts' || id == 'admin_broadcasts_vibrate';
        expect(
          AdminBroadcastChannels.playsSound(id),
          expectedSound,
          reason: '$id playsSound',
        );
        expect(
          AdminBroadcastChannels.vibrates(id),
          expectedVibration,
          reason: '$id vibrates',
        );
        expect(
          AdminBroadcastChannels.isSilent(id),
          id == 'admin_broadcasts_silent',
          reason: '$id isSilent',
        );
        expect(AdminBroadcastChannels.name(id).isNotEmpty, isTrue);
        expect(AdminBroadcastChannels.description(id).isNotEmpty, isTrue);
      }
    });

    test('idFor round-trips through the trait helpers', () {
      for (final sound in const [true, false]) {
        for (final vibrate in const [true, false]) {
          final id = AdminBroadcastChannels.idFor(
            soundEnabled: sound,
            vibrateEnabled: vibrate,
          );
          expect(AdminBroadcastChannels.playsSound(id), sound);
          expect(AdminBroadcastChannels.vibrates(id), vibrate);
        }
      }
    });
  });
}
