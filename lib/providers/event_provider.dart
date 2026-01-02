// lib/providers/event_provider.dart
import 'dart:async';
// ...existing code...
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'event_provider.g.dart';

final supabase = Supabase.instance.client;

// --- Event Management Notifier ---
@riverpod
class EventManager extends _$EventManager {
  @override
  AsyncValue<List<EventModel>> build() {
    fetchUserEvents();
    return const AsyncValue.loading();
  }

  Future<void> fetchUserEvents() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      state = const AsyncValue.data([]);
      return;
    }

    final localDb = ref.read(localDbProvider);

    // First try to get cached events
    final cachedEvents = await localDb.getCachedUserEvents(userId);

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
      // Silently fail background refresh
    }
  }

  Future<void> _fetchEventsFromServer(String userId, LocalDbService localDb, {bool updateState = true}) async {
    try {
      // Query events the current user is attending
      // Join events with event_attendees to get user's personal notes and attendee count
      final response = await supabase
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
          ''')
          .eq('user_id', userId);

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

      if (updateState) {
        state = AsyncValue.data(events);
      }
    } catch (e, s) {
      if (updateState) {
        state = AsyncValue.error(e, s);
      }
    }
  }

  Future<bool> addEvent(EventModel event) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) {
        return false;
      }



      // Step 1: Check if event already exists (same name, venue, start time)
      // Normalize venue field for comparison - treat null and empty string as equivalent
      final normalizedVenue = event.eventVenue?.trim().isEmpty == true ? null : event.eventVenue;
      
      var queryBuilder = supabase
          .from('events')
          .select('id')
          .eq('event_name', event.eventName)
          .eq('start_time', event.startTime.toIso8601String());

      // Handle venue comparison properly
      if (normalizedVenue == null) {
        // If venue is null, check for both NULL and empty string in database
        queryBuilder = queryBuilder.or('event_venue.is.null,event_venue.eq.');
      } else {
        queryBuilder = queryBuilder.eq('event_venue', normalizedVenue);
      }

      final existingEvent = await queryBuilder.maybeSingle();

      String eventId;
      
      if (existingEvent != null) {
        // Event exists - just link the user to it
        eventId = existingEvent['id'] as String;
        
        // Add user as attendee (or ignore if already attending)
        try {
          await supabase.from('event_attendees').insert({
            'event_id': eventId,
            'user_id': userId,
            'notes': event.notes,
          });
        } catch (e) {
          if (e is PostgrestException && e.code == '23505') {
            // Duplicate key, user already attending
            return true;
          }
          rethrow;
        }
      } else {
        // Event doesn't exist - create it
        final newEvent = await supabase
            .from('events')
            .insert(event.toJsonForSave())
            .select('id')
            .single();
        
        eventId = newEvent['id'] as String;
        
        // Add creator as first attendee
        await supabase.from('event_attendees').insert({
          'event_id': eventId,
          'user_id': userId,
          'notes': event.notes,
        });
      }
      
      await fetchUserEvents(); // Refresh the list
      
      // Create matches for event-based connections
      await createEventMatches(eventId, event.eventName, event.eventVenue, event.startTime);
      
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateEvent(EventModel event) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      // Update the event itself (all attendees will see changes)
      await supabase
          .from('events')
          .update(event.toJsonForSave())
          .eq('id', event.id);
      
      // Update the user's personal notes
      await supabase
          .from('event_attendees')
          .update({'notes': event.notes})
          .eq('event_id', event.id)
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
}
// --- END Event Management Notifier ---

// --- DELETED: eventParseResultProvider is no longer needed ---
