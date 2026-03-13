// lib/providers/home_providers.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/background_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final supabase = Supabase.instance.client;

// Helper function to format sender name: "FirstName LastInitial." e.g., "John S."
String formatSenderNameForNotification(String fullName) {
  if (fullName.isEmpty) return 'MatchMe';

  final parts = fullName.trim().split(RegExp(r'\s+'));
  if (parts.length == 1) {
    return parts[0]; // Just first name if no last name
  }

  // First name + first letter of last name with period
  final firstName = parts[0];
  final lastInitial = parts[parts.length - 1][0].toUpperCase();
  return '$firstName $lastInitial.';
}

// --- recentMatchesProvider (Reads Local DB Only) ---
final recentMatchesProvider = StreamProvider.autoDispose.family<
  List<MatchModel>,
  String
>((ref, userId) {
  if (userId.isEmpty) return Stream.value([]);

  final localDb = ref.watch(localDbProvider);

  // Ensure sync manager is initialized to trigger initial data sync
  ref.watch(globalSyncManagerProvider);

  final localStream = localDb.watchMatches();

  return localStream.map((list) {
    final mapped = list
        .map((json) => MatchModel.fromJsonRpc(json, userId))
        .toList();
    developer.log('🏠 recentMatchesProvider update: user=$userId, count=${mapped.length}', name: 'MatchMeTrace');
    if (mapped.isNotEmpty) {
      developer.log('🏠 recentMatchesProvider first match: matchId=${mapped.first.id}, otherUserId=${mapped.first.otherUserId}', name: 'MatchMeTrace');
    }
    return mapped;
  });
});

// --- END UPDATE ---

// Track previous chat states for detecting new unread messages via sync path
final Map<String, int> _previousChatUnreadCounts = {};
final Set<String> _pendingTranslatedNotificationMessageIds = <String>{};
final Set<String> _notifiedMessageIds = <String>{};
final Map<String, ChatModel> _recentChatSnapshots = <String, ChatModel>{};
final Set<String> _inFlightPreviewTranslationKeys = <String>{};

Future<void> _triggerImmediateLastMessageTranslation({
  required Ref ref,
  required String userId,
  required String matchId,
  required String messageId,
  required String targetLanguage,
}) async {
  final translationKey = '$userId|$matchId|$messageId|$targetLanguage';
  if (!_inFlightPreviewTranslationKeys.add(translationKey)) {
    return;
  }

  try {
    await supabase.functions.invoke(
      'translate-proxy',
      body: {
        'match_id': matchId,
        'target_language': targetLanguage,
        'retranslate_all': true,
        'exclude_sender_id': userId,
      },
    );

    final refreshed = await supabase
        .from('chat_messages')
        .select('content_translated, translated_target_language')
        .eq('id', messageId)
        .maybeSingle();

    final translated = refreshed?['content_translated'] as String?;
    final translatedTarget = refreshed?['translated_target_language']?.toString();
    final hasTranslated = translated != null &&
        translated.isNotEmpty &&
        translated != 'null';
    final matchesTarget = translatedTarget != null &&
        translatedTarget.isNotEmpty &&
        normalizeLanguageCode(translatedTarget) == targetLanguage;

    if (hasTranslated && matchesTarget) {
      final localDb = ref.read(localDbProvider);
      await localDb.updateChatLastMessageTranslation(
        userId,
        matchId,
        messageId,
        translated,
      );
    }
  } catch (e) {
    debugPrint('🔄 [SYNC FALLBACK] Immediate preview translation failed for $messageId: $e');
  } finally {
    _inFlightPreviewTranslationKeys.remove(translationKey);
  }
}

// --- recentChatsProvider (Reads Local DB Only) ---
final recentChatsProvider = StreamProvider.family<
  List<ChatModel>,
  String
>((ref, userId) {
  if (userId.isEmpty) {
    return Stream.value([]);
  }

  final localDb = ref.watch(localDbProvider);
  final uiLang = normalizeLanguageCode(ref.watch(localizationProvider).currentLocale.languageCode);

  final localStream = localDb.watchChats(userId);

  // Add logging for web debugging
  if (kIsWeb) {
  }

  // Use the correct provider name here
  final syncService = ref.read(globalSyncManagerProvider);

  final chatUpdateChannel = supabase
      .channel('public:chat_messages:for_user_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_messages',
        callback: (payload) async {
            // Ignore callbacks if provider has been disposed
            if (!ref.mounted) {
              return;
            }

            // Handle message updates (insert, update, delete) - sync chats to update preview
            if (payload.eventType == PostgresChangeEvent.insert || 
                payload.eventType == PostgresChangeEvent.update || 
                payload.eventType == PostgresChangeEvent.delete) {
              try {
                // Add small delay to ensure database trigger has completed
                await Future.delayed(const Duration(milliseconds: 100));
                await syncService.syncChatsNow(userId);
                // Note: totalUnreadChatCountProvider watches recentChatsProvider,
                // so it will automatically update when the local DB changes
              } catch (e) {
                debugPrint('🔄 Error syncing chats on realtime change: $e');
              }
            }

            if (payload.eventType == PostgresChangeEvent.insert ||
                payload.eventType == PostgresChangeEvent.update) {
              final senderId = payload.newRecord['sender_id'];
              final currentUserId = supabase.auth.currentUser?.id;
              final matchId = payload.newRecord['match_id'] as String?;
              final messageId = payload.newRecord['id'] as String?;

              if (currentUserId != null && senderId != currentUserId) {
                final originalContent = payload.newRecord['content_original'] as String?;
                final serverTranslatedContent = payload.newRecord['content_translated'] as String?;
                final oldTranslatedContent = payload.oldRecord['content_translated'] as String?;
                final hasTranslatedContent = serverTranslatedContent != null &&
                    serverTranslatedContent.isNotEmpty &&
                    serverTranslatedContent != 'null';
                final wasTranslatedBefore = oldTranslatedContent != null &&
                    oldTranslatedContent.isNotEmpty &&
                    oldTranslatedContent != 'null';
                final isTranslationUpdate = payload.eventType == PostgresChangeEvent.update &&
                    hasTranslatedContent &&
                    !wasTranslatedBefore;

                if (((originalContent != null && originalContent.isNotEmpty) || hasTranslatedContent) &&
                    messageId != null &&
                    matchId != null) {
                  if (_notifiedMessageIds.contains(messageId)) {
                    if (isTranslationUpdate) {
                      _pendingTranslatedNotificationMessageIds.remove(messageId);
                    }
                    return;
                  }

                  try {
                    final localDb = ref.read(localDbProvider);
                    if (payload.eventType == PostgresChangeEvent.insert) {
                      final messagesToDeliver = await localDb.addMessages(
                        matchId,
                        [payload.newRecord],
                        currentUserId: currentUserId,
                      );
                      if (messagesToDeliver.isNotEmpty) {
                        unawaited(
                          Future.wait(
                            messagesToDeliver.map((msgId) =>
                              supabase.rpc('mark_message_delivered', params: {'p_message_id': msgId})
                                .catchError((e) {
                                  debugPrint('❌ home_providers: Failed to mark $msgId as delivered: $e');
                                })
                            ),
                            eagerError: false,
                          )
                        );
                      }
                    }
                  } catch (e) {
                    debugPrint('❌ Failed to save message to local DB: $e');
                  }

                  bool isTranslationEnabled = false;
                  try {
                    final localDb = ref.read(localDbProvider);
                    isTranslationEnabled = await localDb.isTranslationEnabled(matchId, userId: currentUserId);
                  } catch (e) {
                    debugPrint('Failed to check translation status: $e');
                  }

                  if (payload.eventType == PostgresChangeEvent.insert &&
                      isTranslationEnabled &&
                      !hasTranslatedContent) {
                    _pendingTranslatedNotificationMessageIds.add(messageId);
                    return;
                  }

                  if (payload.eventType == PostgresChangeEvent.update) {
                    final shouldNotifyTranslationUpdate =
                        _pendingTranslatedNotificationMessageIds.contains(messageId) &&
                        hasTranslatedContent;
                    if (!shouldNotifyTranslationUpdate) {
                      return;
                    }
                  }

                  final displayContent = hasTranslatedContent
                      ? serverTranslatedContent
                      : (originalContent ?? '');
                  if (displayContent.isEmpty) {
                    return;
                  }

                  String senderName = 'MatchMe';
                  try {
                    final userData = await supabase
                        .from('users')
                        .select('name')
                        .eq('id', senderId)
                        .single();
                    senderName = userData['name'] as String? ?? 'MatchMe';
                    senderName = formatSenderNameForNotification(senderName);
                  } catch (e) {
                    debugPrint('⚠️ Failed to fetch sender name: $e');
                  }

                  final now = DateTime.now();
                  final timestamp = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 10).toString().padLeft(2, '0')}';
                  debugPrint('🔔 [NOTIFY] $timestamp | Chat=$matchId | From=$senderName | MessageId=$messageId | Translation=${isTranslationEnabled ? "YES" : "NO"}');

                  if (kIsWeb) {
                    final webTime = DateTime.now();
                    final webTimestamp = '${webTime.hour.toString().padLeft(2, '0')}:${webTime.minute.toString().padLeft(2, '0')}:${webTime.second.toString().padLeft(2, '0')}.${(webTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint('🔔 [WEB_NOTIFY] $webTimestamp | Browser notification');
                    WebNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  } else if (Platform.isAndroid) {
                    final androidTime = DateTime.now();
                    final androidTimestamp = '${androidTime.hour.toString().padLeft(2, '0')}:${androidTime.minute.toString().padLeft(2, '0')}:${androidTime.second.toString().padLeft(2, '0')}.${(androidTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint('🔔 [ANDROID_NOTIFY] $androidTimestamp | Background service');
                    // On Android, trigger the background service to check for notifications immediately
                    // Use translated content for notification if translation is enabled
                    Future.delayed(const Duration(milliseconds: 200), () {
                      BackgroundService.triggerNotificationCheck(
                        messageId: messageId,
                        translatedContent: displayContent,
                        originalContent: originalContent,
                        senderName: senderName,
                        matchId: matchId,
                      );
                    });
                  } else if (Platform.isIOS) {
                    // On iOS, use iOS notification service
                    final iosTime = DateTime.now();
                    final iosTimestamp = '${iosTime.hour.toString().padLeft(2, '0')}:${iosTime.minute.toString().padLeft(2, '0')}:${iosTime.second.toString().padLeft(2, '0')}.${(iosTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint('🔔 [IOS_NOTIFY] $iosTimestamp | Local notification');
                    await MobileLocalNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  }
                  _notifiedMessageIds.add(messageId);
                  _pendingTranslatedNotificationMessageIds.remove(messageId);
                }
              }
            }

            // All INSERT/UPDATE/DELETE events are synced above  
          },
      )
      .subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint('✅ Chat messages subscription active for user: $userId');
        } else if (status == RealtimeSubscribeStatus.closed || status == RealtimeSubscribeStatus.channelError) {
          debugPrint('⚠️ Chat messages subscription disconnected - status: $status, error: $err');
          
          // Prevent reconnect loop if app is in background
          if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused || 
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
            debugPrint('⏸️ App in background, skipping auto-reconnect');
            return;
          }

          // Attempt automatic reconnection
          Future.delayed(const Duration(seconds: 2), () {
            if (ref.mounted) {
              debugPrint('🔄 Attempting to reconnect chat messages subscription...');
              ref.invalidateSelf();
            }
          });
        }
      });

  // Subscribe to matches table changes for real-time match deletions
  final matchUpdateChannel = supabase
      .channel('public:matches:for_user_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'matches',
        callback: (payload) async {
          debugPrint('Realtime: Match ${payload.eventType} detected: ${payload.newRecord}');
          // Ignore callbacks if provider has been disposed
          if (!ref.mounted) return;
          // When matches change, sync chats and matches to reflect any deletions
          try {
            await syncService.syncChatsNow(userId);
            await syncService.syncMatchesNow(userId);
          } catch (e) {
            debugPrint('Error syncing on match realtime update: $e');
          }
        },
      )
      .subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint('✅ Matches subscription active for user: $userId');
        } else if (status == RealtimeSubscribeStatus.closed || status == RealtimeSubscribeStatus.channelError) {
          debugPrint('⚠️ Matches subscription disconnected - status: $status, error: $err');
          
          // Prevent reconnect loop if app is in background
          if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused || 
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
            debugPrint('⏸️ App in background, skipping auto-reconnect');
            return;
          }

          // Attempt automatic reconnection
          Future.delayed(const Duration(seconds: 2), () {
            if (ref.mounted) {
              debugPrint('🔄 Attempting to reconnect matches subscription...');
              ref.invalidateSelf();
            }
          });
        }
      });

  // Subscribe to chats table changes for real-time chat deletions
  final chatsUpdateChannel = supabase
      .channel('public:chats:for_user_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chats',
        callback: (payload) async {
          debugPrint('Realtime: Chat ${payload.eventType} detected: ${payload.newRecord}');
          // Ignore callbacks if provider has been disposed
          if (!ref.mounted) return;
          // When chats change, sync chats to reflect any deletions
          try {
            await syncService.syncChatsNow(userId);
          } catch (e) {
            debugPrint('Error syncing on chat realtime update: $e');
          }
        },
      )
      .subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint('✅ Chats subscription active');
        } else if (status == RealtimeSubscribeStatus.closed || status == RealtimeSubscribeStatus.channelError) {
          debugPrint('⚠️ Chats subscription disconnected - status: $status, error: $err');
          
          // Prevent reconnect loop if app is in background
          if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused || 
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
            debugPrint('⏸️ App in background, skipping auto-reconnect');
            return;
          }

          // Attempt automatic reconnection
          Future.delayed(const Duration(seconds: 2), () {
            if (ref.mounted) {
              debugPrint('🔄 Attempting to reconnect chats subscription...');
              ref.invalidateSelf();
            }
          });
        }
      });

  ref.onDispose(() {
    supabase.removeChannel(chatUpdateChannel);
    supabase.removeChannel(matchUpdateChannel);
    supabase.removeChannel(chatsUpdateChannel);
  });

  // Handle translation display for Recent Chats and detect new messages via sync
  return localStream.asyncMap((list) async {
    try {
      debugPrint('🔄 Recent Chats Provider: Processing ${list.length} chats from local DB');

      for (final json in list) {
        final matchId = json['match_id']?.toString();
        if (matchId != null && matchId.isNotEmpty) {
          final snapshotKey = '$userId|$matchId';
          final existingChat = _recentChatSnapshots[snapshotKey];
          if (existingChat != null) {
            continue;
          }
          try {
            final chat = ChatModel.fromJsonRpc(json);
            _recentChatSnapshots[snapshotKey] = chat;
          } catch (e) {
            debugPrint('Recent chats snapshot parse failed for $snapshotKey: $e');
          }
        }
      }

      final chats = await Future.wait(list
          .map((json) async {
            try {
              final chat = ChatModel.fromJsonRpc(json);
              final matchId = json['match_id']?.toString();
              final unreadRaw = json['unread_count'];
              final unreadCount = unreadRaw is int
                  ? unreadRaw
                  : int.tryParse(unreadRaw?.toString() ?? '') ?? 0;
              final lastMessageSenderId = json['last_message_sender_id']?.toString();

              debugPrint('🔄 Recent Chats Provider: Chat $matchId - unreadCount: $unreadCount');

          // Skip notifications for own messages
          if (lastMessageSenderId == userId && matchId != null) {
            debugPrint('🔄 [SYNC FALLBACK] Skipping notification for own message');
            _previousChatUnreadCounts[matchId] = unreadCount;
            // Continue to next chat without triggering notification
          } else if (matchId != null &&
              lastMessageSenderId != null &&
              unreadCount > 0) {

            final previousUnread = _previousChatUnreadCounts[matchId] ?? 0;

            final lastMessageId = json['last_message_id'] as String?;
            final translationEnabled = json['translation_enabled'] == true;
            final serverTranslatedContent = json['last_message_translated'] as String?;
            final hasServerTranslation = serverTranslatedContent != null &&
                serverTranslatedContent.isNotEmpty &&
                serverTranslatedContent != 'null';
            final isPendingTranslatedNotification = lastMessageId != null &&
                _pendingTranslatedNotificationMessageIds.contains(lastMessageId);
            final shouldProcessNotification = unreadCount > previousUnread ||
                (isPendingTranslatedNotification && hasServerTranslation);

            if (shouldProcessNotification) {
              debugPrint('🔄 [SYNC FALLBACK] Detected new message(s) via sync for chat $matchId (was $previousUnread, now $unreadCount)');

              // This message arrived via sync, not realtime - trigger notification as fallback
              try {
                final messageContent = json['last_message'] as String? ?? 'New message';
                String? detectedSourceLang = json['last_message_source_language']?.toString();
                if (detectedSourceLang != null &&
                    detectedSourceLang.isNotEmpty &&
                    detectedSourceLang != 'null') {
                  detectedSourceLang = normalizeLanguageCode(detectedSourceLang);
                } else {
                  detectedSourceLang = null;
                }

                if ((detectedSourceLang == null || detectedSourceLang.isEmpty) &&
                    lastMessageId != null &&
                    lastMessageId.isNotEmpty) {
                  try {
                    final messages = await localDb.getMessages(matchId);
                    final rawMessage = messages.firstWhere(
                      (m) => (m['id']?.toString() ?? '') == lastMessageId,
                      orElse: () => <String, dynamic>{},
                    );
                    if (rawMessage.isNotEmpty) {
                      final rawSource = (rawMessage['detected_source_language'] ??
                              rawMessage['source_language'] ??
                              rawMessage['language'])
                          ?.toString();
                      if (rawSource != null && rawSource.isNotEmpty && rawSource != 'null') {
                        detectedSourceLang = normalizeLanguageCode(rawSource);
                      }
                    }
                  } catch (_) {}
                }

                final shouldWaitForTranslation = translationEnabled &&
                    !hasServerTranslation &&
                    (detectedSourceLang == null || detectedSourceLang != uiLang);

                if (shouldWaitForTranslation && lastMessageId != null && lastMessageId.isNotEmpty) {
                  _pendingTranslatedNotificationMessageIds.add(lastMessageId);
                  debugPrint('🔄 [SYNC FALLBACK] Waiting for translation before notifying for message $lastMessageId');
                  _previousChatUnreadCounts[matchId] = unreadCount;
                  return chat;
                }

                final displayContent = hasServerTranslation
                    ? serverTranslatedContent
                    : messageContent;
                if (displayContent.isEmpty) {
                  _previousChatUnreadCounts[matchId] = unreadCount;
                  return chat;
                }

                // Fetch sender name
                String senderName = 'MatchMe';
                try {
                  final userData = await supabase
                      .from('users')
                      .select('name')
                      .eq('id', lastMessageSenderId)
                      .single();
                  senderName = userData['name'] as String? ?? 'MatchMe';
                  senderName = formatSenderNameForNotification(senderName);
                  debugPrint('🔄 [SYNC FALLBACK] Formatted sender name for notification: "$senderName"');
                } catch (e) {
                  debugPrint('🔄 [SYNC FALLBACK] Failed to fetch sender name: $e, using default');
                }

                debugPrint('🔄 [SYNC FALLBACK] ═══════════════════════════════════════════════════');
                debugPrint('🔄 [SYNC FALLBACK] NOTIFICATION TRIGGER - Message arrived via sync');
                debugPrint('🔄 [SYNC FALLBACK] Chat: $matchId');
                if (translationEnabled) {
                  debugPrint('🔄 [SYNC FALLBACK] Translation: ENABLED (showing translated message)');
                } else {
                  debugPrint('🔄 [SYNC FALLBACK] Translation: DISABLED (showing original message)');
                }
                debugPrint('🔄 [SYNC FALLBACK] ═══════════════════════════════════════════════════');

                // Trigger notifications via platform-specific services
                if (kIsWeb) {
                  debugPrint('🔄 [SYNC FALLBACK] Platform: Web - showing browser notification');
                  WebNotificationService.showMessageNotification(
                    chatId: matchId,
                    senderName: senderName,
                    messageContent: displayContent,
                    matchId: matchId,
                  );
                } else if (Platform.isAndroid) {
                  // On Android, notification will be handled by background service
                  debugPrint('🔄 [SYNC FALLBACK] Platform: Android - notification handled by background service');

                } else if (Platform.isIOS) {
                  debugPrint('🔄 [SYNC FALLBACK] Platform: iOS - showing local notification');
                  await MobileLocalNotificationService.showMessageNotification(
                    chatId: matchId,
                    senderName: senderName,
                    messageContent: displayContent,
                    matchId: matchId,
                  );
                }
                if (lastMessageId != null && lastMessageId.isNotEmpty) {
                  _pendingTranslatedNotificationMessageIds.remove(lastMessageId);
                  _notifiedMessageIds.add(lastMessageId);
                }
              } catch (e) {
                debugPrint('🔄 [SYNC FALLBACK] Error triggering notification: $e');
              }
            }

            // Update state to current unread count
            _previousChatUnreadCounts[matchId] = unreadCount;
          }

          final translationEnabled = json['translation_enabled'] == true;
          final lastMessageSenderIdCheck = json['last_message_sender_id'] as String?;
          final isIncomingLastMessage =
              lastMessageSenderIdCheck != null && lastMessageSenderIdCheck != userId;

          if (translationEnabled && isIncomingLastMessage) {
            final matchIdForCaseCheck = json['match_id']?.toString() ?? chat.matchId;
            final lastMessageId = json['last_message_id']?.toString();
            String? detectedSourceLang;
            String? translatedTargetLang;
            String? translatedPreview = json['last_message_translated'] as String?;

            try {
              if (matchIdForCaseCheck.isNotEmpty && lastMessageId != null && lastMessageId.isNotEmpty) {
                final messages = await localDb.getMessages(matchIdForCaseCheck);
                final rawMessage = messages.firstWhere(
                  (m) => (m['id']?.toString() ?? '') == lastMessageId,
                  orElse: () => <String, dynamic>{},
                );

                if (rawMessage.isNotEmpty) {
                  final rawSource = (rawMessage['detected_source_language'] ??
                          rawMessage['source_language'] ??
                          rawMessage['language'])
                      ?.toString();
                  if (rawSource != null && rawSource.isNotEmpty && rawSource != 'null') {
                    detectedSourceLang = normalizeLanguageCode(rawSource);
                  }

                  final rawTarget = rawMessage['translated_target_language']?.toString();
                  if (rawTarget != null && rawTarget.isNotEmpty && rawTarget != 'null') {
                    translatedTargetLang = normalizeLanguageCode(rawTarget);
                  }

                  final rawTranslated = rawMessage['content_translated'] as String?;
                  if ((translatedPreview == null || translatedPreview.isEmpty || translatedPreview == 'null') &&
                      rawTranslated != null &&
                      rawTranslated.isNotEmpty &&
                      rawTranslated != 'null') {
                    translatedPreview = rawTranslated;
                  }
                }
              }
            } catch (_) {}

            final hasTranslatedPreview = translatedPreview != null &&
                translatedPreview.isNotEmpty &&
                translatedPreview != 'null';

            // Check if this is a NEW message by comparing message IDs
            // OR if translation just became available for the SAME message
            final snapshotKey = '$userId|$matchIdForCaseCheck';
            final previousChat = _recentChatSnapshots[snapshotKey];
            
            // Determine if this is a new message (either no previous chat OR different message ID)
            final bool isNewMessage = (previousChat == null || 
                previousChat.lastMessageId != lastMessageId);
            
            // Handle the case where we need to check for translation availability
            // We can only check previousChat's translation if it exists
            bool translationJustBecameAvailable = false;
            if (previousChat != null) {
              // previousChat exists - check if translation just became available
              final String? prevTranslated = previousChat.lastMessageTranslated;
              final bool prevHadNoTranslation = (prevTranslated == null || prevTranslated.isEmpty || prevTranslated == 'null');
              translationJustBecameAvailable = !isNewMessage && prevHadNoTranslation && hasTranslatedPreview;
            }

            // If translation just became available for this message, we should show it!
            // This is the key case: new translation arrived for the same message
            if (translationJustBecameAvailable) {
              // Translation just arrived - show it!
              return chat.copyWith(
                lastMessage: translatedPreview,
                lastMessageTranslated: translatedPreview,
                lastMessageSourceLanguage: detectedSourceLang,
              );
            }

            if ((detectedSourceLang == null || detectedSourceLang.isEmpty) &&
                matchIdForCaseCheck.isNotEmpty &&
                lastMessageId != null &&
                lastMessageId.isNotEmpty) {
              try {
                final serverMessage = await supabase
                    .from('chat_messages')
                    .select('detected_source_language, translated_target_language, content_translated')
                    .eq('id', lastMessageId)
                    .maybeSingle();
                final serverSource = serverMessage?['detected_source_language']?.toString();
                if (serverSource != null && serverSource.isNotEmpty && serverSource != 'null') {
                  detectedSourceLang = normalizeLanguageCode(serverSource);
                }
                final serverTarget = serverMessage?['translated_target_language']?.toString();
                if (serverTarget != null && serverTarget.isNotEmpty && serverTarget != 'null') {
                  translatedTargetLang = normalizeLanguageCode(serverTarget);
                }
                final serverTranslated = serverMessage?['content_translated'] as String?;
                if (!hasTranslatedPreview &&
                    serverTranslated != null &&
                    serverTranslated.isNotEmpty &&
                    serverTranslated != 'null') {
                  translatedPreview = serverTranslated;
                }
              } catch (_) {}
            }

            final hasTranslatedPreviewAfterServerCheck = translatedPreview != null &&
                translatedPreview.isNotEmpty &&
                translatedPreview != 'null';
            final isCaseBAfterServerCheck = detectedSourceLang != null && detectedSourceLang == uiLang;
            final isCaseCAfterServerCheck = translatedTargetLang != null && translatedTargetLang == uiLang;

            // If this is a NEW message without translation yet (source unknown or source != UI),
            // don't show anything - wait for translation to become available
            final isAbsoluteLastMessage = lastMessageId != null &&
                lastMessageId == chat.lastMessageId;

            if (isNewMessage &&
                !hasTranslatedPreviewAfterServerCheck &&
                (detectedSourceLang == null || detectedSourceLang != uiLang)) {
              if (isAbsoluteLastMessage &&
                  matchIdForCaseCheck.isNotEmpty &&
                  lastMessageId.isNotEmpty) {
                unawaited(
                  _triggerImmediateLastMessageTranslation(
                    ref: ref,
                    userId: userId,
                    matchId: matchIdForCaseCheck,
                    messageId: lastMessageId,
                    targetLanguage: uiLang,
                  ),
                );
              }
              // This is a new incoming message in a different language - don't update preview yet
              // If we have a previous chat, return it to keep showing old preview
              if (previousChat != null) {
                return previousChat;
              }
              // If no previous chat exists (new chat entirely), return empty message
              return null;
            }

            if (isCaseBAfterServerCheck) {
              return chat.copyWith(lastMessageSourceLanguage: detectedSourceLang);
            }

            if (hasTranslatedPreviewAfterServerCheck && (isCaseCAfterServerCheck || !isCaseBAfterServerCheck)) {
              return chat.copyWith(
                lastMessage: translatedPreview,
                lastMessageTranslated: translatedPreview,
                lastMessageSourceLanguage: detectedSourceLang,
              );
            }

            // If we have source language info, include it in the chat model
            if (detectedSourceLang != null) {
              return chat.copyWith(lastMessageSourceLanguage: detectedSourceLang);
            }

            return chat;
          }

              return chat;
            } catch (e) {
              final matchId = json['match_id']?.toString() ?? 'unknown_match';
              debugPrint('Recent chats item processing failed for $matchId: $e');
              return null;
            }
          })
          .toList());

      final visibleChats = chats
          .whereType<ChatModel>()
          .where((chat) => chat.otherUserId != userId)
          .toList()
        ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
      for (final chat in visibleChats) {
        _recentChatSnapshots['$userId|${chat.matchId}'] = chat;
      }
      return visibleChats;
    } catch (e, st) {
      debugPrint('Recent chats stream mapping failed for user $userId: $e\n$st');
      return <ChatModel>[];
    }
  });
});

// Dashboard stats provider - cached stats with real-time updates
final dashboardStatsProvider = StreamProvider<Map<String, int>>((ref) {
  final userId = supabase.auth.currentUser?.id;
  debugPrint('Dashboard stats provider initialized for user: $userId');

  if (userId == null) {
    debugPrint('Dashboard stats provider: No user ID, returning empty stream');
    return Stream.value({'nearby': 0, 'online': 0});
  }

  final controller = StreamController<Map<String, int>>();
  final localDb = ref.read(localDbProvider);
  Timer? periodicRefreshTimer;

  // Function to fetch current stats (with caching support)
  Future<Map<String, int>> fetchStats({bool useCache = true, bool saveToCache = true}) async {
    // Validate auth session before making API calls to prevent 401 errors on login screen
    final session = supabase.auth.currentSession;
    if (session == null) {
      debugPrint('fetchStats: No valid auth session, returning empty stats');
      return {'nearby': 0, 'online': 0};
    }

    // Verify token is not expired
    if (session.expiresAt != null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (session.expiresAt! < now) {
        debugPrint('fetchStats: Token expired, returning empty stats');
        return {'nearby': 0, 'online': 0};
      }
    }

    try {
      // Try cached stats first if allowed
      if (useCache) {
        final cachedStats = await localDb.getDashboardStats();
        if (cachedStats != null) {
          if (kIsWeb) {
          }
          return cachedStats;
        }
      }

      // Fetch fresh stats from server
      if (kIsWeb) {
      }

      // Get the user's radius setting from the users table
      int userRadiusKm = 50; // Default fallback
      try {
        final userResponse = await supabase
            .from('users')
            .select('match_radius_default')
            .eq('id', userId)
            .single();
        userRadiusKm = (userResponse['match_radius_default'] as int?) ?? 50;
      } catch (e) {
        debugPrint('Could not fetch user radius, using default: $e');
      }

      final onlineResponse = await supabase.rpc('get_online_users_count', params: {'p_user_id': userId});
      final nearbyResponse = await supabase.rpc('get_nearby_users_count', params: {'p_user_id': userId, 'p_radius_km': userRadiusKm});

      final onlineCount = (onlineResponse as int?) ?? 0;
      final nearbyCount = (nearbyResponse as int?) ?? 0;

      final freshStats = {'nearby': nearbyCount, 'online': onlineCount};

      debugPrint('Dashboard stats fetched: online=$onlineCount, nearby=$nearbyCount (radius=$userRadiusKm km)');

      // Cache the fresh stats if requested
      if (saveToCache) {
        await localDb.saveDashboardStats(onlineCount, nearbyCount);
      }

      return freshStats;
    } catch (e) {
      debugPrint('Error fetching dashboard stats: $e');

      // Try to return cached stats as fallback, even if expired
      try {
        final cachedStats = await localDb.getDashboardStats();
        if (cachedStats != null) {
          debugPrint('Dashboard stats: Using expired cache as fallback');
          return cachedStats;
        }
      } catch (cacheError) {
        debugPrint('Dashboard stats: Cache fallback also failed: $cacheError');
      }

      // Ultimate fallback
      return {'nearby': 0, 'online': 0};
    }
  }

  // Emit initial stats (cache if available, then always refresh from server)
  (() async {
    try {
      final cachedStats = await localDb.getDashboardStats();
      if (cachedStats != null) {
        controller.add(cachedStats);
      }
    } catch (_) {
      // ignore cache errors
    }

    try {
      final fresh = await fetchStats(useCache: false, saveToCache: true);
      controller.add(fresh);
    } catch (_) {
      // ignore initial refresh errors
    }
  })();

  // Set up real-time subscriptions using Presence channel for immediate updates
  // The user_activity table has RLS that prevents seeing other users' changes,
  // so we use Presence channel with join/leave events instead.
  
  // Presence channel: subscribe to global presence events for immediate
  // notifications when other clients connect/disconnect (fast online/offline updates)
  final presenceChannel = supabase.channel('presence:online',
    opts: const RealtimeChannelConfig(
      self: true, // Receive our own presence events
    ),
  );

  presenceChannel.onPresenceJoin((payload) {
    debugPrint('Presence join detected: ${payload.newPresences.length} users joined');
    // Refresh stats whenever a user joins presence
    // The stats will be recalculated from the database
    // Ignore if provider disposed or no valid session
    if (!ref.mounted) return;
    if (supabase.auth.currentSession == null) {
      debugPrint('fetchStats skipped in onPresenceJoin: No valid session');
      return;
    }
    fetchStats(useCache: false, saveToCache: false).then((stats) {
      try {
        controller.add(stats);
      } catch (e) {
        // guard against closed controller
      }
    });
  });

  presenceChannel.onPresenceLeave((payload) {
    debugPrint('Presence leave detected: ${payload.leftPresences.length} users left');
    // Refresh stats whenever a user leaves presence
    // The stats will be recalculated from the database
    // Ignore if provider disposed or no valid session
    if (!ref.mounted) return;
    if (supabase.auth.currentSession == null) {
      debugPrint('fetchStats skipped in onPresenceLeave: No valid session');
      return;
    }
    fetchStats(useCache: false, saveToCache: false).then((stats) {
      try {
        controller.add(stats);
      } catch (e) {
        // guard against closed controller
      }
    });
  });

  presenceChannel.onPresenceSync((payload) {
    debugPrint('Presence sync detected for dashboard stats');
    // Ignore if provider disposed or no valid session
    if (!ref.mounted) return;
    if (supabase.auth.currentSession == null) {
      debugPrint('fetchStats skipped in onPresenceSync: No valid session');
      return;
    }
    fetchStats(useCache: false, saveToCache: false).then((stats) {
      try {
        controller.add(stats);
      } catch (e) {
        // guard against closed controller
      }
    });
  });

  presenceChannel.subscribe((status, [err]) {
    if (!ref.mounted) return;
    debugPrint('Presence channel status: $status, error: $err');
    if (status == RealtimeSubscribeStatus.subscribed) {
      // Track a simple presence meta for this user so other clients see us as connected
      try {
        final meta = {
          'online': true,
          'ts': DateTime.now().toUtc().toIso8601String(),
          'user_id': userId,
        };
        presenceChannel.track(meta);
      } catch (e) {
        // ignore track errors
      }
    }
  });

  // Subscribe to users table for visibility setting changes
  // This works because users table RLS allows reading all users
  final visibilityChannel = supabase
      .channel('dashboard_stats_visibility_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        callback: (payload) {
          final newRecord = payload.newRecord as Map<String, dynamic>?;
          final oldRecord = payload.oldRecord as Map<String, dynamic>?;
          final changedUserId = (newRecord?['id'] ?? oldRecord?['id']) as String?;

          if (changedUserId == null || changedUserId == userId) return;

          final bool visibilityFieldPresent =
              (newRecord?.containsKey('user_visibility_setting') ?? false) ||
              (oldRecord?.containsKey('user_visibility_setting') ?? false);
          if (!visibilityFieldPresent) return;

          final newVisible = newRecord?['user_visibility_setting'] as bool?;
          final oldVisible = oldRecord?['user_visibility_setting'] as bool?;
          final bool shouldRefetch = oldRecord == null || newVisible != oldVisible;
          if (!shouldRefetch) return;

          debugPrint('Another user visibility setting changed');
          if (!ref.mounted) return;
          if (supabase.auth.currentSession == null) {
            debugPrint('fetchStats skipped in visibility callback: No valid session');
            return;
          }
          fetchStats(useCache: false, saveToCache: false).then((stats) {
            try {
              controller.add(stats);
            } catch (e) {
              // ignore closed controller
            }
          });
        },
      )
      .subscribe((status, err) {
        debugPrint('Visibility channel status: $status, error: $err');
      });

  // Subscribe to user_locations table for location changes that affect nearby count
  final locationChannel = supabase
      .channel('dashboard_stats_location_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'user_locations',
        callback: (payload) {
          final newRecord = payload.newRecord as Map<String, dynamic>?;
          final oldRecord = payload.oldRecord as Map<String, dynamic>?;
          final changedUserId = (newRecord?['user_id'] ?? oldRecord?['user_id']) as String?;

          if (changedUserId == null || changedUserId == userId) return;

          debugPrint('Another user location changed - refreshing nearby count');
          if (!ref.mounted) return;
          if (supabase.auth.currentSession == null) {
            debugPrint('fetchStats skipped in location callback: No valid session');
            return;
          }
          fetchStats(useCache: false, saveToCache: false).then((stats) {
            try {
              controller.add(stats);
            } catch (e) {
              // ignore closed controller
            }
          });
        },
      )
      .subscribe((status, err) {
        debugPrint('Location channel status: $status, error: $err');
      });

  if (kIsWeb) {
    periodicRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!ref.mounted || controller.isClosed) return;
      if (supabase.auth.currentSession == null) {
        debugPrint('fetchStats skipped in periodic timer: No valid session');
        return;
      }
      fetchStats(useCache: false, saveToCache: false).then((stats) {
        try {
          controller.add(stats);
        } catch (_) {
          // ignore closed controller
        }
      });
    });
  }

  // Set up periodic cache refresh (every 5 minutes) to ensure cached data stays fresh
  final cacheRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
    if (!controller.isClosed && ref.mounted) {
      // Skip if no valid session
      if (supabase.auth.currentSession == null) {
        debugPrint('fetchStats skipped in cache refresh timer: No valid session');
        return;
      }
      // Refresh cache with fresh data from server
      fetchStats(useCache: false, saveToCache: true).then((stats) {
        try {
          // Don't emit here - just update cache
          if (kIsWeb) {
          }
        } catch (e) {
          // ignore
        }
      });
    }
  });

  ref.onDispose(() {
    supabase.removeChannel(locationChannel);
    supabase.removeChannel(visibilityChannel);
    supabase.removeChannel(presenceChannel);
    periodicRefreshTimer?.cancel();
    cacheRefreshTimer.cancel();
    controller.close();
  });

  return controller.stream;
});

// Total unread chat count provider
final totalUnreadChatCountProvider = Provider<int>((ref) {
  final userId = supabase.auth.currentUser?.id ?? '';
  final chatsAsync = ref.watch(recentChatsProvider(userId));
  final chats = chatsAsync.asData?.value ?? [];

  // Count the number of chats with unread messages (not total unread messages)
  final chatsWithUnread = chats.where((chat) => chat.unreadCount > 0).toList();
  final totalUnreadCount = chatsWithUnread.length;

  if (kIsWeb) {
    // Web-specific logic for unread count
    debugPrint('🔍 [WEB] totalUnreadChatCountProvider: Found ${chatsWithUnread.length} chats with unread messages out of ${chats.length} total chats');
  } else {
    debugPrint('📱 totalUnreadChatCountProvider: Found ${chatsWithUnread.length} chats with unread messages out of ${chats.length} total chats');
  }

  return totalUnreadCount;
});

// Navigation index notifier
class NavigationIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) {
    state = index;
  }
}

// Navigation index provider
final navigationIndexProvider = NotifierProvider<NavigationIndexNotifier, int>(() {
  return NavigationIndexNotifier();
});

// Activity update provider - updates user activity when accessed
final activityUpdateProvider = Provider.autoDispose<void>((ref) {
  final user = supabase.auth.currentUser;
  if (user != null) {
    // Update activity asynchronously but don't wait for it
    supabase.rpc('update_user_activity', params: {'p_user_id': user.id}).catchError((e) {
      debugPrint('Error updating user activity: $e');
      return null;
    });
  }
});

// Potential matches provider - fetches users that could be matches
final potentialMatchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final user = supabase.auth.currentUser;
  if (user == null) return [];

  try {
    // Get current user's location and settings
    final userResponse = await supabase
        .from('users')
        .select('match_radius_default')
        .eq('id', user.id)
        .single();

    final matchRadius = userResponse['match_radius_default'] as int? ?? 50; // default 50km

    // Get current user's location
    final locationResponse = await supabase
        .from('user_locations')
        .select('latitude, longitude')
        .eq('user_id', user.id)
        .order('updated_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (locationResponse == null) return [];

    final userLat = locationResponse['latitude'] as double;
    final userLng = locationResponse['longitude'] as double;

    // Get existing matches to exclude
    final existingMatches = await supabase
        .from('matches')
        .select('user1_id, user2_id')
        .or('user1_id.eq.${user.id},user2_id.eq.${user.id}');

    final matchedUserIds = <String>{};
    for (final match in existingMatches) {
      if (match['user1_id'] != user.id) matchedUserIds.add(match['user1_id']);
      if (match['user2_id'] != user.id) matchedUserIds.add(match['user2_id']);
    }

    // Query potential matches
    final potentialUsers = await supabase
        .from('users')
        .select('''
          id,
          display_name,
          profile_data,
          user_locations!inner(latitude, longitude)
        ''')
        .eq('user_visibility_setting', true)
        .neq('id', user.id)
        .not('id', 'in', '(${matchedUserIds.join(',')})')
        .filter('user_locations.latitude', 'not.is', null)
        .filter('user_locations.longitude', 'not.is', null);

    // Filter by distance
    final potentialMatches = <Map<String, dynamic>>[];
    for (final userData in potentialUsers) {
      final locations = userData['user_locations'] as List<dynamic>;
      if (locations.isNotEmpty) {
        final location = locations.first;
        final lat = location['latitude'] as double?;
        final lng = location['longitude'] as double?;
        if (lat != null && lng != null) {
          final distance = _calculateDistance(userLat, userLng, lat, lng);
          if (distance <= matchRadius) {
            potentialMatches.add({
              ...userData,
              'distance': distance,
              'location': location,
            });
          }
        }
      }
    }

    // Sort by distance
    potentialMatches.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    return potentialMatches;
  } catch (e) {
    debugPrint('Error fetching potential matches: $e');
    return [];
  }
});

// Helper function to calculate distance between two points
double _calculateDistance(double lat1, double lng1, double lat2, double lng2) {
  const double earthRadius = 6371; // km
  final double dLat = _degreesToRadians(lat2 - lat1);
  final double dLng = _degreesToRadians(lng2 - lng1);
  final double a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_degreesToRadians(lat1)) * cos(_degreesToRadians(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadius * c;
}

double _degreesToRadians(double degrees) => degrees * (3.141592653589793 / 180);

// --- userChatIdsProvider ---
// Returns a set of match IDs that have chats for the given user
final userChatIdsProvider = StreamProvider.autoDispose.family<Set<String>, String>((ref, userId) {
  if (userId.isEmpty) {
    return Stream.value(<String>{});
  }

  final localDb = ref.watch(localDbProvider);
  final localStream = localDb.watchChats(userId);

  return localStream.map((chats) {
    return chats
        .map((chat) => chat['match_id'] as String?)
        .whereType<String>()
        .toSet();
  });
});

// --- matchExpiryNowProvider ---
// Provides the current DateTime for calculating match expiry countdown
// Updates every second to keep countdown timers accurate
final matchExpiryNowProvider = StreamProvider<DateTime>((ref) {
  final controller = StreamController<DateTime>();
  
  // Emit current time immediately
  controller.add(DateTime.now());
  
  // Update every second
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (!controller.isClosed) {
      controller.add(DateTime.now());
    }
  });
  
  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });
  
  return controller.stream;
});

final matchChatStartExpiryWarningProvider = NotifierProvider<MatchChatStartExpiryWarningNotifier, Object?>(() {
  return MatchChatStartExpiryWarningNotifier();
});

class MatchChatStartExpiryWarningNotifier extends Notifier<Object?> {
  List<MatchModel> _matches = const [];
  Set<String> _chatIds = const <String>{};
  LocalizationState? _l10n;
  DateTime? _now;

  bool _checkScheduled = false;
  bool _checkInProgress = false;

  List<Duration> _warningThresholds = const [Duration(minutes: 60)];
  DateTime? _warningThresholdsFetchedAt;

  final Set<String> _notifiedThisSession = <String>{};
  final Set<String> _checkInFlightMatchIds = <String>{};

  @override
  Object? build() {
    final userId = supabase.auth.currentUser?.id ?? '';
    if (userId.isEmpty) return null;

    ref.listen<AsyncValue<List<MatchModel>>>(recentMatchesProvider(userId), (previous, next) {
      _matches = next.asData?.value ?? const [];
      _scheduleCheck();
    });

    ref.listen<AsyncValue<Set<String>>>(userChatIdsProvider(userId), (previous, next) {
      _chatIds = next.asData?.value ?? const <String>{};
      _scheduleCheck();
    });

    ref.listen<LocalizationState>(localizationProvider, (previous, next) {
      _l10n = next;
      _scheduleCheck();
    });

    ref.listen<AsyncValue<DateTime>>(matchExpiryNowProvider, (previous, next) {
      final v = next.asData?.value;
      if (v != null) {
        _now = v;
        _scheduleCheck();
      }
    });

    Future.microtask(_scheduleCheck);

    return null;
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    Future.microtask(() async {
      _checkScheduled = false;
      await _checkForWarnings();
    });
  }

  Future<List<Duration>> _getWarningThresholds(DateTime now) async {
    final last = _warningThresholdsFetchedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return _warningThresholds;
    }

    _warningThresholdsFetchedAt = now;
    final configured = await appConfigService.getDurationList(
      'matches.chat_start_expiry_warning_seconds',
      defaultValue: const [Duration(minutes: 60)],
    );

    final cleaned = configured.where((d) => d > Duration.zero).toSet().toList()
      ..sort((a, b) => a.inSeconds.compareTo(b.inSeconds));
    _warningThresholds = cleaned.isEmpty ? const [Duration(minutes: 60)] : cleaned;
    return _warningThresholds;
  }

  Future<String?> _getCachedOtherUserName(
    LocalDbService localDb,
    String otherUserId,
  ) async {
    if (otherUserId.trim().isEmpty) return null;
    try {
      final cached = await localDb.getOtherUserProfile(otherUserId);
      if (cached == null) return null;
      final raw =
          (cached['name'] ?? cached['display_name'] ?? cached['displayName'] ?? '').toString();
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return formatSenderNameForNotification(trimmed);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveOtherUserName(
    LocalDbService localDb,
    String otherUserId,
  ) async {
    final cached = await _getCachedOtherUserName(localDb, otherUserId);
    if (cached != null && cached.trim().isNotEmpty) return cached;

    try {
      final profile = await ref.read(otherUserProfileProvider(otherUserId).future);
      final raw = profile?.name.toString() ?? '';
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return formatSenderNameForNotification(trimmed);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkForWarnings() async {
    if (_checkInProgress) return;
    _checkInProgress = true;

    try {
      final l10n = _l10n;
      if (l10n == null) return;

      final userId = supabase.auth.currentUser?.id ?? '';
      if (userId.isEmpty) return;

      final matches = _matches;
      if (matches.isEmpty) return;

      final now = _now ?? DateTime.now();
      final thresholds = await _getWarningThresholds(now);
      final startThreshold = thresholds.isEmpty ? const Duration(minutes: 60) : thresholds.last;

      final localDb = ref.read(localDbProvider);
      final prefs = await SharedPreferences.getInstance();

      for (final match in matches) {
        final matchId = match.id.trim();
        if (matchId.isEmpty) continue;

        if (_chatIds.contains(matchId)) continue;

        final window = Duration(
          seconds: match.chatStartWindowSeconds ?? const Duration(hours: 24).inSeconds,
        );
        final remaining = match.createdAt.toUtc().add(window).difference(now.toUtc());
        if (remaining <= Duration.zero) continue;
        if (remaining > startThreshold) continue;

        Duration? thresholdToSend;
        for (final t in thresholds) {
          if (remaining <= t) {
            thresholdToSend = t;
            break;
          }
        }
        if (thresholdToSend == null) continue;

        const templateVersion = 'match_expiry_minutes_v1';
        final sessionKey = '$matchId:${thresholdToSend.inSeconds}:$templateVersion';
        if (_notifiedThisSession.contains(sessionKey)) continue;
        if (_checkInFlightMatchIds.contains(matchId)) continue;
        _checkInFlightMatchIds.add(matchId);

        try {
          final prefsKey =
              'match_chat_start_expiry_warned_${matchId}_${thresholdToSend.inSeconds}_$templateVersion';
          final alreadyNotified = prefs.getBool(prefsKey) ?? false;
          if (alreadyNotified) {
            _notifiedThisSession.add(sessionKey);
            continue;
          }

          await prefs.setBool(prefsKey, true);
          _notifiedThisSession.add(sessionKey);

          final otherName = await _resolveOtherUserName(localDb, match.otherUserId);
          final minutesLeft = max(1, (remaining.inSeconds / 60).ceil());
          final otherUserName = (otherName == null || otherName.trim().isEmpty)
              ? l10n.getString('generalUnknown')
              : otherName;

          final title = l10n.getString(
            'matchExpiryTitle',
            params: {'count': minutesLeft.toString()},
          );
          final body = l10n.getString(
            'matchExpiryBody',
            params: {'count': minutesLeft.toString(), 'otherUserName': otherUserName},
          );

          if (kIsWeb) {
            await WebNotificationService.showMatchNotification(
              matchId: matchId,
              matchName: otherUserName,
              matchPhotoUrl: '',
            );
          } else {
            await MobileLocalNotificationService.showMatchExpiryNotification(
              matchId: matchId,
              title: title,
              body: body,
              notificationKey: 'chat_start_expiry_${thresholdToSend.inSeconds}_$templateVersion',
            );
          }
        } catch (_) {
        } finally {
          _checkInFlightMatchIds.remove(matchId);
        }
      }
    } finally {
      _checkInProgress = false;
    }
  }
}
