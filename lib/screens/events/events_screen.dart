// lib/screens/events_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/events/add_event_screen.dart'; // <-- CORRECTED PATH
import 'package:matchme/screens/events/attendees_screen.dart'; // <-- CORRECTED PATH
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';

class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

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
      appBar: AppBar(
        title: Text(l10n.getString('eventsScreenTitle')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            tooltip: l10n.getString('eventAdd'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AddEventScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (profileAsync.hasValue && profileAsync.value != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Row(
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
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const AddEventScreen()),
          );
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

  Widget _buildEventListItem(BuildContext context, WidgetRef ref, LocalizationState l10n, EventModel event) {

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
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => AttendeesScreen(event: event)),
          );
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
                        _buildEventDetailRow(context, l10n.getString('eventLocationLabel'), event.eventVenue ?? l10n.getString('eventVenueNotSpecified')),
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
