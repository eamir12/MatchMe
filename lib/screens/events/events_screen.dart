// lib/screens/events_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/calendar_sync_provider.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/events/add_event_screen.dart'; // <-- CORRECTED PATH
import 'package:matchme/screens/events/attendees_screen.dart'; // <-- CORRECTED PATH
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/screens/events/calendar_sync_screen.dart';
import 'package:matchme/screens/events/online_providers_screen.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/event_attendance_summary.dart';
import 'package:matchme/widgets/event_matched_attendees.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/event_venue_utils.dart';
import 'package:matchme/services/web_calendar_service.dart';

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
        widget.navigatorKey.currentState?.pushNamed(
          '/attendees',
          arguments: pending,
        );
        ref.read(pendingEventTabRouteProvider.notifier).clear();
      });
    }

    final pendingShare = ref.watch(pendingAddEventShareProvider);
    if (pendingShare != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.navigatorKey.currentState?.pushNamed(
          '/add',
          arguments: pendingShare,
        );
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
              onOpenEvent: (event) => Navigator.of(
                context,
              ).pushNamed('/attendees', arguments: event),
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
          return MaterialPageRoute(
            builder: (context) =>
                AttendeesScreen(event: event, showAppBar: false),
          );
        }

        if (settings.name == '/sync') {
          final args = settings.arguments as CalendarProvider?;
          return MaterialPageRoute(
            builder: (context) => CalendarSyncScreen(initialProvider: args),
          );
        }

        return MaterialPageRoute(
          builder: (context) => EventsScreen(showAppBar: false),
        );
      },
    );
  }
}

/// Search text for the Events list.
///
/// EventsScreen is a ConsumerWidget, so the query lives in a Notifier rather
/// than in State. That keeps the widget itself untouched apart from reading
/// this value, instead of converting a 1300-line widget to stateful.
class EventsSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;

  void clear() => state = '';
}

final eventsSearchQueryProvider =
    NotifierProvider<EventsSearchQueryNotifier, String>(
      EventsSearchQueryNotifier.new,
    );

/// Search field for the Events list, styled to match the one on the Chats and
/// Matches screens.
class EventsSearchField extends ConsumerStatefulWidget {
  const EventsSearchField({super.key});

  @override
  ConsumerState<EventsSearchField> createState() => _EventsSearchFieldState();
}

class _EventsSearchFieldState extends ConsumerState<EventsSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(eventsSearchQueryProvider),
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final rawText = _controller.text;
    final isEmpty = rawText.trim().isEmpty;
    final isRtl = !isEmpty && rawText.trimLeft().isRtlByFirstStrongChar();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _controller,
        onChanged: (value) =>
            ref.read(eventsSearchQueryProvider.notifier).update(value),
        textInputAction: TextInputAction.search,
        textDirection: isEmpty
            ? Directionality.of(context)
            : (isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr),
        textAlign: isEmpty
            ? TextAlign.start
            : (isRtl ? TextAlign.right : TextAlign.left),
        decoration: InputDecoration(
          labelText: l10n.getString('eventsSearchLabel'),
          hintText: l10n.getString('eventsSearchHint'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.getString('generalClear'),
                  onPressed: () {
                    _controller.clear();
                    ref.read(eventsSearchQueryProvider.notifier).clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
          isDense: true,
          filled: true,
          fillColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class EventsScreen extends ConsumerWidget {
  final bool showAppBar;
  final VoidCallback? onAddEvent;
  final void Function(EventModel event)? onOpenEvent;
  final VoidCallback? onImportGoogleCalendar;
  final VoidCallback? onImportOutlookCalendar;
  final VoidCallback? onImportAppleCalendar;

  const EventsScreen({
    super.key,
    this.showAppBar = true,
    this.onAddEvent,
    this.onOpenEvent,
    this.onImportGoogleCalendar,
    this.onImportOutlookCalendar,
    this.onImportAppleCalendar,
  });

  Future<String?> _showImportPermissionDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = ref.read(localizationProvider);
    final settingsGuideKey = switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        'calendarSyncPermissionBlockedSettingsGuideAndroid',
      TargetPlatform.iOS => 'calendarSyncPermissionBlockedSettingsGuideIos',
      _ => 'calendarSyncPermissionBlockedSettingsGuide',
    };
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final isRtl = Directionality.of(dialogContext) == ui.TextDirection.rtl;
        final contentAlignment = isRtl
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start;
        final textAlign = isRtl ? TextAlign.right : TextAlign.left;
        final buttonAlignment = isRtl
            ? Alignment.centerRight
            : Alignment.centerLeft;
        return AlertDialog(
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(l10n.getString('calendarSyncPermissionTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: contentAlignment,
            children: [
              Text(l10n.getString(settingsGuideKey), textAlign: textAlign),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop('open_settings'),
                  style: FilledButton.styleFrom(alignment: buttonAlignment),
                  child: Text(
                    l10n.getString(
                      'calendarSyncPermissionActionOpenAppSettings',
                    ),
                    textAlign: textAlign,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop('import_online'),
                  style: OutlinedButton.styleFrom(alignment: buttonAlignment),
                  child: Text(
                    l10n.getString('calendarSyncPermissionActionImportOnline'),
                    textAlign: textAlign,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('close'),
                  style: TextButton.styleFrom(alignment: buttonAlignment),
                  child: Text(
                    l10n.getString('calendarSyncPermissionActionClose'),
                    textAlign: textAlign,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startImportFlow(
    BuildContext context,
    WidgetRef ref,
    CalendarProvider provider,
  ) async {
    if (kIsWeb) {
      final initialCalendars = await _loadWebImportCalendars(ref, provider);
      if (provider != CalendarProvider.apple && initialCalendars == null) {
        return;
      }
      if (!context.mounted) return;
      _openCalendarSync(
        context,
        provider,
        CalendarSource.api,
        initialCalendars: initialCalendars,
      );
      return;
    }

    if (provider != CalendarProvider.device) {
      _openCalendarSync(context, provider, CalendarSource.api);
      return;
    }

    // Device calendar is Android/iOS only (device_calendar_plus has no other
    // implementation). Guard here too, not just on the button: this screen can
    // also be entered with an explicit `initialProvider`.
    if (!CalendarSyncService.isDeviceCalendarSupported) {
      if (!context.mounted) return;
      final l10n = ref.read(localizationProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('calendarSyncDeviceNotSupported')),
        ),
      );
      return;
    }

    final service = ref.read(calendarSyncServiceProvider);
    var hasCalendarPermission = false;
    try {
      hasCalendarPermission = await service.requestPermissions();
    } catch (error) {
      if (!_isCalendarPermissionError(error)) {
        hasCalendarPermission = false;
      }
    }
    if (!context.mounted) return;

    if (hasCalendarPermission) {
      _openCalendarSync(context, provider, CalendarSource.device);
      return;
    }

    final selection = await _showImportPermissionDialog(context, ref);
    if (!context.mounted) return;

    if (selection == 'open_settings') {
      await service.openCalendarPermissionSettings();
      return;
    }
    if (selection != 'import_online') {
      return;
    }

    _openOnlineProvidersScreen(context);
  }

  Future<List<ExternalCalendar>?> _loadWebImportCalendars(
    WidgetRef ref,
    CalendarProvider provider,
  ) async {
    if (!kIsWeb) return <ExternalCalendar>[];
    final service = ref.read(calendarSyncServiceProvider);
    try {
      if (provider == CalendarProvider.outlook) {
        final token = await service.signInOutlook();
        if (token == null) return null;
        return await service.retrieveOutlookCalendars();
      }
      if (provider == CalendarProvider.google) {
        return await service.retrieveCalendars();
      }
      return <ExternalCalendar>[];
    } catch (_) {
      return null;
    }
  }

  Future<void> _startOnlineProviderImportFlow(
    BuildContext context,
    WidgetRef ref,
    CalendarProvider provider,
  ) async {
    final initialCalendars = await _loadWebImportCalendars(ref, provider);
    if (provider != CalendarProvider.apple && initialCalendars == null) {
      return;
    }
    if (!context.mounted) return;
    _openCalendarSync(
      context,
      provider,
      CalendarSource.api,
      initialCalendars: initialCalendars,
    );
  }

  bool _isCalendarPermissionError(Object error) {
    final key = error.toString();
    return key == 'calendarSyncPermissionDenied' ||
        key == 'calendarSyncPermissionFailed' ||
        key == 'calendarSyncPermissionBlocked';
  }

  void _openCalendarSync(
    BuildContext context,
    CalendarProvider provider,
    CalendarSource source, {
    List<ExternalCalendar>? initialCalendars,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CalendarSyncScreen(
          initialProvider: provider,
          initialSource: source,
          initialCalendars: initialCalendars,
        ),
      ),
    );
  }

  /// Opens the new multi-account online providers screen
  /// This displays all connected accounts' events similar to device calendar import
  void _openMultiAccountOnlineProvidersScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const OnlineProvidersScreen()),
    );
  }

  void _openOnlineProvidersScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) {
          return Consumer(
            builder: (context, routeRef, _) {
              final l10n = routeRef.watch(localizationProvider);
              return Scaffold(
                appBar: AppBar(
                  title: Text(l10n.getString('eventsImportOnlineProviders')),
                ),
                body: SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildImportProviderButton(
                              label: l10n.getString('eventsImportGoogle'),
                              assetPath: 'assets/images/providers/google.png',
                              onPressed: () async {
                                await _startOnlineProviderImportFlow(
                                  context,
                                  routeRef,
                                  CalendarProvider.google,
                                );
                              },
                            ),
                            const SizedBox(height: 10),
                            _buildImportProviderButton(
                              label: l10n.getString('eventsImportOutlook'),
                              assetPath:
                                  'assets/images/providers/microsoft.png',
                              onPressed: () async {
                                await _startOnlineProviderImportFlow(
                                  context,
                                  routeRef,
                                  CalendarProvider.outlook,
                                );
                              },
                            ),
                            const SizedBox(height: 10),
                            _buildImportProviderButton(
                              label: l10n.getString('eventsImportApple'),
                              assetPath: 'assets/images/providers/apple.png',
                              onPressed: () async {
                                await _startOnlineProviderImportFlow(
                                  context,
                                  routeRef,
                                  CalendarProvider.apple,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildImportProviderButton({
    required String label,
    String? assetPath,
    IconData? iconData,
    required Future<void> Function() onPressed,
  }) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label),
          if (assetPath != null || iconData != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 20,
              height: 20,
              child: assetPath != null
                  ? Image.asset(
                      assetPath,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const SizedBox.shrink();
                      },
                    )
                  : Icon(iconData, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final eventsAsync = ref.watch(eventManagerProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final profileAsync = userId == null
        ? const AsyncValue<UserProfile?>.data(null)
        : ref.watch(profileEditProvider(userId));
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final importButtonColumns = screenWidth >= 900
        ? 3
        : (screenWidth >= 600 || isLandscape)
        ? 2
        : 1;
    final importButtonWidth =
        (screenWidth - 32 - ((importButtonColumns - 1) * 8)) /
        importButtonColumns;

    if (userId != null && profileAsync is AsyncLoading) {
      Future.microtask(
        () =>
            ref.read(profileEditProvider(userId).notifier).loadInitialProfile(),
      );
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
                      MaterialPageRoute(
                        builder: (context) => const AddEventScreen(),
                      ),
                    );
                  },
                ),
              ],
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () => ref
            .read(eventManagerProvider.notifier)
            .fetchUserEvents(forceRemote: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (profileAsync.hasValue && profileAsync.value != null)
              SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
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
                            value:
                                profileAsync.value!.sharedEventMatchingEnabled,
                            onChanged: (value) async {
                              final resolvedUserId = userId;
                              if (resolvedUserId == null) return;
                              try {
                                await ref
                                    .read(
                                      profileEditProvider(
                                        resolvedUserId,
                                      ).notifier,
                                    )
                                    .updateSharedEventMatching(value);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.getString(
                                          'settingsSharedEventMatchingUpdated',
                                        ),
                                      ),
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${l10n.getString('settingsSharedEventMatchingUpdateFailed')}: $e',
                                      ),
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  );
                                }
                              }
                            },
                            activeThumbColor: Theme.of(
                              context,
                            ).colorScheme.secondary,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.3),
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
                          Switch(
                            value: ref
                                .read(eventManagerProvider.notifier)
                                .showPastEvents,
                            onChanged: (value) async {
                              ref
                                  .read(eventManagerProvider.notifier)
                                  .setShowPastEvents(value);
                              await ref
                                  .read(eventManagerProvider.notifier)
                                  .fetchUserEvents();
                            },
                            activeThumbColor: Theme.of(
                              context,
                            ).colorScheme.secondary,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.3),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (CalendarSyncService.isDeviceCalendarSupported)
                            SizedBox(
                              width: importButtonWidth,
                              child: _buildImportProviderButton(
                                label: l10n.getString(
                                  'eventsImportDeviceCalendar',
                                ),
                                iconData: Icons.devices_outlined,
                                onPressed: () async {
                                  print(
                                    'CalendarSync EventsScreen import tap provider=device',
                                  );
                                  await _startImportFlow(
                                    context,
                                    ref,
                                    CalendarProvider.device,
                                  );
                                },
                              ),
                            ),
                          if (!kIsWeb)
                            SizedBox(
                              width: importButtonWidth,
                              child: _buildImportProviderButton(
                                label: l10n.getString(
                                  'eventsImportOnlineProviders',
                                ),
                                iconData: Icons.cloud_outlined,
                                onPressed: () async {
                                  _openMultiAccountOnlineProvidersScreen(
                                    context,
                                  );
                                },
                              ),
                            ),
                          if (kIsWeb) ...[
                            SizedBox(
                              width: importButtonWidth,
                              child: _buildImportProviderButton(
                                label: l10n.getString('eventsImportGoogle'),
                                assetPath: 'assets/images/providers/google.png',
                                onPressed: () async {
                                  print(
                                    'CalendarSync EventsScreen import tap provider=google',
                                  );
                                  final handler = onImportGoogleCalendar;
                                  if (handler != null) {
                                    handler();
                                    return;
                                  }
                                  await _startImportFlow(
                                    context,
                                    ref,
                                    CalendarProvider.google,
                                  );
                                },
                              ),
                            ),
                            SizedBox(
                              width: importButtonWidth,
                              child: _buildImportProviderButton(
                                label: l10n.getString('eventsImportOutlook'),
                                assetPath:
                                    'assets/images/providers/microsoft.png',
                                onPressed: () async {
                                  print(
                                    'CalendarSync EventsScreen import tap provider=outlook',
                                  );
                                  final handler = onImportOutlookCalendar;
                                  if (handler != null) {
                                    handler();
                                    return;
                                  }
                                  await _startImportFlow(
                                    context,
                                    ref,
                                    CalendarProvider.outlook,
                                  );
                                },
                              ),
                            ),
                            SizedBox(
                              width: importButtonWidth,
                              child: _buildImportProviderButton(
                                label: l10n.getString('eventsImportApple'),
                                assetPath: 'assets/images/providers/apple.png',
                                onPressed: () async {
                                  print(
                                    'CalendarSync EventsScreen import tap provider=apple',
                                  );
                                  final handler = onImportAppleCalendar;
                                  if (handler != null) {
                                    handler();
                                    return;
                                  }
                                  await _startImportFlow(
                                    context,
                                    ref,
                                    CalendarProvider.apple,
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ...eventsAsync.when(
              data: (events) {
                final showPast = ref
                    .read(eventManagerProvider.notifier)
                    .showPastEvents;
                final now = DateTime.now();
                final visibleEvents = showPast
                    ? events
                    : events
                          .where((event) => !event.endTime.isBefore(now))
                          .toList();

                // Text search across the fields a user would actually
                // remember: the event name, where it is, and the description.
                // Personal notes are deliberately excluded — they are private
                // to the user and not what someone is searching for.
                final normalizedQuery = ref
                    .watch(eventsSearchQueryProvider)
                    .trim()
                    .toLowerCase();
                final searchedEvents = normalizedQuery.isEmpty
                    ? visibleEvents
                    : visibleEvents.where((event) {
                        final haystack = [
                          event.eventName,
                          event.eventVenue ?? '',
                          event.description ?? '',
                        ].join(' ').toLowerCase();
                        return haystack.contains(normalizedQuery);
                      }).toList();

                if (searchedEvents.isEmpty && visibleEvents.isNotEmpty) {
                  return <Widget>[
                    SliverToBoxAdapter(child: EventsSearchField()),
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: AppEmptyState(
                        icon: Icons.search_off_rounded,
                        title: l10n.getString('eventsNoSearchResults'),
                        message: l10n.getString('eventsNoSearchResultsMessage'),
                        actionLabel: l10n.getString('generalClear'),
                        onAction: () => ref
                            .read(eventsSearchQueryProvider.notifier)
                            .clear(),
                      ),
                    ),
                  ];
                }

                if (visibleEvents.isEmpty) {
                  return <Widget>[
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        children: [
                          Expanded(
                            child: AppEmptyState(
                              icon: Icons.calendar_today_outlined,
                              title: l10n.getString('eventNoActiveEvents'),
                              message: l10n.getString('eventCreateFirst'),
                              actionLabel: l10n.getString('eventAdd'),
                              onAction: () {
                                final handler = onAddEvent;
                                if (handler != null) {
                                  handler();
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const AddEventScreen(),
                                  ),
                                );
                              },
                            ),
                          ),
                          const AdSlot(placement: AdPlacement.eventsInline),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ];
                }

                final itemCount = searchedEvents.length + 2;
                return <Widget>[
                  if (visibleEvents.isNotEmpty)
                    const SliverToBoxAdapter(child: EventsSearchField()),
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      if (index == searchedEvents.length) {
                        return const AdSlot(
                          placement: AdPlacement.eventsInline,
                        );
                      }

                      if (index == searchedEvents.length + 1) {
                        return const SizedBox(height: 32);
                      }

                      final event = searchedEvents[index];
                      return _buildEventListItem(context, ref, l10n, event);
                    }, childCount: itemCount),
                  ),
                ];
              },
              loading: () => <Widget>[
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Semantics(
                    liveRegion: true,
                    label: l10n.getString('generalLoading'),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
              ],
              error: (e, s) => <Widget>[
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppEmptyState(
                    icon: Icons.cloud_off,
                    title: l10n.getString('eventLoadErrorTitle'),
                    message: l10n.getString('eventLoadErrorMessage'),
                    actionLabel: l10n.getString('generalRetry'),
                    onAction: () => ref
                        .read(eventManagerProvider.notifier)
                        .fetchUserEvents(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'events_add_fab',
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
        tooltip: l10n.getString('eventAdd'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.add),
        label: Text(l10n.getString('eventAdd')),
      ),
    );
  }

  Widget _buildLocationRow(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            '$label:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.85),
            ),
            maxLines: 2,
            overflow: TextOverflow.visible,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            maxLines: 2,
            overflow: TextOverflow.visible,
          ),
        ),
      ],
    );
  }

  Widget _buildEventListItem(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    EventModel event,
  ) {
    final venue = event.eventVenue?.trim();
    final hasVenue = venue != null && venue.isNotEmpty;
    final showMap = hasVenue && !isVirtualMeetingLocation(venue);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
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
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AttendeesScreen(event: event),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                          textAlign: event.eventName.isRtl()
                              ? TextAlign.right
                              : TextAlign.left,
                          textDirection: event.eventName.isRtl()
                              ? ui.TextDirection.rtl
                              : ui.TextDirection.ltr,
                          maxLines: 3,
                          overflow: TextOverflow.visible,
                        ),
                        const SizedBox(height: 8),
                        _buildLocationRow(
                          context,
                          ref,
                          l10n,
                          l10n.getString('eventLocationLabel'),
                          event.eventVenue ??
                              l10n.getString('eventVenueNotSpecified'),
                        ),
                        const SizedBox(height: 4),
                        _buildEventDetailRow(
                          context,
                          l10n.getString('eventDateLabel'),
                          _formatDateOnly(event.startTime, l10n),
                        ),
                        const SizedBox(height: 4),
                        _buildEventDetailRow(
                          context,
                          l10n.getString('eventTimeLabel'),
                          formatTimeOfDateTimeWithPrefs(
                            context,
                            ref,
                            l10n,
                            event.startTime,
                          ),
                        ),
                        const SizedBox(height: 8),
                        EventAttendanceSummary(
                          attendeeCount: event.attendeeCount,
                          l10n: l10n,
                        ),
                        EventMatchedAttendees(
                          event: event,
                          l10n: l10n,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          textDirection: l10n.textDirection,
                          children: [
                            if (event.eventLink != null &&
                                event.eventLink!.isNotEmpty)
                              _buildEventCardAction(
                                context,
                                label: l10n.getString('eventViewDetails'),
                                icon: Icons.link,
                                onPressed: () => unawaited(
                                  _openEventLink(
                                    context,
                                    l10n,
                                    event.eventLink!,
                                  ),
                                ),
                              ),
                            if (showMap)
                              _buildEventCardAction(
                                context,
                                label: l10n.getString('eventOpenInMaps'),
                                icon: Icons.map_outlined,
                                onPressed: () async {
                                  final success = await openGoogleMaps(venue);
                                  if (!success && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.getString(
                                            'errorCouldNotOpenMaps',
                                          ),
                                        ),
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    );
                                  }
                                },
                              ),
                            _buildEventCardAction(
                              context,
                              label: l10n.getString('eventLeave'),
                              icon: Icons.logout_rounded,
                              isDestructive: true,
                              onPressed: () =>
                                  _confirmLeave(context, ref, l10n, event),
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

  Widget _buildEventCardAction(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool isDestructive = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = isDestructive ? colorScheme.error : colorScheme.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: foreground,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 40),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: foreground.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Future<void> _openEventLink(
    BuildContext context,
    LocalizationState l10n,
    String rawUrl,
  ) async {
    final uri = Uri.tryParse(rawUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null || (scheme != 'http' && scheme != 'https')) {
      _showEventLinkOpenFailed(context, l10n, rawUrl);
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!launched) {
      try {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (_) {}
    }
    if (!launched) {
      _showEventLinkOpenFailed(context, l10n, rawUrl);
    }
  }

  void _showEventLinkOpenFailed(
    BuildContext context,
    LocalizationState l10n,
    String rawUrl,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.getString('eventLinkOpenFailed')),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(
          label: l10n.getString('generalRetry'),
          textColor: Theme.of(context).colorScheme.onError,
          onPressed: () => unawaited(_openEventLink(context, l10n, rawUrl)),
        ),
      ),
    );
  }

  Future<void> _confirmLeave(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    EventModel event,
  ) async {
    final bool? shouldLeave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var busy = false;
        return StatefulBuilder(
          builder: (dialogStateContext, setDialogState) => AlertDialog(
            title: Text(l10n.getString('eventLeaveConfirmTitle')),
            content: Text(
              l10n.getString(
                'eventLeaveConfirmBodyWithName',
                params: {'eventName': event.eventName},
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(dialogStateContext).pop(false),
                child: Text(l10n.getString('generalCancel')),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setDialogState(() => busy = true);
                        var success = false;
                        try {
                          success = await ref
                              .read(eventManagerProvider.notifier)
                              .leaveEvent(event.id);
                        } catch (_) {}
                        if (!dialogStateContext.mounted) return;
                        Navigator.of(dialogStateContext).pop(success);
                        if (!success && context.mounted) {
                          _showLeaveFailed(context, ref, l10n, event);
                        }
                      },
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(
                    dialogStateContext,
                  ).colorScheme.error,
                ),
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('eventLeave')),
              ),
            ],
          ),
        );
      },
    );

    if (shouldLeave == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('eventLeft')),
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      );
    }
  }

  void _showLeaveFailed(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    EventModel event,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.getString('eventLeaveFailed')),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(
          label: l10n.getString('generalRetry'),
          textColor: Theme.of(context).colorScheme.onError,
          onPressed: () => unawaited(_retryLeave(context, ref, l10n, event)),
        ),
      ),
    );
  }

  Future<void> _retryLeave(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    EventModel event,
  ) async {
    var success = false;
    try {
      success = await ref
          .read(eventManagerProvider.notifier)
          .leaveEvent(event.id);
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.getString(success ? 'eventLeft' : 'eventLeaveFailed'),
        ),
        backgroundColor: success
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
    );
  }

  Widget _buildEventDetailRow(
    BuildContext context,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            '$label:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.85),
            ),
            maxLines: 2,
            overflow: TextOverflow.visible,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            maxLines: 2,
            overflow: TextOverflow.visible,
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
