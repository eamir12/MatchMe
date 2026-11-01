// test/utils/chat_notification_copy_test.dart
//
// The Dart twin of supabase/functions/_shared/chat_notification_copy_test.ts.
// The app draws the same card the server draws, so it has to reach the same
// result from the same inputs - and the two rules the member set have to hold
// for every surface that renders a card itself (web tray, iOS banner, Windows
// toast) and for a push that arrived without any payload copy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/chat_notification_copy.dart';
import 'package:matchme/utils/notification_limits.dart';
import 'package:matchme/utils/string_extensions.dart';

/// The name is wrapped in directional marks and bidi isolates so an RTL name
/// cannot scramble an LTR sentence. Compare what the member actually reads.
String visible(String value) => value.withoutBidiControls;

ChatNotificationCard buildCard({
  required int unreadCount,
  bool previewsEnabled = true,
  List<String> lines = const <String>[],
  ChatCopyForms? forms,
  ChatPushCardModel? payload,
}) {
  return buildChatNotificationCard(
    unreadCount: unreadCount,
    previewsEnabled: previewsEnabled,
    candidateLines: lines,
    forms: forms ?? ChatCopyForms.fallback('John S.'),
    payload: payload,
  );
}

LocalizationState _state(String languageCode, Map<String, String> strings) {
  return LocalizationState(
    currentLocale: Locale(languageCode),
    textDirection: languageCode == 'he' ? TextDirection.rtl : TextDirection.ltr,
    strings: strings,
    supportedLanguages: const [],
    contentLanguageCode: languageCode,
    dbKeys: strings.keys.toSet(),
  );
}

void main() {
  group('chat card content model', () {
    test('one unread is unambiguous, so its line is the body', () {
      final card = buildCard(unreadCount: 1, lines: ['Coffee tomorrow?']);
      expect(visible(card.title), '1 message from John S.');
      expect(card.body, 'Coffee tomorrow?');
    });

    test('several unread show no text and state the count', () {
      final card = buildCard(
        unreadCount: 3,
        lines: ['Coffee tomorrow?', 'I found that place', '9am works'],
      );
      expect(visible(card.title), '3 messages from John S.');
      expect(card.body, '3 unread - open to read');
      // The lines still travel, oldest first, for a surface that can expand.
      expect(card.previewLines, [
        'Coffee tomorrow?',
        'I found that place',
        '9am works',
      ]);
    });

    test('previews off ships no message content at all', () {
      final card = buildCard(
        unreadCount: 1,
        previewsEnabled: false,
        lines: ['a secret'],
      );
      expect(card.previewLines, isEmpty);
      expect(card.body, '1 unread - open to read');
      expect(card.title.contains('secret'), false);
      expect(card.body.contains('secret'), false);
    });

    test('no canned preview promise survives in the copy', () {
      for (final count in [1, 2, 3, 9]) {
        for (final previews in [true, false]) {
          final card = buildCard(
            unreadCount: count,
            previewsEnabled: previews,
            lines: const ['x'],
          );
          expect(card.body.contains('New message'), false, reason: '$count');
          expect(
            card.body.contains('Turn previews on'),
            false,
            reason: '$count',
          );
        }
      }
    });

    test('lines are byte-capped and clamped to the preview window', () {
      final long = 'א' * 2000;
      final many = List<String>.generate(9, (i) => '$i $long');
      final card = buildCard(unreadCount: 9, lines: many);
      expect(card.previewLines.length, NotifLimits.chatHistoryMaxItems);
      for (final line in card.previewLines) {
        expect(
          notifUtf8Bytes(line) <= NotifLimits.chatPreviewLineMaxBytes,
          true,
          reason: 'line of ${notifUtf8Bytes(line)} bytes',
        );
      }
      expect(card.previewLines.first.startsWith('4 '), true);
    });

    test('a zero count never renders "0 messages"', () {
      final card = buildCard(unreadCount: 0);
      expect(visible(card.title), '1 message from John S.');
      expect(card.unreadCount, 1);
    });

    test('server copy wins over the local computation', () {
      final card = buildCard(
        unreadCount: 3,
        forms: ChatCopyForms.fallback('יוסי כ.'),
        payload: const ChatPushCardModel(
          title: '3 messages from John S.',
          body: '3 unread - open to read',
          previewLines: ['one', 'two', 'three'],
          unreadCount: 3,
        ),
      );
      expect(card.title, '3 messages from John S.');
      expect(card.body, '3 unread - open to read');
      expect(card.previewLines, ['one', 'two', 'three']);
    });

    test('an empty payload title falls through to the localized form', () {
      final card = buildCard(
        unreadCount: 2,
        payload: const ChatPushCardModel(title: '', body: ''),
      );
      expect(visible(card.title), '2 messages from John S.');
      expect(card.body, '2 unread - open to read');
    });
  });

  group('push payload parsing', () {
    test('a data-only payload carries no card', () {
      expect(
        ChatPushCardModel.tryFromMap({
          'matchId': 'm1',
          'sender_name': 'John Smith',
        }),
        isNull,
      );
    });

    test('lines travel as JSON and the flags are tri-state', () {
      final model = ChatPushCardModel.tryFromMap({
        'notification_title': '2 messages from John S.',
        'notification_body': '2 unread - open to read',
        'preview_lines': '["Coffee tomorrow?","","9am works"]',
        'unread_count': '2',
        'previews_enabled': 'false',
      });
      expect(model?.title, '2 messages from John S.');
      expect(model?.previewLines, ['Coffee tomorrow?', '9am works']);
      expect(model?.unreadCount, 2);
      expect(model?.previewsEnabled, false);
    });

    test('malformed preview_lines still leaves the server title and body', () {
      final model = ChatPushCardModel.tryFromMap({
        'notification_title': '1 message from John S.',
        'notification_body': 'Coffee tomorrow?',
        'preview_lines': 'not json',
      });
      expect(model?.previewLines, isEmpty);
      expect(model?.title, '1 message from John S.');
      expect(model?.body, 'Coffee tomorrow?');
      expect(model?.unreadCount, isNull);
      expect(model?.previewsEnabled, isNull);
    });
  });

  group('localized card forms', () {
    test('English agrees the noun with the count', () {
      final forms = _state('en', const {
        'pushMessagesTitle': '{count} messages from {name}',
        'pushMessagesTitle_one': '{count} message from {name}',
        'pushOpenToReadBody': '{count} unread - open to read',
        'pushOpenToReadBody_one': '1 unread - open to read',
      }).chatCardForms(maskedName: 'John S.');
      expect(visible(forms.title(1)), '1 message from John S.');
      expect(visible(forms.title(4)), '4 messages from John S.');
      expect(forms.openToReadBody(1), '1 unread - open to read');
      expect(forms.openToReadBody(4), '4 unread - open to read');
    });

    test('Hebrew uses the dual for two', () {
      final forms = _state('he', const {
        'pushMessagesTitle': '{count} הודעות מאת {name}',
        'pushMessagesTitle_one': 'הודעה מאת {name}',
        'pushMessagesTitle_two': 'שתי הודעות מאת {name}',
        'pushOpenToReadBody': '{count} הודעות לא נקראו - פתח כדי לקרוא',
        'pushOpenToReadBody_one': 'הודעה אחת לא נקראה - פתח כדי לקרוא',
        'pushOpenToReadBody_two': 'שתי הודעות לא נקראו - פתח כדי לקרוא',
      }).chatCardForms(maskedName: 'יוסי כ.');
      expect(visible(forms.title(2)), 'שתי הודעות מאת יוסי כ.');
      expect(forms.openToReadBody(2), 'שתי הודעות לא נקראו - פתח כדי לקרוא');
      expect(forms.openToReadBody(1), 'הודעה אחת לא נקראה - פתח כדי לקרוא');
    });

    test('Spanish carries the count in the noun form', () {
      final forms = _state('es', const {
        'pushMessagesTitle': '{count} mensajes de {name}',
        'pushMessagesTitle_one': '{count} mensaje de {name}',
        'pushOpenToReadBody': '{count} mensajes sin leer: abre para leer',
        'pushOpenToReadBody_one': '1 mensaje sin leer: abre para leer',
      }).chatCardForms(maskedName: 'Juan S.');
      expect(visible(forms.title(1)), '1 mensaje de Juan S.');
      expect(forms.openToReadBody(1), '1 mensaje sin leer: abre para leer');
      expect(visible(forms.title(5)), '5 mensajes de Juan S.');
    });

    test('an unknown locale falls back to English copy, never to a key', () {
      final forms = _state('fr', const {}).chatCardForms(maskedName: 'John S.');
      expect(visible(forms.title(4)), '4 messages from John S.');
      expect(forms.title(4).contains('pushMessagesTitle'), false);
      expect(forms.openToReadBody(4).contains('openToReadBody'), false);
    });

    test(
      'a card built from localized Hebrew copy keeps the count out of the body',
      () {
        final forms = _state('he', const {
          'pushMessagesTitle': '{count} הודעות מאת {name}',
          'pushOpenToReadBody': '{count} הודעות לא נקראו - פתח כדי לקרוא',
        }).chatCardForms(maskedName: 'יוסי כ.');
        final card = buildCard(
          unreadCount: 3,
          lines: const ['שלום'],
          forms: forms,
        );
        expect(visible(card.title), '3 הודעות מאת יוסי כ.');
        expect(card.body, '3 הודעות לא נקראו - פתח כדי לקרוא');
        expect(card.previewLines, ['שלום']);
      },
    );
  });
}
