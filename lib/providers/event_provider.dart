// lib/providers/event_provider.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';

part 'event_provider.g.dart';

final supabase = Supabase.instance.client;

/// Pending route used to deep-link into the Event tab from other screens/notifications.
class PendingEventTabRouteNotifier extends Notifier<EventModel?> {
  @override
  EventModel? build() => null;

  void navigateTo(EventModel event) => state = event;

  void clear() => state = null;
}

final pendingEventTabRouteProvider =
    NotifierProvider<PendingEventTabRouteNotifier, EventModel?>(() {
      return PendingEventTabRouteNotifier();
    });

class PendingAddEventShareNotifier extends Notifier<Map<String, dynamic>?> {
  @override
  Map<String, dynamic>? build() => null;

  void setPayload(Map<String, dynamic> payload) => state = payload;

  void clear() => state = null;
}

final pendingAddEventShareProvider =
    NotifierProvider<PendingAddEventShareNotifier, Map<String, dynamic>?>(() {
      return PendingAddEventShareNotifier();
    });

// --- Event Management Notifier ---
@riverpod
class EventManager extends _$EventManager {
  // UI toggle stored in the notifier - defaults to hiding past events
  bool _showPastEvents = false;

  bool get showPastEvents => _showPastEvents;

  List<EventModel> _filterVisibleEvents(List<EventModel> events) {
    if (_showPastEvents) {
      return events;
    }

    final now = DateTime.now();
    return events.where((event) => !event.endTime.isBefore(now)).toList();
  }

  Future<List<EventModel>?> _loadCachedVisibleEvents(
    String userId,
    LocalDbService localDb,
  ) async {
    final cachedEvents = await localDb.getCachedUserEvents(userId);
    if (cachedEvents == null) {
      return null;
    }

    final allEvents = <EventModel>[];
    for (final eventData in cachedEvents) {
      allEvents.add(EventModel.fromJson(eventData));
    }
    return _filterVisibleEvents(allEvents);
  }

  /// Update the toggle and persist for the current user if available
  void setShowPastEvents(bool v) async {
    _showPastEvents = v;
    final userId = supabase.auth.currentUser?.id;
    if (userId != null && userId.isNotEmpty) {
      try {
        final localDb = await LocalDbService.instance;
        await localDb.saveShowPastEvents(userId, v);
      } catch (_) {}
    }
  }

  @override
  AsyncValue<List<EventModel>> build() {
    // Initialize user preference and events after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Check if provider is still mounted before proceeding
      if (!ref.mounted) return;

      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          final localDb = await LocalDbService.instance;
          _showPastEvents = await localDb.loadShowPastEvents(userId);
        } catch (_) {}
      }

      // Check again before fetching events
      if (ref.mounted) {
        await fetchUserEvents();
      }
    });

    return const AsyncValue.loading();
  }

  Future<void> fetchUserEvents({bool forceRemote = false}) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      if (ref.mounted) {
        state = const AsyncValue.data([]);
      }
      return;
    }

    final localDb = ref.read(localDbProvider);

    if (offlineCacheManager.shouldUseCachedData()) {
      final cachedVisibleEvents = await _loadCachedVisibleEvents(
        userId,
        localDb,
      );
      if (!ref.mounted) return;
      state = AsyncValue.data(cachedVisibleEvents ?? const <EventModel>[]);
      return;
    }

    if (forceRemote) {
      await _fetchEventsFromServer(userId, localDb);
      return;
    }

    final cachedEvents = await localDb.getCachedUserEvents(userId);

    // Check if provider is still mounted after async operation
    if (!ref.mounted) return;

    if (cachedEvents != null) {
      final allEvents = <EventModel>[];
      for (final eventData in cachedEvents) {
        allEvents.add(EventModel.fromJson(eventData));
      }
      state = AsyncValue.data(_filterVisibleEvents(allEvents));
      _refreshEventsFromServer(userId, localDb);
    } else {
      await _fetchEventsFromServer(userId, localDb);
    }
  }

  Future<void> _refreshEventsFromServer(
    String userId,
    LocalDbService localDb,
  ) async {
    try {
      await _fetchEventsFromServer(userId, localDb, updateState: true);
    } catch (_) {
      // Silently fail background refresh - _fetchEventsFromServer already checks ref.mounted
    }
  }

  Future<void> _fetchEventsFromServer(
    String userId,
    LocalDbService localDb, {
    bool updateState = true,
  }) async {
    try {
      // Query events the current user is attending
      // Join events with event_attendees to get user's personal notes and attendee count
      var query = supabase.from('event_attendees').select('''
            notes,
            events!inner(
              id,
              event_name,
              event_venue,
              start_time,
              end_time,
              event_link,
              external_calendar_id,
              external_event_id,
              external_provider,
              is_all_day,
              description
            )
          ''');

      final includePast = _showPastEvents;
      if (!includePast) {
        // Only include events that have not fully finished (end_time >= now())
        query = query.gte('events.end_time', DateTime.now().toIso8601String());
      }

      final response = await query.eq('user_id', userId);

      // Check if provider is still mounted after async operation
      if (!ref.mounted) return;

      // Transform the response to include attendee count
      final List<Map<String, dynamic>> eventsData = [];
      final List<EventModel> events = [];
      final sortedResponse = (response as List).cast<Map<String, dynamic>>()
        ..sort((a, b) {
          final aEvents = a['events'] as Map<String, dynamic>;
          final bEvents = b['events'] as Map<String, dynamic>;
          final aStartTime = aEvents['start_time'] as String?;
          final bStartTime = bEvents['start_time'] as String?;
          if (aStartTime == null || bStartTime == null) return 0;
          return aStartTime.compareTo(bStartTime);
        });

      for (final row in sortedResponse) {
        final eventData = row['events'] as Map<String, dynamic>;

        int? attendeeCount;
        try {
          final countResponse = await supabase.rpc(
            'count_event_attendees',
            params: {'event_id_param': eventData['id']},
          );

          if (countResponse is num) {
            attendeeCount = countResponse.toInt();
          } else if (countResponse is Map<String, dynamic> &&
              countResponse.containsKey('count')) {
            final countValue = countResponse['count'];
            if (countValue is num) {
              attendeeCount = countValue.toInt();
            } else if (countValue is String) {
              attendeeCount = int.tryParse(countValue);
            }
          }
        } catch (_) {}

        // Check if provider is still mounted after each RPC call
        if (!ref.mounted) return;

        final fullEventData = {
          ...eventData,
          'notes': row['notes'],
          'attendee_count': attendeeCount,
        };

        eventsData.add(fullEventData);
        events.add(EventModel.fromJson(fullEventData));
      }

      // Cache the events data
      await localDb.saveUserEvents(userId, eventsData);

      // Check if provider is still mounted before updating state
      if (!ref.mounted) return;

      if (updateState) {
        state = AsyncValue.data(events);
      }
    } catch (e, s) {
      if (!ref.mounted) return;

      final cachedVisibleEvents = await _loadCachedVisibleEvents(
        userId,
        localDb,
      );
      if (!ref.mounted) return;

      if (cachedVisibleEvents != null) {
        state = AsyncValue.data(cachedVisibleEvents);
      } else if (updateState) {
        state = AsyncValue.error(e, s);
      }
    }
  }

  Future<bool> addEvent(EventModel event) async {
    final result = await addEventWithResult(event);
    return result.success;
  }

  Future<EventSaveResult> addEventWithResult(EventModel event) async {
    var eventLinkedSuccessfully = false;

    if (shouldSkipSupabaseCalls()) {
      return const EventSaveResult(
        success: false,
        errorKey: 'eventAddFailedOffline',
        diagnosticCode: 'offline_supabase_paused',
      );
    }

    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) {
        print(
          '[EVENT_IMPORT] addEventWithResult aborted: no authenticated user',
        );
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedAuth',
          diagnosticCode: 'auth_missing_user',
        );
      }

      print(
        '[EVENT_IMPORT] addEventWithResult start user=$userId title="${event.eventName}" start=${event.startTime.toIso8601String()} venue="${event.eventVenue ?? ''}" provider="${event.externalProvider ?? ''}"',
      );

      final sanitize = await _sanitizeEventForPublicSaveWithReason(
        event,
        requirePublicJoinable: true,
      );
      final safeEvent = sanitize.event;
      if (safeEvent == null) {
        print(
          '[EVENT_IMPORT] addEventWithResult rejected during sanitization title="${event.eventName}" reason=${sanitize.errorKey ?? 'eventAddFailedUnknown'}',
        );
        return EventSaveResult(
          success: false,
          errorKey: sanitize.errorKey ?? 'eventAddFailedUnknown',
          diagnosticCode: sanitize.errorKey,
        );
      }

      final existingEventId = await _findExistingEventIdForImport(safeEvent);

      String eventId;

      if (existingEventId != null) {
        print(
          '[EVENT_IMPORT] addEventWithResult matched existing event eventId=$existingEventId title="${safeEvent.eventName}"',
        );
        // Event exists - just link the user to it
        eventId = existingEventId;

        // Add user as attendee (or ignore if already attending)
        try {
          await supabase.from('event_attendees').insert({
            'event_id': eventId,
            'user_id': userId,
            'notes': safeEvent.notes,
          });
        } catch (e) {
          if (e is PostgrestException && e.code == '23505') {
            // Duplicate key, user already attending
            print(
              '[EVENT_IMPORT] addEventWithResult user already attending eventId=$eventId user=$userId',
            );
            return const EventSaveResult(
              success: true,
              diagnosticCode: 'attendance_duplicate',
            );
          }
          rethrow;
        }
        eventLinkedSuccessfully = true;
        print(
          '[EVENT_IMPORT] addEventWithResult linked attendee to existing event eventId=$eventId user=$userId',
        );
      } else {
        try {
          final newEvent = await supabase
              .from('events')
              .insert(safeEvent.toJsonForSave())
              .select('id')
              .single();

          eventId = newEvent['id'] as String;
          print(
            '[EVENT_IMPORT] addEventWithResult created new event eventId=$eventId title="${safeEvent.eventName}"',
          );
        } catch (e) {
          if (e is PostgrestException && _isUniqueConstraintFailure(e)) {
            print(
              '[EVENT_IMPORT] addEventWithResult create conflicted with existing event, retrying lookup title="${safeEvent.eventName}"',
            );
            final recoveredEventId = await _findExistingEventIdForImport(
              safeEvent,
            );
            if (recoveredEventId == null) {
              rethrow;
            }
            eventId = recoveredEventId;
            print(
              '[EVENT_IMPORT] addEventWithResult recovered existing event after conflict eventId=$eventId title="${safeEvent.eventName}"',
            );
          } else {
            rethrow;
          }
        }

        await supabase.from('event_attendees').insert({
          'event_id': eventId,
          'user_id': userId,
          'notes': safeEvent.notes,
        });
        eventLinkedSuccessfully = true;
        print(
          '[EVENT_IMPORT] addEventWithResult linked creator as attendee eventId=$eventId user=$userId',
        );
      }

      try {
        await fetchUserEvents();
        print(
          '[EVENT_IMPORT] addEventWithResult refreshed event list successfully',
        );
      } catch (e, st) {
        print(
          '[EVENT_IMPORT] addEventWithResult refresh failed after save: $e',
        );
        print('$st');
      }

      try {
        await createEventMatches(
          eventId,
          safeEvent.eventName,
          safeEvent.eventVenue,
          safeEvent.startTime,
        );
        print(
          '[EVENT_IMPORT] addEventWithResult post-save matching step completed for eventId=$eventId',
        );
      } catch (e, st) {
        print(
          '[EVENT_IMPORT] addEventWithResult post-save matching failed for eventId=$eventId: $e',
        );
        print('$st');
      }

      print(
        '[EVENT_IMPORT] addEventWithResult completed successfully eventId=$eventId',
      );
      return const EventSaveResult(success: true, diagnosticCode: 'success');
    } catch (e, st) {
      print(
        '[EVENT_IMPORT] addEventWithResult failed after ${eventLinkedSuccessfully ? 'saving event attendance' : 'before save completed'}: $e',
      );
      print('$st');
      if (e is PostgrestException) {
        print(
          '[EVENT_IMPORT] PostgrestException details code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}',
        );
      }
      return _mapEventSaveFailure(e);
    }
  }

  Future<bool> updateEvent(EventModel event) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return false;

      final safeEvent = await _sanitizeEventForPublicSave(
        event,
        requirePublicJoinable: true,
      );
      if (safeEvent == null) return false;

      // Update the event itself (all attendees will see changes)
      await supabase
          .from('events')
          .update(safeEvent.toJsonForSave())
          .eq('id', safeEvent.id);

      // Update the user's personal notes
      await supabase
          .from('event_attendees')
          .update({'notes': safeEvent.notes})
          .eq('event_id', safeEvent.id)
          .eq('user_id', userId);

      await fetchUserEvents(); // Refresh the list
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> leaveEvent(String eventId) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return false;

      // First, remove any event matches where this user is involved
      await supabase
          .from('matches')
          .delete()
          .eq('event_id', eventId)
          .eq('match_type', 'event')
          .or('user1_id.eq.$userId,user2_id.eq.$userId');

      // Remove user from event attendees
      // The trigger will automatically delete the event if no attendees remain
      await supabase
          .from('event_attendees')
          .delete()
          .eq('event_id', eventId)
          .eq('user_id', userId);

      await fetchUserEvents(); // Refresh the list
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteEvent(String eventId) => leaveEvent(eventId);

  Future<void> createEventMatches(
    String eventId,
    String eventName,
    String? eventVenue,
    DateTime startTime,
  ) async {
    // Event matching is now handled entirely by the backend
    // The database trigger automatically calls perform_event_matching when users join events
    // No frontend logic needed here
  }

  /// Normalizes a venue string to handle variations between vendors
  /// - Converts to lowercase
  /// - Removes common suffixes like address, city, state, zip
  /// - Normalizes common venue words (theater/theatre, center/centre)
  String _normalizeVenue(String? venue) {
    if (venue == null || venue.trim().isEmpty) return '';

    var normalized = venue.toLowerCase().trim();

    // Remove common address components (comma-separated parts after venue name)
    // E.g., "Space Ballroom, 295 Treadwell Street, Hamden, CT 06514" -> "space ballroom"
    final commaIndex = normalized.indexOf(',');
    if (commaIndex > 0) {
      normalized = normalized.substring(0, commaIndex);
    }

    // Normalize common spelling variations
    normalized = normalized
        .replaceAll('theatre', 'theater')
        .replaceAll('centre', 'center')
        .replaceAll('theater', 'thtr')
        .replaceAll('center', 'ctr')
        .replaceAll('hall', 'hl')
        .replaceAll('stadium', 'stdm')
        .replaceAll('arena', 'arn')
        .replaceAll('pavilion', 'pav');

    // Remove common words
    final wordsToRemove = [
      'the',
      'at',
      'in',
      'on',
      'live',
      'music',
      'venue',
      'club',
    ];
    for (final word in wordsToRemove) {
      normalized = normalized.replaceAll(RegExp(r'\b' + word + r'\b'), '');
    }

    // Normalize whitespace
    normalized = normalized
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return normalized;
  }

  /// Normalizes an event URL by removing query parameters and trailing slashes
  /// This allows matching events with URLs like:
  /// - https://eventbrite.com/e/event-tickets-123
  /// - https://eventbrite.com/e/event-tickets-123?aff=tracking
  String _normalizeEventLink(String link) {
    try {
      final uri = Uri.parse(link.trim());
      // Rebuild URL without query parameters and fragment
      var normalized = uri
          .replace(queryParameters: {}, fragment: '')
          .toString();
      // Remove trailing slash
      normalized = normalized.replaceAll(RegExp(r'/+$'), '');
      return normalized.toLowerCase();
    } catch (e) {
      // If parsing fails, just remove query string manually
      return link.split('?').first.toLowerCase().trim();
    }
  }

  /// Normalizes event name by:
  /// - Converting to lowercase
  /// - Removing opening acts (" w/ Artist", "feat.", "featuring", etc.)
  /// - Removing ticket types ("VIP", "General Admission", "Early Entry", etc.)
  /// - Removing seating sections ("Floor", "Balcony", "Orchestra", etc.)
  /// - Removing age restrictions ("18+", "21+")
  /// - Removing dates embedded in names
  /// - Removing special characters and extra whitespace
  String _normalizeEventName(String name) {
    var normalized = name.toLowerCase().trim();

    // Remove common suffix patterns (opening acts, special guests, ticket types, etc.)
    final suffixPatterns = [
      // Opening acts / special guests
      RegExp(r'\s+w/\s+.+$', caseSensitive: false), // " w/ Artist"
      RegExp(r'\s+with\s+.+$', caseSensitive: false), // " with Artist"
      RegExp(
        r'\s+feat\.?\s+.+$',
        caseSensitive: false,
      ), // " feat. Artist" or " feat Artist"
      RegExp(
        r'\s+featuring\s+.+$',
        caseSensitive: false,
      ), // " featuring Artist"
      RegExp(r'\s+plus\s+.+$', caseSensitive: false), // " plus Artist"
      RegExp(r'\s+\+\s+.+$', caseSensitive: false), // " + Artist"
      RegExp(r'\s+and\s+.+$', caseSensitive: false), // " and Artist"
      RegExp(r'\s+&\s+.+$', caseSensitive: false), // " & Artist"
      // Ticket types and entry types
      RegExp(
        r'\s*[-–—]\s*(vip|general admission|ga|early entry|presale|presales?).*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*\((vip|general admission|ga|early entry|presale|presales?).*\).*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s+(vip|general admission|ga|early entry|presale|presales?)\s+(tickets|passes|entry).*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s+(tickets|passes)\s*:?\s*(vip|general admission|ga|early entry).*$',
        caseSensitive: false,
      ),
      // Seating/sections
      RegExp(
        r'\s*[-–—]\s*(floor|balcony|mezzanine|orchestra|section|row|seat).*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*\((floor|balcony|mezzanine|orchestra|section)\s*.*\).*$',
        caseSensitive: false,
      ),
      // Age restrictions
      RegExp(r'\s*[-–—]?\s*\d+\+.*$', caseSensitive: false), // "18+", "21+"
      RegExp(r'\s*\(\d+\+\).*$', caseSensitive: false), // "(18+)"
      // Dates in name (when already have start_time)
      RegExp(
        r'\s*[-–—]?\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}.*$',
        caseSensitive: false,
      ),
      // Generic ticket/layout qualifiers
      RegExp(
        r'\s*[-–—]\s*(admission|tickets?|pass|entry|show|doors?).*$',
        caseSensitive: false,
      ),
    ];

    for (final pattern in suffixPatterns) {
      normalized = normalized.replaceFirst(pattern, '');
    }

    // Remove common punctuation and normalize whitespace
    normalized = normalized
        .replaceAll(RegExp(r'[^\w\s]'), ' ') // Replace special chars with space
        .replaceAll(RegExp(r'\s+'), ' ') // Collapse multiple spaces
        .trim();

    return normalized;
  }

  /// Compares two normalized event names to determine if they match
  /// Uses both exact match and substring matching for flexibility
  bool _areEventNamesMatching(String name1, String name2) {
    // Exact match after normalization
    if (name1 == name2) return true;

    // If one is significantly longer, check if the shorter is a substring
    // This handles cases like "Band Name" vs "Band Name Tour 2026"
    if (name1.length > name2.length) {
      return name1.contains(name2) || name2.contains(name1);
    } else {
      return name2.contains(name1) || name1.contains(name2);
    }
  }

  Future<EventModel?> _sanitizeEventForPublicSave(
    EventModel event, {
    required bool requirePublicJoinable,
  }) async {
    return (await _sanitizeEventForPublicSaveWithReason(
      event,
      requirePublicJoinable: requirePublicJoinable,
    )).event;
  }

  Future<_SanitizedEventResult> _sanitizeEventForPublicSaveWithReason(
    EventModel event, {
    required bool requirePublicJoinable,
  }) async {
    final name = _sanitizeEventText(event.eventName);
    final venue = event.eventVenue == null
        ? null
        : _sanitizeEventText(event.eventVenue!);
    final link = event.eventLink == null
        ? null
        : _sanitizeEventLink(event.eventLink!);
    final description = event.description == null
        ? null
        : _sanitizeEventDescription(event.description!);

    if (name.isEmpty) {
      return const _SanitizedEventResult(null, 'eventAddRejectedMissingTitle');
    }
    if (_containsPii(name) ||
        (venue != null && _containsPii(venue)) ||
        (link != null && _containsPii(link)) ||
        (description != null && _containsPii(description))) {
      return const _SanitizedEventResult(null, 'eventAddRejectedContainsPII');
    }

    if (requirePublicJoinable) {
      final validation = await _validatePublicJoinability(
        eventName: name,
        eventVenue: venue,
        eventLink: link,
        description: description,
        externalProvider: event.externalProvider,
        isAllDay: event.isAllDay,
        startTime: event.startTime,
        endTime: event.endTime,
      );
      if (!validation.allowed) {
        return _SanitizedEventResult(null, validation.errorKey);
      }
    }

    return _SanitizedEventResult(
      EventModel(
        id: event.id,
        eventName: name,
        eventVenue: venue?.trim().isEmpty == true ? null : venue,
        startTime: event.startTime,
        endTime: event.endTime,
        eventLink: link?.trim().isEmpty == true ? null : link,
        notes: event.notes,
        attendeeCount: event.attendeeCount,
        externalCalendarId: event.externalCalendarId,
        externalEventId: event.externalEventId,
        externalProvider: event.externalProvider,
        isAllDay: event.isAllDay,
        description: description,
      ),
      null,
    );
  }

  String _sanitizeEventText(String input) {
    var s = input.trim();
    s = s.replaceAll(
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
      '',
    );
    s = s.replaceAll(RegExp(r'(\+?\d[\d\s().-]{6,}\d)'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 180) s = s.substring(0, 180).trim();
    return s;
  }

  String _sanitizeEventLink(String input) {
    var raw = input.trim();
    if (raw.length >= 2) {
      final first = raw[0];
      final last = raw[raw.length - 1];
      final hasMatchingWrapper =
          (first == '`' && last == '`') ||
          (first == '"' && last == '"') ||
          (first == "'" && last == "'");
      if (hasMatchingWrapper) {
        raw = raw.substring(1, raw.length - 1).trim();
      }
    }
    Uri? uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      return '';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return '';
    final normalized = uri.replace(fragment: '').toString().trim();
    if (normalized.length > 600) return normalized.substring(0, 600);
    return normalized;
  }

  String? _sanitizeEventDescription(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 2000) s = s.substring(0, 2000).trim();
    return s.isEmpty ? null : s;
  }

  bool _containsPii(String input) {
    if (input.isEmpty) return false;
    if (RegExp(
      r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
      caseSensitive: false,
    ).hasMatch(input)) {
      return true;
    }
    if (RegExp(r'(\+?\d[\d\s().-]{6,}\d)').hasMatch(input)) {
      return true;
    }
    return false;
  }

  bool _isPublicEventUrl(String url) {
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = (uri.host).toLowerCase();
    if (host.isEmpty) return false;

    const blockedHosts = {
      'calendar.google.com',
      'www.google.com',
      'outlook.live.com',
      'outlook.office.com',
      'outlook.office365.com',
      'teams.microsoft.com',
      'meet.google.com',
      'zoom.us',
      'www.zoom.us',
    };
    if (blockedHosts.contains(host)) return false;
    if (host.endsWith('.zoom.us')) return false;
    return true;
  }

  Future<_JoinabilityValidationResult> _validatePublicJoinability({
    required String eventName,
    required String? eventVenue,
    required String? eventLink,
    required String? description,
    required String? externalProvider,
    required bool isAllDay,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final hasPublicUrl =
        eventLink != null &&
        eventLink.isNotEmpty &&
        _isPublicEventUrl(eventLink);
    if (hasPublicUrl) {
      return const _JoinabilityValidationResult(allowed: true, errorKey: null);
    }

    final classification = await _classifyEventJoinabilityWithAi(
      eventName: eventName,
      eventVenue: eventVenue,
      eventLink: eventLink,
      description: description,
      externalProvider: externalProvider,
      isAllDay: isAllDay,
      startTime: startTime,
      endTime: endTime,
    );

    return switch (classification) {
      _AiJoinabilityClassification.publicEvent =>
        const _JoinabilityValidationResult(allowed: true, errorKey: null),
      _AiJoinabilityClassification.privateEvent =>
        const _JoinabilityValidationResult(
          allowed: false,
          errorKey: 'eventAddRejectedPrivateEvent',
        ),
      _AiJoinabilityClassification.uncertain =>
        const _JoinabilityValidationResult(
          allowed: false,
          errorKey: 'eventAddRejectedCouldNotVerifyPublic',
        ),
      _AiJoinabilityClassification.unavailable =>
        const _JoinabilityValidationResult(
          allowed: false,
          errorKey: 'eventAddRejectedCouldNotVerifyPublic',
        ),
    };
  }

  Future<_AiJoinabilityClassification> _classifyEventJoinabilityWithAi({
    required String eventName,
    required String? eventVenue,
    required String? eventLink,
    required String? description,
    required String? externalProvider,
    required bool isAllDay,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    try {
      final locale = ref
          .read(localizationProvider)
          .currentLocale
          .toLanguageTag();
      final durationMinutes = endTime.difference(startTime).inMinutes;
      final response = await supabase.functions.invoke(
        'get-event-metadata',
        body: {
          'eventValidation': {
            'title': eventName,
            'location': eventVenue,
            'description': description,
            'url': eventLink,
            'provider': externalProvider,
            'appLocale': locale,
            'isAllDay': isAllDay,
            'startTime': startTime.toIso8601String(),
            'endTime': endTime.toIso8601String(),
            'durationMinutes': durationMinutes < 0 ? 0 : durationMinutes,
            'urlHost': _eventUrlHost(eventLink),
          },
        },
      );

      if (response.status != 200) {
        return _AiJoinabilityClassification.unavailable;
      }

      dynamic data = response.data;
      if (data is String && data.trim().isNotEmpty) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      if (data is! Map) {
        return _AiJoinabilityClassification.unavailable;
      }

      final classification = (data['classification'] as String?)
          ?.trim()
          .toLowerCase();
      return switch (classification) {
        'public' => _AiJoinabilityClassification.publicEvent,
        'private' => _AiJoinabilityClassification.privateEvent,
        'uncertain' => _AiJoinabilityClassification.uncertain,
        _ => _AiJoinabilityClassification.unavailable,
      };
    } catch (_) {
      return _AiJoinabilityClassification.unavailable;
    }
  }

  String? _eventUrlHost(String? rawUrl) {
    final value = rawUrl?.trim();
    if (value == null || value.isEmpty) return null;
    try {
      final uri = Uri.parse(value);
      final host = uri.host.trim().toLowerCase();
      return host.isEmpty ? null : host;
    } catch (_) {
      return null;
    }
  }

  EventSaveResult _mapEventSaveFailure(Object error) {
    if (error is AuthException) {
      return const EventSaveResult(
        success: false,
        errorKey: 'eventAddFailedAuth',
        diagnosticCode: 'auth_exception',
      );
    }

    if (error is PostgrestException) {
      final detailsText = [
        error.message,
        error.details,
        error.hint,
      ].whereType<String>().join(' ').toLowerCase();

      if (error.code == '42501' ||
          detailsText.contains('row-level security') ||
          detailsText.contains('permission denied') ||
          detailsText.contains('not allowed')) {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedPermission',
          diagnosticCode: 'db_permission_denied',
        );
      }

      if (error.code == '23505' ||
          detailsText.contains('duplicate key') ||
          detailsText.contains('unique constraint')) {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedDuplicate',
          diagnosticCode: 'db_duplicate',
        );
      }

      if (error.code == '23503') {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedMissingDependency',
          diagnosticCode: 'db_foreign_key',
        );
      }

      if (error.code == '23502' ||
          error.code == '23514' ||
          error.code == '22P02') {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedInvalidData',
          diagnosticCode: 'db_invalid_data',
        );
      }

      if (detailsText.contains('start_time') &&
          detailsText.contains('must not be in the past')) {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedPastEvent',
          diagnosticCode: 'db_past_event',
        );
      }

      if (error.code == 'PGRST301' ||
          detailsText.contains('jwt') ||
          detailsText.contains('not authenticated')) {
        return const EventSaveResult(
          success: false,
          errorKey: 'eventAddFailedAuth',
          diagnosticCode: 'db_auth',
        );
      }

      return EventSaveResult(
        success: false,
        errorKey: 'eventAddFailedDatabase',
        diagnosticCode: error.code ?? 'db_unknown',
      );
    }

    if (error is TimeoutException) {
      return const EventSaveResult(
        success: false,
        errorKey: 'eventAddFailedNetwork',
        diagnosticCode: 'timeout',
      );
    }

    final message = error.toString().toLowerCase();
    if (message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('network') ||
        message.contains('connection')) {
      return const EventSaveResult(
        success: false,
        errorKey: 'eventAddFailedNetwork',
        diagnosticCode: 'network_error',
      );
    }

    return const EventSaveResult(
      success: false,
      errorKey: 'eventAddFailedUnknown',
      diagnosticCode: 'unknown',
    );
  }

  Future<String?> _findExistingEventIdForImport(EventModel safeEvent) async {
    final normalizedVenue = _normalizeVenue(safeEvent.eventVenue);
    final normalizedName = _normalizeEventName(safeEvent.eventName);

    var potentialMatchesQuery = supabase
        .from('events')
        .select('id, event_name, event_venue')
        .eq('start_time', safeEvent.startTime.toIso8601String());

    if (normalizedVenue.isEmpty) {
      potentialMatchesQuery = potentialMatchesQuery.or(
        'event_venue.is.null,event_venue.eq.',
      );
    }

    final potentialMatches = await potentialMatchesQuery;

    for (final match
        in (potentialMatches as List<dynamic>).cast<Map<String, dynamic>>()) {
      final existingNormalizedName = _normalizeEventName(
        match['event_name'] as String,
      );
      final existingNormalizedVenue = _normalizeVenue(
        match['event_venue'] as String?,
      );

      final namesMatch = _areEventNamesMatching(
        normalizedName,
        existingNormalizedName,
      );
      final venuesMatch =
          normalizedVenue == existingNormalizedVenue ||
          (normalizedVenue.isNotEmpty &&
              existingNormalizedVenue.isNotEmpty &&
              (normalizedVenue.contains(existingNormalizedVenue) ||
                  existingNormalizedVenue.contains(normalizedVenue)));

      if (namesMatch && venuesMatch) {
        return match['id'] as String;
      }
    }

    if (safeEvent.eventLink != null && safeEvent.eventLink!.isNotEmpty) {
      final normalizedLink = _normalizeEventLink(safeEvent.eventLink!);
      final linkMatch = await supabase
          .from('events')
          .select('id, event_link')
          .ilike('event_link', '%${normalizedLink.split('?').first}%')
          .eq('start_time', safeEvent.startTime.toIso8601String())
          .maybeSingle();

      if (linkMatch != null) {
        final existingNormalizedLink = _normalizeEventLink(
          linkMatch['event_link'] ?? '',
        );
        if (existingNormalizedLink == normalizedLink) {
          return linkMatch['id'] as String;
        }
      }
    }

    return null;
  }

  bool _isUniqueConstraintFailure(PostgrestException error) {
    final detailsText = [
      error.message,
      error.details,
      error.hint,
    ].whereType<String>().join(' ').toLowerCase();
    return error.code == '23505' ||
        detailsText.contains('duplicate key') ||
        detailsText.contains('unique constraint');
  }
}

class EventSaveResult {
  final bool success;
  final String? errorKey;
  final String? diagnosticCode;

  const EventSaveResult({
    required this.success,
    this.errorKey,
    this.diagnosticCode,
  });
}

class _SanitizedEventResult {
  final EventModel? event;
  final String? errorKey;

  const _SanitizedEventResult(this.event, this.errorKey);
}

class _JoinabilityValidationResult {
  final bool allowed;
  final String? errorKey;

  const _JoinabilityValidationResult({
    required this.allowed,
    required this.errorKey,
  });
}

enum _AiJoinabilityClassification {
  publicEvent,
  privateEvent,
  uncertain,
  unavailable,
}
