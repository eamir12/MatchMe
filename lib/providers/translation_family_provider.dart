// lib/providers/translation_family_provider.dart
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/services/translation_service.dart';

/// Per-message translation provider (FutureProvider.family).
/// param: JSON-encoded map containing at least {'text': '...','matchId': '...','messageId': '...','otherUserId': '...'}
/// Returns translated string or null if none / on error.
///
/// This provider depends on translationVersionProvider and localizationProvider so it
/// will re-run when the user changes app language (translationVersion bumps).
final translationFamilyProvider = FutureProvider.family<String?, String>((ref, paramsJson) async {
  // Depend on explicit version so we control when re-evaluation occurs
  ref.watch(translationVersionProvider);

  // Also depend on the current app locale/target language
  final locale = ref.watch(localizationProvider).currentLocale;
  final targetLang = locale.languageCode;

  // Defensive parse of params
  Map<String, dynamic> params;
  try {
    final decoded = jsonDecode(paramsJson);
    if (decoded is Map<String, dynamic>) {
      params = decoded;
    } else {
      params = {'text': paramsJson};
    }
  } catch (e) {
    params = {'text': paramsJson};
  }

  final text = (params['text'] ?? '') as String;
  final otherUserId = (params['otherUserId'] ?? '') as String;

  // Quick return if no text
  if (text.trim().isEmpty) {
    return null;
  }

  // Get recipient's gender for gender-aware translation
  String? recipientGender;
  if (otherUserId.isNotEmpty) {
    try {
      final otherUserProfile = await ref.watch(userProfileProvider(otherUserId).future);
      recipientGender = otherUserProfile?.gender;
    } catch (e) {
      // If we can't get the profile, continue without gender context
      recipientGender = null;
    }
  }

  final TranslationService service = ref.read(translationServiceProvider);

  try {
    // Identify source language when possible. Guard any exceptions.
    String sourceLang = '';
    try {
      sourceLang = await service.identifyLanguage(text);
    } catch (identifyErr) {
      sourceLang = '';
    }

    // If sourceLang equals targetLang, we may still want to return null (no translation needed).
    if (sourceLang.isNotEmpty && sourceLang == targetLang) {
      return null;
    }

    final translated = await service.translateText(
      text,
      sourceLang,
      targetLang,
      recipientGender: recipientGender,
    );

    final trimmed = translated.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    return trimmed;
  } catch (e) {
    // Return null on error (UI will show original text)
    return null;
  }
});