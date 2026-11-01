// lib/utils/notification_copy_source.dart
//
// The two provider reads every self-drawn chat card needs, in one place: the
// member's "show message previews" switch and the card sentences in the
// member's language.
//
// They live here rather than in ChatCopyForms because that module is
// provider-free on purpose - the push payload path and the tests build a card
// without a Riverpod container. They live here rather than in each renderer
// because web, iOS and Windows must not be able to disagree about what a
// container that has not answered yet means.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/utils/chat_notification_copy.dart';

/// The member's preview switch.
///
/// True when the preferences have no answer yet: the tray is showing the
/// message the member is waiting for, and hiding it because a provider had not
/// answered is the failure this setting is not meant to cause. A push payload
/// carries its own flag, which the caller checks first - the server applied it
/// before anything went on the wire.
bool messagePreviewsEnabled(ProviderContainer? container) {
  if (container == null) return true;
  try {
    return container
        .read(userPreferencesProvider)
        .notifications
        .messagePreviews;
  } catch (_) {
    return true;
  }
}

/// The card sentences, resolved in the member's language.
///
/// [maskedName] is inserted already masked and isolated: it belongs inside the
/// sentence, and where it lands depends on the language ("3 messages from John
/// S." / "3 הודעות מאת יוסי כ."). English when localization has no state yet, so
/// a card still states its count instead of falling back to "New message".
ChatCopyForms chatCardForms(ProviderContainer? container, String maskedName) {
  if (container != null) {
    try {
      return container
          .read(localizationProvider)
          .chatCardForms(maskedName: maskedName);
    } catch (_) {}
  }
  return ChatCopyForms.fallback(maskedName);
}
