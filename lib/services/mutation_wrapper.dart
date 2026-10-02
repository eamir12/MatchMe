import 'package:matchme/services/offline_mutation_queue.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/approval_required_fields.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Wrapper for mutations that handles offline queueing and optimistic updates
class MutationWrapper {
  /// Queue a mutation for later sync
  static Future<void> queueMutation({
    required String type, // 'insert', 'update', 'delete'
    required String table,
    required Map<String, dynamic> payload,
    Map<String, dynamic>? where,
  }) async {
    await OfflineMutationQueue.instance.queueMutation(
      type: type,
      table: table,
      payload: payload,
      where: where,
    );
  }

  /// Execute a mutation online, or queue it offline
  /// Returns true if executed online, false if queued offline
  static Future<bool> executeMutation({
    required String type, // 'insert', 'update', 'delete'
    required String table,
    required Map<String, dynamic> payload,
    Map<String, dynamic>? where,
    required Future<void> Function(SupabaseClient supabase) onlineExecution,
  }) async {
    final offlineCacheManager = OfflineCacheManager.instance;
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;

    // Check if we should use cached data (offline or unreliable connection)
    bool shouldQueueOffline = offlineCacheManager.shouldUseCachedData();

    // Also check if session is expired - if so, we must queue offline until bootstrap refreshes it
    if (!shouldQueueOffline && session != null && session.expiresAt != null) {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      if (session.expiresAt! <= now) {
        print('[MutationWrapper] Session expired, queuing offline: $table');
        shouldQueueOffline = true;
      }
    }

    if (shouldQueueOffline) {
      // Queue the mutation for later
      await queueMutation(
        type: type,
        table: table,
        payload: payload,
        where: where,
      );
      print('[MutationWrapper] Queued offline mutation: $type on $table');
      return false; // Queued offline
    }

    try {
      // Try to execute online
      await onlineExecution(supabase);
      print('[MutationWrapper] ✅ Executed mutation: $type on $table');
      return true; // Executed online
    } catch (e) {
      // If it fails, queue it
      print('[MutationWrapper] Failed to execute online, queuing: $e');
      await queueMutation(
        type: type,
        table: table,
        payload: payload,
        where: where,
      );
      return false; // Queued offline
    }
  }

  /// Send a message (with offline queueing)
  /// NOTE: This method is unused — the real send path goes through
  /// ChatService.sendMessage in chat_provider.dart which handles encryption.
  static Future<bool> sendMessage({
    required String matchId,
    required String senderId,
    required String text,
    String? replyToMessageId,
  }) async {
    throw UnimplementedError(
      'MutationWrapper.sendMessage is deprecated. Use ChatService.sendMessage which handles encryption.',
    );
  }

  /// Check if profile updates contain approval-required fields while offline
  /// Returns list of approval-required fields found in the updates
  static List<String> getApprovalRequiredFieldsInUpdates(
    Map<String, dynamic> updates,
  ) {
    return updates.keys
        .where((field) => ApprovalRequiredFields.requiresApproval(field))
        .toList();
  }

  /// Check if we can update profile with these changes
  /// Returns: (canUpdate: bool, blockedFields: List[String])
  /// If canUpdate is false, blockedFields contains fields that need approval
  static (bool canUpdate, List<String> blockedFields) canUpdateProfile(
    Map<String, dynamic> updates,
  ) {
    final offlineCacheManager = OfflineCacheManager.instance;

    // If we have a stable connection, allow all updates
    if (!offlineCacheManager.shouldUseCachedData()) {
      return (true, []);
    }

    // Get approval-required fields in this update
    final blockedFields = getApprovalRequiredFieldsInUpdates(updates);

    // If any approval-required fields are present, block the update
    if (blockedFields.isNotEmpty) {
      print(
        '[MutationWrapper] ⛔ Cannot update offline - approval-required fields: $blockedFields',
      );
      return (false, blockedFields);
    }

    return (true, []);
  }

  /// Update user profile field
  static Future<bool> updateProfile({
    required String userId,
    required Map<String, dynamic> updates,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'users',
      payload: updates,
      where: {'id': userId},
      onlineExecution: (supabase) async {
        await supabase.from('users').update(updates).eq('id', userId);
      },
    );
  }

  /// Update visibility status
  static Future<bool> updateVisibilityStatus({
    required String userId,
    required String status, // 'visible' or 'invisible'
  }) async {
    return executeMutation(
      type: 'update',
      table: 'users',
      payload: {'user_visibility_setting': status},
      where: {'id': userId},
      onlineExecution: (supabase) async {
        await supabase
            .from('users')
            .update({'user_visibility_setting': status})
            .eq('id', userId);
      },
    );
  }

  /// Mark chat as read
  static Future<bool> markChatAsRead({
    required String matchId,
    required String userId,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'chat_rooms',
      payload: {'last_read_by_$userId': DateTime.now().toIso8601String()},
      where: {'id': matchId},
      onlineExecution: (supabase) async {
        await supabase
            .from('chat_rooms')
            .update({'last_read_by_$userId': DateTime.now().toIso8601String()})
            .eq('id', matchId);
      },
    );
  }

  /// React to a message
  static Future<bool> reactToMessage({
    required String messageId,
    required String userId,
    required String emoji,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'message_reactions',
      payload: {'message_id': messageId, 'user_id': userId, 'emoji': emoji},
      onlineExecution: (supabase) async {
        await supabase.from('message_reactions').insert({
          'message_id': messageId,
          'user_id': userId,
          'emoji': emoji,
        });
      },
    );
  }

  /// Delete a message
  static Future<bool> deleteMessage({required String messageId}) async {
    return executeMutation(
      type: 'delete',
      table: 'chat_messages',
      payload: const {},
      where: {'id': messageId},
      onlineExecution: (supabase) async {
        await supabase.from('chat_messages').delete().eq('id', messageId);
      },
    );
  }

  /// Edit a message. All edits must be encrypted — plaintext is never allowed.
  static Future<bool> editMessage({
    required String messageId,
    required String newContent,
    required String encryptionScheme,
    required String contentOriginalNonce,
    required Map<String, dynamic> wrappedKeys,
    required String senderKeyId,
    required String recipientKeyId,
    required String recipientId,
  }) async {
    final payload = <String, dynamic>{
      'content_original_encrypted': newContent,
      'encryption_scheme': encryptionScheme,
      'content_original_nonce': contentOriginalNonce,
      'wrapped_keys': wrappedKeys,
      'sender_key_id': senderKeyId,
      'recipient_key_id': recipientKeyId,
      'recipient_id': recipientId,
      'edited_at': DateTime.now().toIso8601String(),
    };
    return executeMutation(
      type: 'update',
      table: 'chat_messages',
      payload: payload,
      where: {'id': messageId},
      onlineExecution: (supabase) async {
        await supabase
            .from('chat_messages')
            .update(payload)
            .eq('id', messageId);
      },
    );
  }

  /// Delete a reaction from a message
  static Future<bool> deleteReaction({required String reactionId}) async {
    return executeMutation(
      type: 'delete',
      table: 'message_reactions',
      payload: {'id': reactionId},
      where: {'id': reactionId},
      onlineExecution: (supabase) async {
        await supabase.from('message_reactions').delete().eq('id', reactionId);
      },
    );
  }

  /// Create an event
  static Future<bool> createEvent({
    required String createdBy,
    required String title,
    required String? description,
    required DateTime eventDateTime,
    required String? location,
    required double? latitude,
    required double? longitude,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'events',
      payload: {
        'created_by': createdBy,
        'title': title,
        'description': description,
        'event_datetime': eventDateTime.toIso8601String(),
        'location': location,
        'latitude': latitude,
        'longitude': longitude,
      },
      onlineExecution: (supabase) async {
        await supabase.from('events').insert({
          'created_by': createdBy,
          'title': title,
          'description': description,
          'event_datetime': eventDateTime.toIso8601String(),
          'location': location,
          'latitude': latitude,
          'longitude': longitude,
        });
      },
    );
  }

  /// Update an event
  static Future<bool> updateEvent({
    required String eventId,
    required Map<String, dynamic> updates,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'events',
      payload: updates,
      where: {'id': eventId},
      onlineExecution: (supabase) async {
        await supabase.from('events').update(updates).eq('id', eventId);
      },
    );
  }

  /// Delete an event
  static Future<bool> deleteEvent({required String eventId}) async {
    return executeMutation(
      type: 'delete',
      table: 'events',
      payload: {'id': eventId},
      where: {'id': eventId},
      onlineExecution: (supabase) async {
        await supabase.from('events').delete().eq('id', eventId);
      },
    );
  }

  /// Join an event
  static Future<bool> joinEvent({
    required String eventId,
    required String userId,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'event_participants',
      payload: {
        'event_id': eventId,
        'user_id': userId,
        'joined_at': DateTime.now().toIso8601String(),
      },
      onlineExecution: (supabase) async {
        await supabase.from('event_participants').insert({
          'event_id': eventId,
          'user_id': userId,
          'joined_at': DateTime.now().toIso8601String(),
        });
      },
    );
  }

  /// Leave an event
  static Future<bool> leaveEvent({
    required String eventId,
    required String userId,
  }) async {
    return executeMutation(
      type: 'delete',
      table: 'event_participants',
      payload: {},
      where: {'event_id': eventId, 'user_id': userId},
      onlineExecution: (supabase) async {
        await supabase.from('event_participants').delete().match({
          'event_id': eventId,
          'user_id': userId,
        });
      },
    );
  }

  /// Update user location
  static Future<bool> updateLocation({
    required String userId,
    required double latitude,
    required double longitude,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'user_locations',
      payload: {
        'latitude': latitude,
        'longitude': longitude,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: {'user_id': userId},
      onlineExecution: (supabase) async {
        await supabase
            .from('user_locations')
            .update({
              'latitude': latitude,
              'longitude': longitude,
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('user_id', userId);
      },
    );
  }

  /// Add an invisibility rule
  static Future<bool> addInvisibilityRule({
    required String userId,
    required String targetUserId,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'invisibility_rules',
      payload: {'user_id': userId, 'target_user_id': targetUserId},
      onlineExecution: (supabase) async {
        await supabase.from('invisibility_rules').insert({
          'user_id': userId,
          'target_user_id': targetUserId,
        });
      },
    );
  }

  /// Remove an invisibility rule
  static Future<bool> removeInvisibilityRule({
    required String userId,
    required String targetUserId,
  }) async {
    return executeMutation(
      type: 'delete',
      table: 'invisibility_rules',
      payload: {},
      where: {'user_id': userId, 'target_user_id': targetUserId},
      onlineExecution: (supabase) async {
        await supabase.from('invisibility_rules').delete().match({
          'user_id': userId,
          'target_user_id': targetUserId,
        });
      },
    );
  }

  /// Toggle shared event matching preference
  static Future<bool> toggleSharedEventMatching({
    required String userId,
    required bool enabled,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'users',
      payload: {'shared_event_matching_enabled': enabled},
      where: {'id': userId},
      onlineExecution: (supabase) async {
        await supabase
            .from('users')
            .update({'shared_event_matching_enabled': enabled})
            .eq('id', userId);
      },
    );
  }

  /// Toggle shared movement matching preference
  static Future<bool> toggleSharedMovementMatching({
    required String userId,
    required bool enabled,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'users',
      payload: {'shared_movement_matching_enabled': enabled},
      where: {'id': userId},
      onlineExecution: (supabase) async {
        await supabase
            .from('users')
            .update({'shared_movement_matching_enabled': enabled})
            .eq('id', userId);
      },
    );
  }

  /// Update notification preferences
  static Future<bool> updateNotificationPreferences({
    required String userId,
    required Map<String, dynamic> preferences,
  }) async {
    return executeMutation(
      type: 'update',
      table: 'notification_preferences',
      payload: preferences,
      where: {'user_id': userId},
      onlineExecution: (supabase) async {
        await supabase
            .from('notification_preferences')
            .update(preferences)
            .eq('user_id', userId);
      },
    );
  }

  /// Block a user
  static Future<bool> blockUser({
    required String userId,
    required String targetUserId,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'user_blocks',
      payload: {'user_id': userId, 'blocked_user_id': targetUserId},
      onlineExecution: (supabase) async {
        await supabase.from('user_blocks').insert({
          'user_id': userId,
          'blocked_user_id': targetUserId,
        });
      },
    );
  }

  /// Unblock a user
  static Future<bool> unblockUser({
    required String userId,
    required String targetUserId,
  }) async {
    return executeMutation(
      type: 'delete',
      table: 'user_blocks',
      payload: {},
      where: {'user_id': userId, 'blocked_user_id': targetUserId},
      onlineExecution: (supabase) async {
        await supabase.from('user_blocks').delete().match({
          'user_id': userId,
          'blocked_user_id': targetUserId,
        });
      },
    );
  }

  /// Report a user
  static Future<bool> reportUser({
    required String reportedBy,
    required String reportedUserId,
    required String reason,
    required String? description,
  }) async {
    return executeMutation(
      type: 'insert',
      table: 'user_reports',
      payload: {
        'reported_by': reportedBy,
        'reported_user_id': reportedUserId,
        'reason': reason,
        'description': description,
      },
      onlineExecution: (supabase) async {
        await supabase.from('user_reports').insert({
          'reported_by': reportedBy,
          'reported_user_id': reportedUserId,
          'reason': reason,
          'description': description,
        });
      },
    );
  }
}
