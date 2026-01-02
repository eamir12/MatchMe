// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:matchme/providers/profile_provider.dart'; // for userProfileProvider
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/auth_provider.dart';


final supabase = Supabase.instance.client;
final uuid = Uuid();

// Throttle map to avoid triggering translation multiple times for the same message
final Map<String, DateTime> _lastTranslationTriggeredAt = {};

// --- ChatSyncService (Modified to take localDb as parameter) ---
class ChatSyncService {
  final LocalDbService localDb;
  ChatSyncService(this.localDb);

  Future<void> syncMessages(String matchId) async {
    if (matchId.isEmpty) return;
    try {
      final data = await supabase
          .from('chat_messages')
          .select('id, match_id, sender_id, content_original, content_translated, created_at, edited_at, read_at')
          .eq('match_id', matchId)
          .order('created_at', ascending: true);
      // Replace all messages for this match with the current database state
      // This ensures deleted messages are removed from local cache
      await localDb.saveMessages(matchId, data.cast<Map<String, dynamic>>());
    } catch (e) {
      debugPrint('syncMessages error: $e');
      // Keep the error surfaced but avoid noisy logging here.
    }
  }
}

final chatSyncProvider = Provider.family<ChatSyncService, String>(
  (ref, matchId) => ChatSyncService(ref.read(localDbProvider)),
);


// --- UPDATED: chatMessagesProvider (Fixes bugs & uses local DB + realtime)
// Emits a stream of ChatMessageModel lists for a given matchId.
final chatMessagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessageModel>, String>((ref, matchId) {

  if (matchId.isEmpty) return Stream.value([]);

  final localDb = ref.watch(localDbProvider);
  final localStream = localDb.watchMessages(matchId);

  // Use syncService for an initial full sync once we subscribe
  final syncService = ref.read(chatSyncProvider(matchId));

  final channel = supabase.channel('public:chat_messages:match_id=eq.$matchId');

  final streamController = StreamController<List<ChatMessageModel>>.broadcast();
  bool disposed = false;

  // Always emit local cached messages immediately (offline-first).
  final localSubscription = localStream.listen((messagesData) {
    if (disposed || streamController.isClosed) return;
    try {
      streamController.add(
        messagesData.map((json) => ChatMessageModel.fromJson(json)).toList(),
      );
    } catch (_) {
      // ignore add-after-close races
    }
  });

  // Handler for Postgres realtime changes (insert/update/delete)
  void handleChanges(dynamic payload) async {
     try {
       final eventType = payload.eventType;

       // Check if this event is for our match
       // For DELETE events, the subscription filter ensures it's for our match
       if (eventType != PostgresChangeEvent.delete) {
         final recordMatchId = payload.newRecord['match_id'];
         if (recordMatchId != matchId) {
           return;
         }
       }

       final currentUserId = supabase.auth.currentUser?.id;

       if (eventType == PostgresChangeEvent.insert) {
         // Don't add our own messages via real-time, since they're already handled by the send flow
         final senderId = payload.newRecord['sender_id'];
         if (senderId != currentUserId) {
           localDb.addMessages(matchId, [payload.newRecord]);

           // Proactively trigger translation for incoming messages
           final messageId = payload.newRecord['id'];
           final contentOriginal = payload.newRecord['content_original'];
           if (messageId != null && contentOriginal != null && contentOriginal.isNotEmpty) {
             // Avoid triggering translations repeatedly for the same message in a short window
             final now = DateTime.now();
             final last = _lastTranslationTriggeredAt[messageId];
             if (last != null && now.difference(last) < const Duration(seconds: 2)) {
               debugPrint('Skipping duplicate translation trigger for incoming message: $messageId');
             } else {
               _lastTranslationTriggeredAt[messageId] = now;
               debugPrint('Triggering translation for incoming message: $messageId');
               // Trigger translation in background - don't await to avoid blocking realtime handling
               final translationParams = jsonEncode({
                 'text': contentOriginal,
                 'matchId': matchId,
                 'messageId': messageId,
                 'otherUserId': senderId,
               });
               // This will trigger the translation provider to run and update the database
               ref.read(translationFamilyProvider(translationParams));
             }
           }
         } else {
           debugPrint('Ignoring INSERT for own message');
         }
       } else if (eventType == PostgresChangeEvent.update) {
         localDb.mergeMessages(matchId, [payload.newRecord]);

         // Check if this update includes content that needs translation
         final messageId = payload.newRecord['id'];
         final contentOriginal = payload.newRecord['content_original'];
         final senderId = payload.newRecord['sender_id'];
         final currentUserId = supabase.auth.currentUser?.id;

         // Trigger translation if this is an incoming message with content that might need translation
         if (messageId != null && contentOriginal != null && contentOriginal.isNotEmpty &&
             senderId != null && senderId != currentUserId) {
           final now = DateTime.now();
           final last = _lastTranslationTriggeredAt[messageId];
           if (last != null && now.difference(last) < const Duration(seconds: 2)) {
             debugPrint('Skipping duplicate translation trigger for updated message: $messageId');
           } else {
             _lastTranslationTriggeredAt[messageId] = now;
             debugPrint('Triggering translation for updated incoming message: $messageId');
             final translationParams = jsonEncode({
               'text': contentOriginal,
               'matchId': matchId,
               'messageId': messageId,
               'otherUserId': senderId,
             });
             // This will trigger the translation provider to run and update the database
             ref.read(translationFamilyProvider(translationParams));
           }
         }
       } else if (eventType == PostgresChangeEvent.delete) {
         final deletedId = payload.oldRecord['id'];
         // For DELETE events, oldRecord may only contain the primary key (id)
         // The channel filter ensures this event is for our match
         if (deletedId != null) {
           await localDb.deleteMessage(matchId, deletedId);

           // If there are no messages left for this match, remove the recent chat
           try {
             final remaining = await localDb.getMessages(matchId);
             final currentUserId = supabase.auth.currentUser?.id;
             if ((remaining.isEmpty) && (currentUserId != null && currentUserId.isNotEmpty)) {
               await localDb.deleteChat(matchId, userId: currentUserId);
             }
           } catch (e) {
             // Ignore local DB errors – we don't want realtime handling to crash
           }
         }
       }
     } catch (e) {
       // Swallow handler errors to avoid noisy logs; local DB operations should surface errors where appropriate.
     }
   }

  channel.onPostgresChanges(
    event: PostgresChangeEvent.all, // Catches INSERTs, UPDATEs, and DELETEs
    schema: 'public',
    table: 'chat_messages',
    callback: handleChanges,
  ).subscribe((status, err) async {
    if (status == RealtimeSubscribeStatus.subscribed) {
      // Run a full sync ONCE on subscribe, to catch up
      await syncService.syncMessages(matchId);
    } else if (err != null) {
      // suppress noisy logging here
    }
  });

  ref.onDispose(() {
    disposed = true;
    localSubscription.cancel();
    supabase.removeChannel(channel);
    streamController.close();
  });

  return streamController.stream;
});


// --- chatServiceProvider (Unchanged) ---
final chatServiceProvider = Provider((ref) => ChatService(ref));

class ChatService {
  final Ref _ref;
  ChatService(this._ref);

  Future<void> sendMessage({
    required String matchId,
    required String text,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);
    final tempId = uuid.v4();
    final optimisticMessage = ChatMessageModel(
      id: tempId, 
      matchId: matchId,
      senderId: user.id,
      contentOriginal: text,
      createdAt: DateTime.now(), 
      isPending: true, 
    );
    try {
      await localDb.addMessages(matchId, [optimisticMessage.toJson()]);
    } catch (e) {
      // Keep higher-level error handling; avoid extra logs here.
    }
    final connectivityResult = await Connectivity().checkConnectivity();
    final isOnline = connectivityResult.any((r) => r != ConnectivityResult.none);
    final supabasePayload = {
      'match_id': matchId,
      'sender_id': user.id,
      'content_original': text,
    };
    if (isOnline) {
      try {
        final data = await supabase
            .from('chat_messages')
            .insert(supabasePayload)
            .select();
        if (data.isEmpty) {
          throw Exception('Invalid response format: expected non-empty List, got ${data.runtimeType}');
        }
        final firstItem = data[0];
        await localDb.replaceMessage(matchId, tempId, firstItem);
      } catch (e) {
        await _saveToOutbox(supabasePayload);
      }
    } else {
      await _saveToOutbox(supabasePayload);
    }
  }

  Future<void> _saveToOutbox(Map<String, dynamic> messagePayload) async {
    final localDb = _ref.read(localDbProvider);
    await localDb.saveMessageToOutbox(messagePayload);
  }

  /// Set or clear a reaction for a message. p_reaction==null clears reaction for current user.
  Future<void> setReaction({required String matchId, required String messageId, String? reaction}) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);

    // Optimistic local update: modify local cache immediately for snappy UI
    try {
      // Fetch current messages for this match
      final messages = await localDb.getMessages(matchId);
      final idx = messages.indexWhere((m) => m['id']?.toString() == messageId);
      if (idx != -1) {
        final msg = Map<String, dynamic>.from(messages[idx]);
        // update my_reaction
        if (reaction == null) {
          msg.remove('my_reaction');
        } else {
          msg['my_reaction'] = reaction;
        }

        // update reaction_summary counts optimistically
        final Map<String, dynamic> summary = (msg['reaction_summary'] is Map) ? Map<String, dynamic>.from(msg['reaction_summary']) : {};
        // decrement previous reaction if any
        final prev = messages[idx]['my_reaction'] as String?;
        if (prev != null) {
          final int prevCount = (summary[prev] as int?) ?? 0;
          if (prevCount <= 1) {
            summary.remove(prev);
          } else {
            summary[prev] = prevCount - 1;
          }
        }
        if (reaction != null) {
          final int cur = (summary[reaction] as int?) ?? 0;
          summary[reaction] = cur + 1;
        }
        msg['reaction_summary'] = summary;

        messages[idx] = msg;
        await localDb.saveMessages(matchId, messages);
      }
    } catch (_) {}

    try {
      final res = await supabase.rpc('set_message_reaction', params: {
        'p_message_id': messageId,
        'p_reaction': reaction,
      }).single();

      // RPC returns new_summary jsonb; apply it to local DB
      final newSummary = res as Map<String, dynamic>?;
      if (newSummary != null) {
        await localDb.mergeMessages(matchId, [ {'id': messageId, 'reaction_summary': newSummary} ]);
        // Also set my_reaction locally to confirm
        await localDb.mergeMessages(matchId, [ {'id': messageId, 'my_reaction': reaction} ]);
      }
    } catch (e) {
      // On failure revert optimistic update by syncing messages for the match
      try {
        await _ref.read(chatSyncProvider(matchId)).syncMessages(matchId);
      } catch (_) {}
      rethrow;
    }
  }
}
// --- END chatServiceProvider ---


// ---
// --- UPDATED: Translation State Management (listens to locale changes)
// ---
typedef TranslationStates = Map<String, String>;

class TranslationNotifier extends Notifier<TranslationStates> {
  // Base prefs key - actual stored key is namespaced per-user: '${_prefsKeyBase}_<userId>'
  static const String _prefsKeyBase = 'translation_states';

  @override
  TranslationStates build() {
    // Load for the currently signed-in user (if any)
    _loadFromPrefsForCurrentUser();

    // Also listen to auth state changes so we can reload when user signs in/out/switches
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      _loadFromPrefsForCurrentUser();
    });

    return {}; // Return empty state initially, will be updated when loaded
  }

  String _prefsKeyForUser(String? userId) => '$_prefsKeyBase${userId == null ? '' : '_$userId'}';

  Future<void> _loadFromPrefsForCurrentUser() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    await _loadFromPrefsForUser(userId);
  }

  Future<void> _loadFromPrefsForUser(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _prefsKeyForUser(userId);
      final jsonString = prefs.getString(key);
      if (jsonString != null) {
        final Map<String, dynamic> decoded = jsonDecode(jsonString);
        final Map<String, String> loaded = {};
        decoded.forEach((key, value) {
          if (value != null) loaded[key] = value as String;
        });
        state = loaded;
      } else {
        // No stored prefs for this user - leave state empty
        state = {};
      }
    } catch (e) {
      // Ignore errors, keep empty state
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final key = _prefsKeyForUser(userId);
      final jsonString = jsonEncode(state);
      await prefs.setString(key, jsonString);
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> setTranslation(String matchId, String? targetLang) async {
    final previous = state[matchId];

    // Optimistically update in-memory state and prefs
    if (targetLang == null) {
      state = {...state}..remove(matchId);
    } else {
      state = {
        ...state,
        matchId: targetLang,
      };
    }
    await _saveToPrefs();

    final userId = Supabase.instance.client.auth.currentUser?.id;

    // Immediately update local cache to reflect the new flag for UX
    try {
      if (userId != null) {
        final localDb = ref.read(localDbProvider);
        await localDb.updateChatTranslation(userId, matchId, targetLang != null, targetLang);
      }
    } catch (_) {
      // best-effort
    }

    // Notify UI providers to refresh translations
    ref.read(translationVersionProvider.notifier).increment();

    // If translation was turned OFF, clear any cached translations
    if (targetLang == null && matchId.isNotEmpty) {
      try {
        final localDb = ref.read(localDbProvider);
        await localDb.clearCachedTranslationsForMatch(matchId, userId: userId);
      } catch (e) {
        // Ignore failures - clearing cache is best-effort
      }
    }

    // Persist to server; if it fails, revert and rethrow so callers can show UI feedback
    try {
      if (userId != null) {
        await Supabase.instance.client.rpc('set_chat_translation', params: {
          'p_user_id': userId,
          'p_match_id': matchId,
          'p_enabled': targetLang != null,
          'p_language': targetLang,
        });

        // After successful write, trigger a background sync to pick up server canonical data
        try {
          await ref.read(globalSyncManagerProvider).syncChatsNow(userId);
          ref.invalidate(recentChatsProvider(userId));
        } catch (_) {}
      }
    } catch (e) {
      // Revert optimistic update
      if (previous == null) {
        state = {...state}..remove(matchId);
      } else {
        state = {...state, matchId: previous};
      }
      await _saveToPrefs();

      // Revert local cache
      try {
        if (userId != null) {
          final localDb = ref.read(localDbProvider);
          await localDb.updateChatTranslation(userId, matchId, previous != null, previous);
        }
      } catch (_) {}

      rethrow;
    }
  }
}

final translationProvider = NotifierProvider<TranslationNotifier, TranslationStates>(() {
  return TranslationNotifier();
});
// --- END Translation State ---


// ---
// --- *** UPDATED: translationFamilyProvider (translates to current UI language)
// --- Translates incoming messages to the current app UI language when translation is enabled.
// --- Only translates messages from other users, not outgoing messages.
// ---
final translationFamilyProvider = FutureProvider.autoDispose
    .family<String, String>((ref, paramsString) async {
  // Depend on translation version to ensure re-evaluation when toggled
  ref.watch(translationVersionProvider);

  final Map<String, dynamic> params;
  try {
    params = jsonDecode(paramsString) as Map<String, dynamic>;
  } catch (e) {
  
    return 'Error parsing params';
  }

  final text = params['text'] as String?;
  final matchId = params['matchId'] as String?;
  final messageId = params['messageId'] as String?;
  final otherUserId = params['otherUserId'] as String?;




  if (text == null || matchId == null || messageId == null || text.isEmpty) {
    return text ?? 'Error: invalid params';
  }

  final localDb = ref.read(localDbProvider);

  // 1. Check if translation is even on for this chat
  final translationEnabled = ref.watch(translationProvider)[matchId] != null;

  if (!translationEnabled) {
    // Translation is off for this chat.

    return text;
  }

  // 2. Get the current UI language as the target language
  final currentUILocale = ref.watch(localizationProvider).currentLocale;
  final targetLanguage = currentUILocale.languageCode;


  // 2. Load message data once from local DB for both sender check and cache check
  if (matchId.isEmpty) return text;

  final messages = await localDb.getMessages(matchId);
  final message = messages.firstWhere((m) => m['id'].toString() == messageId, orElse: () => {});
  final senderId = message['sender_id'] as String?;
  final cachedTranslation = message['translated_text'] as String?;
  final cachedLang = message['translated_lang'] as String?;

  // Check if this is an outgoing message (from current user) - don't translate those
  final currentUserId = supabase.auth.currentUser?.id;
  if (senderId == currentUserId) {
    // This is our own message, don't translate it
    return text;
  }

  // 3. Identify source language first. If source is same as target, do NOT translate or cache.
  final translator = ref.watch(translationServiceProvider);
  String sourceLanguage;
  try {
    // Language identification can fail for very short texts or emoji-heavy messages.
    // Use a sanitized string for identification but translate the original to preserve emojis.
    final textForLangId = _stripEmojisForLanguageId(text);

    sourceLanguage = await translator.identifyLanguage(textForLangId.isEmpty ? text : textForLangId);
    // Fallback: If detection fails, try to guess based on common patterns
    if (sourceLanguage == 'und') {
      final fallbackLang = _guessLanguageFromText(text);

      sourceLanguage = fallbackLang;
    }
  } catch (e) {
    // Fallback language detection if API fails
    sourceLanguage = _guessLanguageFromText(text);

  }


  if (sourceLanguage == targetLanguage) {
    // Already in target language — return original, don't cache.

    return text;
  }

  // Convert 'und' to 'auto' for API calls
  final apiSourceLang = sourceLanguage == 'und' ? 'auto' : sourceLanguage;


  // 4. Check local DB cache for existing translation (only meaningful now because source != target)
  // Only return the cache if it's not empty AND it matches our target language
  if (cachedTranslation != null && cachedTranslation.isNotEmpty && cachedLang == targetLanguage) {
    return cachedTranslation;
  }

  // 5. Otherwise, fetch from API and save
  // Get recipient's gender for gender-aware translation
  String? recipientGender;
  if (otherUserId != null && otherUserId.isNotEmpty) {
    try {
      final otherUserProfile = await ref.watch(userProfileProvider(otherUserId).future);
      recipientGender = otherUserProfile?.gender;
    } catch (e) {
      // If we can't get the profile, continue without gender context
      recipientGender = null;
    }
  }

  String translatedText;
  try {

    translatedText = await translator.translateText(text, apiSourceLang, targetLanguage, recipientGender: recipientGender);



  } catch (e) {

    return text; // Return original text on failure
  }

  translatedText = _ensureEmojisPreserved(original: text, translated: translatedText);

  // Save the new translation AND the language to the local DB

  await localDb.saveTranslation(matchId, messageId, translatedText, targetLanguage);

  // Also update the chat record with the translated last message if this was the last message
  try {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) {
      // Can't update chat record without user ID, but translation is still saved
      return translatedText;
    }

    final messages = await localDb.getMessages(matchId);
    if (messages.isNotEmpty) {
      // Sort by created_at descending to find the latest message
      messages.sort((a, b) {
        final aDate = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bDate = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bDate.compareTo(aDate);
      });

      final latestMessage = messages.first;
      if (latestMessage['id'] == messageId) {
        // This translated message is the latest message, update the chat record

        await localDb.updateChatLastMessageTranslation(currentUserId, matchId, messageId, translatedText);
      }
    }
  } catch (e) {
    // Intentionally ignoring errors: failing to update chat record is non-critical.
  }

  // Also update the message in Supabase with the translation
  try {

    await supabase
        .from('chat_messages')
        .update({'content_translated': translatedText})
        .eq('id', messageId);

  } catch (e) {

    // If Supabase update fails, the translation is still saved locally
    // This is not critical since local cache takes precedence
  }



  // Notify that a translation has completed to trigger UI updates
  ref.read(translationVersionProvider.notifier).increment();

  return translatedText;
});

/// Strip emojis and most non-letter characters to improve language identification.
String _stripEmojisForLanguageId(String input) {
  final buf = StringBuffer();
  for (final ch in input.characters) {
    final s = ch.toString();
    if (_looksLikeEmoji(s)) continue;
    if (RegExp(r'[\p{L}\p{N}\s]', unicode: true).hasMatch(s)) {
      buf.write(s);
    } else {
      buf.write(' ');
    }
  }
  return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Simple fallback language detection based on character patterns
String _guessLanguageFromText(String text) {
  if (text.trim().isEmpty) return 'und';

  debugPrint('_guessLanguageFromText: Analyzing text: "$text"');

  // Count different types of characters
  int latinLetters = 0;
  int cyrillicLetters = 0;
  int arabicLetters = 0;
  int hebrewLetters = 0;
  int chineseChars = 0;
  int japaneseChars = 0;
  int koreanChars = 0;

  for (int i = 0; i < text.length; i++) {
    final char = text[i];
    final code = char.codeUnitAt(0);

    // Latin (English, Spanish, French, etc.)
    if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
      latinLetters++;
    }
    // Cyrillic (Russian, etc.)
    else if ((code >= 1040 && code <= 1103) || code == 1025 || code == 1105) {
      cyrillicLetters++;
    }
    // Arabic
    else if (code >= 1536 && code <= 1791) {
      arabicLetters++;
    }
    // Hebrew
    else if (code >= 1424 && code <= 1535) {
      hebrewLetters++;
    }
    // Chinese/Japanese/Korean
    else if (code >= 19968 && code <= 40959) {
      chineseChars++;
    }
    else if (code >= 12352 && code <= 12543) {
      japaneseChars++;
    }
    else if (code >= 44032 && code <= 55215) {
      koreanChars++;
    }
  }

  // Find the most common script
  final counts = {
    'en': latinLetters,    // English (most common Latin)
    'ru': cyrillicLetters,
    'ar': arabicLetters,
    'he': hebrewLetters,
    'zh': chineseChars,
    'ja': japaneseChars,
    'ko': koreanChars,
  };

  final maxEntry = counts.entries.reduce((a, b) => a.value > b.value ? a : b);
  debugPrint('_guessLanguageFromText: Max script count: ${maxEntry.key}=${maxEntry.value}');
  if (maxEntry.value > 0) {
    debugPrint('_guessLanguageFromText: Returning script-based language: ${maxEntry.key}');
    return maxEntry.key;
  }

  // If no specific script detected, assume English for common words
  final lowerText = text.toLowerCase();
  final commonEnglishWords = ['the', 'is', 'and', 'this', 'that', 'with', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'had', 'her', 'was', 'one', 'our', 'out', 'day', 'get', 'has', 'him', 'his', 'how', 'its', 'may', 'new', 'now', 'old', 'see', 'two', 'way', 'who', 'boy', 'did', 'has', 'let', 'put', 'say', 'she', 'too', 'use'];
  final words = lowerText.split(RegExp(r'\s+'));
  final englishWordCount = words.where((word) => commonEnglishWords.contains(word)).length;

  debugPrint('_guessLanguageFromText: English word count: $englishWordCount, words: $words');
  if (englishWordCount > 0 || RegExp(r'\b(the|is|and|this|that|with|for|are|but|not|you|all|can|had|her|was|one|our|out|day|get|has|him|his|how|its|may|new|now|old|see|two|way|who|boy|did|has|let|put|say|she|too|use)\b', caseSensitive: false).hasMatch(text)) {
    debugPrint('_guessLanguageFromText: Returning English based on common words');
    return 'en';
  }

  debugPrint('_guessLanguageFromText: Returning undetermined');
  return 'und';
}

bool _looksLikeEmoji(String grapheme) {
  // Broad, best-effort emoji/pictographic range match.
  return RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true).hasMatch(grapheme);
}

String _ensureEmojisPreserved({required String original, required String translated}) {
  final originalEmojis = <String>[];
  for (final ch in original.characters) {
    final s = ch.toString();
    if (_looksLikeEmoji(s)) originalEmojis.add(s);
  }
  if (originalEmojis.isEmpty) return translated;

  final missing = originalEmojis.where((e) => !translated.contains(e)).toList();
  if (missing.isEmpty) return translated;

  final suffix = missing.join('');
  final needsSpace = translated.isNotEmpty && !translated.endsWith(' ') && !translated.endsWith('\n');
  return needsSpace ? '$translated $suffix' : '$translated$suffix';
}
