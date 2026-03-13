// lib/screens/events_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/calendar_sync_provider.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/events/add_event_screen.dart'; // <-- CORRECTED PATH
import 'package:matchme/screens/events/attendees_screen.dart'; // <-- CORRECTED PATH
import 'package:matchme/screens/events/calendar_sync_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/map_utils.dart';

class EventsTab extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const EventsTab({super.key, required this.navigatorKey});

  @override
  ConsumerState<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends ConsumerState<EventsTab> {
  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingEventTabRouteProvider);
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.navigatorKey.currentState?.pushNamed('/attendees', arguments: pending);
        ref.read(pendingEventTabRouteProvider.notifier).clear();
      });
    }

    final pendingShare = ref.watch(pendingAddEventShareProvider);
    if (pendingShare != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.navigatorKey.currentState?.pushNamed('/add', arguments: pendingShare);
        ref.read(pendingAddEventShareProvider.notifier).clear();
      });
    }

    return Navigator(
      key: widget.navigatorKey,
      initialRoute: '/',
      onGenerateRoute: (settings) {
        if (settings.name == '/' || settings.name == null) {
          return MaterialPageRoute(
            builder: (context) => EventsScreen(
              showAppBar: false,
              onAddEvent: () => Navigator.of(context).pushNamed('/add'),
              onOpenEvent: (event) => Navigator.of(context).pushNamed('/attendees', arguments: event),
              onImportGoogleCalendar:
                  () => widget.navigatorKey.currentState?.pushNamed('/sync', arguments: CalendarProvider.google),
              onImportOutlookCalendar:
                  () => widget.navigatorKey.currentState?.pushNamed('/sync', arguments: CalendarProvider.outlook),
            ),
          );
        }

        if (settings.name == '/add') {
          final args = settings.arguments;
          String? sharedText;
          String? sharedFilePath;
          if (args is Map) {
            final map = Map<String, dynamic>.from(args);
            sharedText = (map['sharedText'] as String?)?.trim();
            sharedFilePath = (map['sharedFilePath'] as String?)?.trim();
          }

          return MaterialPageRoute(
            builder: (context) => AddEventScreen(
              showAppBar: false,
              initialSharedText: sharedText,
              initialSharedFilePath: sharedFilePath,
            ),
          );
        }

        if (settings.name == '/attendees') {
          final event = settings.arguments as EventModel;
          return MaterialPageRoute(builder: (context) => AttendeesScreen(event: event, showAppBar: false));
        }

        if (settings.name == '/sync') {
          final args = settings.arguments as CalendarProvider?;
          return MaterialPageRoute(builder: (context) => CalendarSyncScreen(initialProvider: args));
        }

        return MaterialPageRoute(builder: (context) => EventsScreen(showAppBar: false));
      },
    );
  }
}

class EventsScreen extends ConsumerWidget {
  final bool showAppBar;
  final VoidCallback? onAddEvent;
  final void Function(EventModel event)? onOpenEvent;
  final VoidCallback? onImportGoogleCalendar;
  final VoidCallback? onImportOutlookCalendar;

  const EventsScreen({
    super.key,
    this.showAppBar = true,
    this.onAddEvent,
    this.onOpenEvent,
    this.onImportGoogleCalendar,
    this.onImportOutlookCalendar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final eventsAsync = ref.watch(eventManagerProvider);
    final userId = Supabase.instance.client.auth.currentUser!.id;
    final profileAsync = ref.watch(profileEditProvider(userId));

    if (profileAsync is AsyncLoading) {
      Future.microtask(() => ref.read(profileEditProvider(userId).notifier).loadInitialProfile());
    }

    return Scaffold(
      appBar: showAppBar
          ? AppBar(
              title: Text(l10n.getString('eventsScreenTitle')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add_box_outlined),
                  tooltip: l10n.getString('eventAdd'),
                  onPressed: () {
                    final handler = onAddEvent;
                    if (handler != null) {
                      handler();
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const AddEventScreen()),
                    );
                  },
                ),
              ],
            )
          : null,
      body: Column(
        children: [
          if (profileAsync.hasValue && profileAsync.value != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.getString('settingsSharedEventMatching'),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Switch(
                        value: profileAsync.value!.sharedEventMatchingEnabled,
                        onChanged: (value) async {
                          try {
                            await ref.read(profileEditProvider(userId).notifier).updateSharedEventMatching(value);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(l10n.getString('settingsSharedEventMatchingUpdated')), backgroundColor: Theme.of(context).colorScheme.primary),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('${l10n.getString('settingsSharedEventMatchingUpdateFailed')}: $e'), backgroundColor: Theme.of(context).colorScheme.error),
                              );
                            }
                          }
                        },
                        activeThumbColor: Theme.of(context).colorScheme.secondary,
                        activeTrackColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.3),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.getString('showPastEvents'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      // Use EventManager's notifier to persist the toggle and refresh the list
                      Switch(
                        value: ref.read(eventManagerProvider.notifier).showPastEvents,
                        onChanged: (value) async {
                          ref.read(eventManagerProvider.notifier).setShowPastEvents(value);
                          await ref.read(eventManagerProvider.notifier).fetchUserEvents();
                        },
                        activeThumbColor: Theme.of(context).colorScheme.secondary,
                        activeTrackColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.3),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final handler = onImportGoogleCalendar;
                            if (handler != null) {
                              handler();
                              return;
                            }
                            Navigator.of(context).pushNamed('/sync', arguments: CalendarProvider.google);
                          },
                          icon: const Icon(Icons.calendar_month),
                          label: Text(l10n.getString('eventsImportGoogle')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final handler = onImportOutlookCalendar;
                            if (handler != null) {
                              handler();
                              return;
                            }
                            if (kIsWeb) {
                              final service = ref.read(calendarSyncServiceProvider);
                              try {
                                final token = await service.signInOutlook();
                                if (token == null) return;
                                if (!context.mounted) return;
                              } catch (_) {
                                return;
                              }
                            }
                            Navigator.of(context).pushNamed(
                              '/sync',
                              arguments: CalendarProvider.outlook,
                            );
                          },
                          icon: const Icon(Icons.mail_outline),
                          label: Text(l10n.getString('eventsImportOutlook')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: eventsAsync.when(
              data: (events) {
                if (events.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Theme.of(context).colorScheme.primary.withValues(alpha:0.1), Theme.of(context).colorScheme.secondary.withValues(alpha:0.1)],
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.calendar_today_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.getString('eventNoActiveEvents'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.getString('eventCreateFirst'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(eventManagerProvider.notifier).fetchUserEvents(),
            child: ListView.builder(
              itemCount: events.length,
              itemBuilder: (context, index) {
                final event = events[index];
                return _buildEventListItem(context, ref, l10n, event);
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('${l10n.getString('generalError')}: $e')),
      ),
    ),
  ],
),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'events_add_fab',
        onPressed: () {
          final handler = onAddEvent;
          if (handler != null) {
            handler();
            return;
          }
          Navigator.push(context, MaterialPageRoute(builder: (context) => const AddEventScreen()));
        },
        tooltip: l10n.getString('eventAdd'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        icon: const Icon(Icons.add),
        label: Text(l10n.getString('eventAdd')),
      ),
    );
  }

  Widget _buildLocationRow(BuildContext context, WidgetRef ref, LocalizationState l10n, String label, String value) {
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.85),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
            ),
          ),
        ),
      ],
    );
  }

  bool _isVirtualMeetingLocation(String raw) {
    final s = raw.toLowerCase().trim();
    if (s.isEmpty) {
      return false;
    }
    if (s == 'online' || s == 'virtual') {
      return true;
    }
    if (s.contains('http://') || s.contains('https://')) {
      return true;
    }
    if (s.contains('zoom.us') || s.contains('zoom.com') || s.contains('zoom')) {
      return true;
    }
    if (s.contains('meet.google.com') || s.contains('google meet')) {
      return true;
    }
    if (s.contains('teams.microsoft.com') ||
        s.contains('microsoft teams') ||
        s.contains('ms teams')) {
      return true;
    }
    if (s.contains('webex') ||
        s.contains('gotomeeting') ||
        s.contains('go to meeting') ||
        s.contains('skype') ||
        s.contains('hangouts') ||
        s.contains('discord.gg') ||
        s.contains('discord.com')) {
      return true;
    }
    if (s.contains('online meeting') ||
        s.contains('virtual meeting') ||
        s.contains('video call') ||
        s.contains('conference call')) {
      return true;
    }
    return false;
  }

  Widget _buildEventListItem(BuildContext context, WidgetRef ref, LocalizationState l10n, EventModel event) {
    final venue = event.eventVenue?.trim();
    final hasVenue = venue != null && venue.isNotEmpty;
    final showMap = hasVenue && !_isVirtualMeetingLocation(venue);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha:0.05),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          final handler = onOpenEvent;
          if (handler != null) {
            handler(event);
            return;
          }
          Navigator.push(context, MaterialPageRoute(builder: (context) => AttendeesScreen(event: event)));
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              // Main content uses the full width; delete button is overlaid so it doesn't shrink the title.
              Row(
                textDirection: l10n.textDirection,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          event.eventName,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: event.eventName.isRtl() ? TextAlign.right : TextAlign.left,
                          textDirection: event.eventName.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                        ),
                        const SizedBox(height: 8),
                        _buildLocationRow(context, ref, l10n, l10n.getString('eventLocationLabel'), event.eventVenue ?? l10n.getString('eventVenueNotSpecified')),
                        const SizedBox(height: 4),
                        _buildEventDetailRow(context, l10n.getString('eventDateLabel'), _formatDateOnly(event.startTime, l10n)),
                        const SizedBox(height: 4),
                        _buildEventDetailRow(context, l10n.getString('eventTimeLabel'), formatTimeOfDateTimeWithPrefs(context, ref, l10n, event.startTime)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (event.eventLink != null && event.eventLink!.isNotEmpty) ...[
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final Uri url = Uri.parse(event.eventLink!);
                                    if (await canLaunchUrl(url)) {
                                      await launchUrl(url, mode: LaunchMode.externalApplication);
                                    }
                                  },
                                  child: Row(
                                    children: [
                                      Icon(Icons.link, size: 14, color: Theme.of(context).colorScheme.primary),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          l10n.getString('eventViewDetails'),
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Theme.of(context).colorScheme.primary,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ] else ...[
                              const Spacer(),
                            ],
                            if (showMap) ...[
                              InkWell(
                                onTap: () async {
                                  final success = await openGoogleMaps(venue);
                                  if (!success && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l10n.getString('errorCouldNotOpenMaps')),
                                        backgroundColor: Colors.orange,
                                      ),
                                    );
                                  }
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                                      width: 1,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.map_outlined,
                                    size: 20,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                              onPressed: () => _confirmDelete(context, ref, l10n, event),
                              style: IconButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.error.withValues(alpha:0.1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, LocalizationState l10n, EventModel event) async {
    final bool? shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.getString('eventDeleteConfirm')),
        content: Text(event.eventName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      final success = await ref.read(eventManagerProvider.notifier).deleteEvent(event.id);
      if (context.mounted && success) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('eventDeleted')), backgroundColor: Colors.orange));
      }
    }
  }

  Widget _buildEventDetailRow(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.85),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
            ),
          ),
        ),
      ],
    );
  }


  String _formatDateOnly(DateTime dateTime, LocalizationState l10n) {
    try {
      final curLocale = l10n.currentLocale;
      final langCode = curLocale.languageCode.toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(dateTime);
        } catch (e) {
          return DateFormat('EEEE, d MMMM y').format(dateTime);
        }
      } else {
        try {
          final localeTag = curLocale.toLanguageTag();
          final df = DateFormat('EEEE, MMMM d, y', localeTag);
          return df.format(dateTime);
        } catch (e) {
          return DateFormat('EEEE, MMMM d, y').format(dateTime);
        }
      }
    } catch (e) {
      // Fallback
      return DateFormat('EEEE, MMMM d, yyyy').format(dateTime);
    }
  }

}
