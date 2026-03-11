// lib/providers/event_provider.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<void> fetchUserEvents() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      if (ref.mounted) {
        state = const AsyncValue.data([]);
      }
      return;
    }

    final localDb = ref.read(localDbProvider);

    // First try to get cached events
    final cachedEvents = await localDb.getCachedUserEvents(userId);

    // Check if provider is still mounted after async operation
    if (!ref.mounted) return;

    if (cachedEvents != null) {
      // Use cached data immediately
      final events = cachedEvents.map((eventData) => EventModel.fromJson(eventData)).toList();
      state = AsyncValue.data(events);

      // Refresh from server in background
      _refreshEventsFromServer(userId, localDb);
    } else {
      // No cache, fetch from server
      await _fetchEventsFromServer(userId, localDb);
    }
  }

  Future<void> _refreshEventsFromServer(String userId, LocalDbService localDb) async {
    try {
      await _fetchEventsFromServer(userId, localDb, updateState: true);
    } catch (_) {
      // Silently fail background refresh - _fetchEventsFromServer already checks ref.mounted
    }
  }

  Future<void> _fetchEventsFromServer(String userId, LocalDbService localDb, {bool updateState = true}) async {
    try {
      // Query events the current user is attending
      // Join events with event_attendees to get user's personal notes and attendee count
      var query = supabase
          .from('event_attendees')
          .select('''
            notes,
            events!inner(
              id,
              event_name,
              event_venue,
              start_time,
              end_time,
              event_link
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

        // Get attendee count for this event
        int attendeeCount = 1;
        try {
          final countResponse = await supabase.rpc(
            'count_event_attendees',
            params: {'event_id_param': eventData['id']}
          );

          if (countResponse is int) {
            attendeeCount = countResponse;
          } else if (countResponse is Map<String, dynamic> && countResponse.containsKey('count')) {
            final countValue = countResponse['count'];
            if (countValue is int) {
              attendeeCount = countValue;
            } else if (countValue is String) {
              attendeeCount = int.tryParse(countValue) ?? 1;
            }
          }
        } catch (_) {
          // RPC failed, keep default of 1
          attendeeCount = 1;
        }

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
      // Check if provider is still mounted before updating state
      if (!ref.mounted) return;

      if (updateState) {
        state = AsyncValue.error(e, s);
      }
    }
  }

  Future<bool> addEvent(EventModel event) async {
    final result = await addEventWithResult(event);
    return result.success;
  }

  Future<EventSaveResult> addEventWithResult(EventModel event) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) {
        return const EventSaveResult(success: false, errorKey: 'eventAddFailedAuth');
      }

      final sanitize = _sanitizeEventForPublicSaveWithReason(
        event,
        requirePublicJoinable: true,
      );
      final safeEvent = sanitize.event;
      if (safeEvent == null) {
        return EventSaveResult(success: false, errorKey: sanitize.errorKey ?? 'eventAddFailedUnknown');
      }

      // Step 1: Check if event already exists using multiple strategies
      // Note: We prioritize name+venue+time matching over URL matching because
      // different ticketing vendors use completely different URLs for the same event
      String? existingEventId;

      // Strategy 1: Check by normalized name + venue + start_time (works across vendors)
      {
        final normalizedVenue = _normalizeVenue(safeEvent.eventVenue);
        final normalizedName = _normalizeEventName(safeEvent.eventName);

        // Get potential matches by start_time (we'll filter by venue in code)
        var potentialMatchesQuery = supabase
            .from('events')
            .select('id, event_name, event_venue')
            .eq('start_time', safeEvent.startTime.toIso8601String());

        // For null/empty venues, only match other null/empty venues
        if (normalizedVenue.isEmpty) {
          potentialMatchesQuery = potentialMatchesQuery.or('event_venue.is.null,event_venue.eq.');
        }

        final potentialMatches = await potentialMatchesQuery;

        // Check each potential match for name and venue similarity
        for (final match in (potentialMatches as List<dynamic>).cast<Map<String, dynamic>>()) {
          final existingNormalizedName = _normalizeEventName(match['event_name'] as String);
          final existingNormalizedVenue = _normalizeVenue(match['event_venue'] as String?);

          // Both name AND venue must match (within tolerance)
          final namesMatch = _areEventNamesMatching(normalizedName, existingNormalizedName);
          final venuesMatch = normalizedVenue == existingNormalizedVenue ||
              (normalizedVenue.isNotEmpty &&
               existingNormalizedVenue.isNotEmpty &&
               (normalizedVenue.contains(existingNormalizedVenue) ||
                existingNormalizedVenue.contains(normalizedVenue)));

          if (namesMatch && venuesMatch) {
            existingEventId = match['id'] as String;
            break;
          }
        }
      }

      // Strategy 2: Check by normalized event_link (same vendor scenario)
      // Only used as fallback since different vendors have different URLs
      if (existingEventId == null && safeEvent.eventLink != null && safeEvent.eventLink!.isNotEmpty) {
        final normalizedLink = _normalizeEventLink(safeEvent.eventLink!);
        final linkMatch = await supabase
            .from('events')
            .select('id, event_link')
            .ilike('event_link', '%${normalizedLink.split('?').first}%')
            .eq('start_time', safeEvent.startTime.toIso8601String())
            .maybeSingle();

        if (linkMatch != null) {
          // Verify the existing link matches when normalized
          final existingNormalizedLink = _normalizeEventLink(linkMatch['event_link'] ?? '');
          if (existingNormalizedLink == normalizedLink) {
            existingEventId = linkMatch['id'] as String;
          }
        }
      }

      String eventId;

      if (existingEventId != null) {
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
            return const EventSaveResult(success: true);
          }
          rethrow;
        }
      } else {
        // Event doesn't exist - create it
        final newEvent = await supabase
            .from('events')
            .insert(safeEvent.toJsonForSave())
            .select('id')
            .single();

        eventId = newEvent['id'] as String;

        // Add creator as first attendee
        await supabase.from('event_attendees').insert({
          'event_id': eventId,
          'user_id': userId,
          'notes': safeEvent.notes,
        });
      }

      await fetchUserEvents(); // Refresh the list

      // Create matches for event-based connections
      await createEventMatches(eventId, safeEvent.eventName, safeEvent.eventVenue, safeEvent.startTime);

      return const EventSaveResult(success: true);
    } catch (e) {
      return const EventSaveResult(success: false, errorKey: 'eventAddFailedUnknown');
    }
  }

  Future<bool> updateEvent(EventModel event) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return false;

      final safeEvent = _sanitizeEventForPublicSave(event, requirePublicJoinable: true);
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

  Future<bool> deleteEvent(String eventId) async {
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

  Future<void> createEventMatches(String eventId, String eventName, String? eventVenue, DateTime startTime) async {
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
      'the', 'at', 'in', 'on', 'live', 'music', 'venue', 'club'
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
      var normalized = uri.replace(queryParameters: {}, fragment: '').toString();
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
      RegExp(r'\s+w/\s+.+$', caseSensitive: false),           // " w/ Artist"
      RegExp(r'\s+with\s+.+$', caseSensitive: false),        // " with Artist"
      RegExp(r'\s+feat\.?\s+.+$', caseSensitive: false),     // " feat. Artist" or " feat Artist"
      RegExp(r'\s+featuring\s+.+$', caseSensitive: false),   // " featuring Artist"
      RegExp(r'\s+plus\s+.+$', caseSensitive: false),        // " plus Artist"
      RegExp(r'\s+\+\s+.+$', caseSensitive: false),          // " + Artist"
      RegExp(r'\s+and\s+.+$', caseSensitive: false),         // " and Artist"
      RegExp(r'\s+&\s+.+$', caseSensitive: false),           // " & Artist"
      // Ticket types and entry types
      RegExp(r'\s*[-–—]\s*(vip|general admission|ga|early entry|presale|presales?).*$', caseSensitive: false),
      RegExp(r'\s*\((vip|general admission|ga|early entry|presale|presales?).*\).*$', caseSensitive: false),
      RegExp(r'\s+(vip|general admission|ga|early entry|presale|presales?)\s+(tickets|passes|entry).*$', caseSensitive: false),
      RegExp(r'\s+(tickets|passes)\s*:?\s*(vip|general admission|ga|early entry).*$', caseSensitive: false),
      // Seating/sections
      RegExp(r'\s*[-–—]\s*(floor|balcony|mezzanine|orchestra|section|row|seat).*$', caseSensitive: false),
      RegExp(r'\s*\((floor|balcony|mezzanine|orchestra|section)\s*.*\).*$', caseSensitive: false),
      // Age restrictions
      RegExp(r'\s*[-–—]?\s*\d+\+.*$', caseSensitive: false),  // "18+", "21+"
      RegExp(r'\s*\(\d+\+\).*$', caseSensitive: false),       // "(18+)"
      // Dates in name (when already have start_time)
      RegExp(r'\s*[-–—]?\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}.*$', caseSensitive: false),
      // Generic ticket/layout qualifiers
      RegExp(r'\s*[-–—]\s*(admission|tickets?|pass|entry|show|doors?).*$', caseSensitive: false),
    ];

    for (final pattern in suffixPatterns) {
      normalized = normalized.replaceFirst(pattern, '');
    }

    // Remove common punctuation and normalize whitespace
    normalized = normalized
        .replaceAll(RegExp(r'[^\w\s]'), ' ')  // Replace special chars with space
        .replaceAll(RegExp(r'\s+'), ' ')      // Collapse multiple spaces
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

  EventModel? _sanitizeEventForPublicSave(EventModel event, {required bool requirePublicJoinable}) {
    return _sanitizeEventForPublicSaveWithReason(event, requirePublicJoinable: requirePublicJoinable).event;
  }

  _SanitizedEventResult _sanitizeEventForPublicSaveWithReason(EventModel event, {required bool requirePublicJoinable}) {
    final name = _sanitizeEventText(event.eventName);
    final venue = event.eventVenue == null ? null : _sanitizeEventText(event.eventVenue!);
    final link = event.eventLink == null ? null : _sanitizeEventLink(event.eventLink!);

    if (name.isEmpty) return const _SanitizedEventResult(null, 'eventAddRejectedMissingTitle');
    if (_containsPii(name) || (venue != null && _containsPii(venue)) || (link != null && _containsPii(link))) {
      return const _SanitizedEventResult(null, 'eventAddRejectedContainsPII');
    }

    final lowerTitle = name.toLowerCase();
    final lowerLocation = (venue ?? '').toLowerCase();
    if (_looksPersonalTitle(lowerTitle) || _looksPersonalLocation(lowerLocation)) {
      return const _SanitizedEventResult(null, 'eventAddRejectedPersonalOrPrivate');
    }

    if (requirePublicJoinable) {
      final linkOk = link != null && link.isNotEmpty && _isPublicEventUrl(link);
      final venueOk = venue != null && venue.trim().isNotEmpty && !_looksPersonalLocation(lowerLocation);

      if (!linkOk && !venueOk) {
        return const _SanitizedEventResult(null, 'eventAddRejectedNotJoinable');
      }
      if (!linkOk && !_looksPublicEventTitle(lowerTitle)) {
        return const _SanitizedEventResult(null, 'eventAddRejectedNotPublicEvent');
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
      ),
      null,
    );
  }

  String _sanitizeEventText(String input) {
    var s = input.trim();
    s = s.replaceAll(RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'(\+?\d[\d\s().-]{6,}\d)'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 180) s = s.substring(0, 180).trim();
    return s;
  }

  String _sanitizeEventLink(String input) {
    final raw = input.trim();
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

  bool _containsPii(String input) {
    if (input.isEmpty) return false;
    if (RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false).hasMatch(input)) {
      return true;
    }
    if (RegExp(r'(\+?\d[\d\s().-]{6,}\d)').hasMatch(input)) {
      return true;
    }
    return false;
  }

  bool _looksPersonalTitle(String lowerTitle) {
    return RegExp(
      r'\b(birthday|anniversary|dentist|doctor|therapy|appointment|1:1|one[-\s]?on[-\s]?one|meeting|sync|call|interview|school|pickup|drop[-\s]?off|flight|reservation|invoice|receipt|dinner|lunch|brunch|coffee|drinks?|date\s*night|hangout|hang\s*out|catch\s*up|catchup)\b',
      caseSensitive: false,
    ).hasMatch(lowerTitle);
  }

  bool _looksPublicEventTitle(String lowerTitle) {
    return RegExp(
      r'\b(concert|festival|show|gig|party|club\s*night|open\s*mic|exhibition|gallery|museum|theatre|theater|screening|premiere|tournament|match|league|conference|summit|meetup|workshop|class|seminar|lecture|talk|networking|fundraiser|charity|rave|dj\s*set)\b',
      caseSensitive: false,
    ).hasMatch(lowerTitle);
  }

  bool _looksPersonalLocation(String lowerLocation) {
    return RegExp(r'\b(home|my place|house|apartment|apt\.?|unit\s+\d+)\b', caseSensitive: false)
        .hasMatch(lowerLocation);
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
}

class EventSaveResult {
  final bool success;
  final String? errorKey;

  const EventSaveResult({required this.success, this.errorKey});
}

class _SanitizedEventResult {
  final EventModel? event;
  final String? errorKey;

  const _SanitizedEventResult(this.event, this.errorKey);
}
