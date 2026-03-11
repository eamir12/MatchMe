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
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';

enum CalendarProvider { google, outlook }

class CalendarSyncScreen extends ConsumerStatefulWidget {
  final CalendarProvider? initialProvider;

  const CalendarSyncScreen({
    super.key,
    this.initialProvider,
  });

  @override
  ConsumerState<CalendarSyncScreen> createState() => _CalendarSyncScreenState();
}

class _CalendarSyncScreenState extends ConsumerState<CalendarSyncScreen> {
  int _currentStep = 0;
  List<ExternalCalendar> _calendars = [];
  final Set<String> _selectedCalendarIds = {};
  List<ExternalEvent> _events = [];
  final Set<String> _selectedEventIds = {};
  bool _isLoading = false;
  String? _errorMessage;
  bool _hasFetched = false;
  late CalendarProvider _selectedProvider;
  Map<String, EventModel> _existingEventsMap = {};
  final Set<String> _duplicateEventIds = {};
  bool _isDuplicateCheckEnabled = true;
  List<ExternalCalendar> _allCalendars = [];
  bool _isOutlookInstalled = false;
  bool _hasCheckedOutlookInstallation = false;
  bool _useOutlookOAuthFallback = false;
  int _emptyCalendarsAutoRetryCount = 0;

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

  String _formatDateOnly(DateTime dateTime, LocalizationState l10n) {
    try {
      final curLocale = l10n.currentLocale;
      final langCode = curLocale.languageCode.toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(dateTime);
        } catch (_) {
          return DateFormat('EEEE, d MMMM y').format(dateTime);
        }
      } else {
        try {
          final localeTag = curLocale.toLanguageTag();
          final df = DateFormat('EEEE, MMMM d, y', localeTag);
          return df.format(dateTime);
        } catch (_) {
          return DateFormat('EEEE, MMMM d, y').format(dateTime);
        }
      }
    } catch (_) {
      return DateFormat('EEEE, MMMM d, yyyy').format(dateTime);
    }
  }

  Widget _buildDetailRow(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImportEventListItem(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ExternalEvent event, {
    required bool isSelected,
    required bool enabled,
    required bool isDuplicate,
  }) {
    final start = event.start;
    final title = event.title.trim().isNotEmpty ? event.title.trim() : 'No Title';
    final location = event.location?.trim();
    final hasLocation = location != null && location.isNotEmpty;
    final showMap = hasLocation && !_isVirtualMeetingLocation(location);
    final hasUrl = event.url != null;

    Widget content = Container(
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
        onTap: enabled
            ? () {
                setState(() {
                  if (isSelected) {
                    _selectedEventIds.remove(event.id);
                  } else {
                    _selectedEventIds.add(event.id);
                  }
                });
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            textDirection: l10n.textDirection,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                            textAlign: title.isRtl() ? TextAlign.right : TextAlign.left,
                            textDirection: title.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                          ),
                        ),
                        if (isDuplicate)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.getString('calendarSyncDuplicateBadge'),
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.orange.shade800,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _buildDetailRow(
                      context,
                      l10n.getString('eventLocationLabel'),
                      hasLocation ? location : l10n.getString('eventVenueNotSpecified'),
                    ),
                    const SizedBox(height: 4),
                    _buildDetailRow(
                      context,
                      l10n.getString('eventDateLabel'),
                      start != null ? _formatDateOnly(start, l10n) : l10n.getString('calendarSyncNoDate'),
                    ),
                    if (start != null && !event.isAllDay) ...[
                      const SizedBox(height: 4),
                      _buildDetailRow(
                        context,
                        l10n.getString('eventTimeLabel'),
                        formatTimeOfDateTimeWithPrefs(context, ref, l10n, start),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (hasUrl) ...[
                          Expanded(
                            child: InkWell(
                              onTap: enabled
                                  ? () async {
                                      final url = event.url;
                                      if (url == null) return;
                                      if (await canLaunchUrl(url)) {
                                        await launchUrl(url, mode: LaunchMode.externalApplication);
                                      }
                                    }
                                  : null,
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
                            onTap: enabled
                                ? () async {
                                    final success = await openGoogleMaps(location);
                                    if (!success && context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(l10n.getString('errorCouldNotOpenMaps')),
                                          backgroundColor: Colors.orange,
                                        ),
                                      );
                                    }
                                  }
                                : null,
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
                          icon: Icon(
                            isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                            color: enabled
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                          onPressed: enabled
                              ? () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedEventIds.remove(event.id);
                                    } else {
                                      _selectedEventIds.add(event.id);
                                    }
                                  });
                                }
                              : null,
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
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
        ),
      ),
    );

    if (!enabled) {
      content = Opacity(opacity: 0.55, child: content);
    }

    return content;
  }

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider ?? CalendarProvider.google;
    _loadExistingEvents();
    _checkOutlookInstallation();

    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.initialProvider == null) return;
        if (_hasFetched || _isLoading) return;
        _fetchCalendars();
      });
    } else {
      // On mobile, fetch to detect available providers
      // If a provider was explicitly selected, we can still fetch all but default to the selected one
      Future.delayed(Duration.zero, _fetchCalendars);
    }
  }

  Future<void> _loadExistingEvents() async {
    try {
      final eventsAsyncValue = ref.read(eventManagerProvider);

      // Handle AsyncValue to get the actual list
      final events = eventsAsyncValue.maybeWhen(
        data: (eventList) => eventList,
        orElse: () => <EventModel>[],
      );

      // Create a map for quick duplicate checking
      _existingEventsMap = {
        for (var event in events)
          _createEventKey(
            event.eventName,
            event.startTime,
            endTime: event.endTime,
          ): event,
      };
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: st),
      );
    }
  }

  String _createEventKey(
    String name,
    DateTime startTime, {
    DateTime? endTime,
    bool isAllDay = false,
  }) {
    var allDay = isAllDay;
    if (!allDay && endTime != null) {
      final duration = endTime.difference(startTime);
      if (startTime.hour == 0 &&
          startTime.minute == 0 &&
          duration >= const Duration(hours: 23)) {
        allDay = true;
      }
    }

    if (allDay) {
      final localDate = startTime.isUtc ? startTime.toLocal() : startTime;
      return '${name.toLowerCase().trim()}_${localDate.year}_${localDate.month}_${localDate.day}_allDay';
    }

    final utcTime = startTime.toUtc();
    return '${name.toLowerCase().trim()}_${utcTime.year}_${utcTime.month}_${utcTime.day}_${utcTime.hour}_${utcTime.minute}';
  }

  Future<void> _checkOutlookInstallation() async {
    if (!kIsWeb && !_hasCheckedOutlookInstallation) {
      try {
        final service = ref.read(calendarSyncServiceProvider);
        final isInstalled = await service.isOutlookInstalled();
        if (mounted) {
          setState(() {
            _isOutlookInstalled = isInstalled;
            _hasCheckedOutlookInstallation = true;
          });
        }
      } catch (e, st) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: e, stack: st),
        );
      }
    }
  }

  bool _isDuplicate(ExternalEvent deviceEvent) {
    if (!_isDuplicateCheckEnabled ||
        deviceEvent.start == null) {
      return false;
    }
    final key = _createEventKey(
      deviceEvent.title,
      deviceEvent.start!,
      endTime: deviceEvent.end,
      isAllDay: deviceEvent.isAllDay,
    );
    return _existingEventsMap.containsKey(key);
  }

  void _checkForDuplicates() {
    _duplicateEventIds.clear();
    for (final event in _events) {
      if (event.id.isNotEmpty && _isDuplicate(event)) {
        _duplicateEventIds.add(event.id);
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _fetchCalendars() async {
    if (_isLoading) return; // Prevent concurrent fetches

    if (kIsWeb) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final service = ref.read(calendarSyncServiceProvider);
      List<ExternalCalendar> calendars;

      if (kIsWeb) {
        // On web, always use OAuth API methods
        calendars =
            _selectedProvider == CalendarProvider.outlook
                ? await service.retrieveOutlookCalendars()
                : await service.retrieveCalendars();
      } else {
        // On mobile/desktop, retrieve all device calendars
        // Always refresh to pick up newly synced calendars from Outlook/Google
        _allCalendars = await service.retrieveCalendars();

        // Filter device calendars based on selected provider
        if (_selectedProvider == CalendarProvider.outlook) {
          calendars =
              _allCalendars.where((calendar) {
                final accountType = calendar.accountType?.toLowerCase() ?? '';
                final accountName = calendar.accountName?.toLowerCase() ?? '';
                final name = calendar.name.toLowerCase();
                // Broader detection: check account type, account name, and calendar name
                final isOutlook =
                    accountType.contains('outlook') ||
                    accountType.contains('exchange') ||
                    accountType.contains('office') ||
                    accountType.contains('microsoft') ||
                    accountType.contains('hotmail') ||
                    accountType.contains('live') ||
                    accountType.contains('com.microsoft') ||
                    accountName.contains('outlook') ||
                    accountName.contains('exchange') ||
                    accountName.contains('office') ||
                    accountName.contains('hotmail') ||
                    accountName.contains('live') ||
                    accountName.contains('microsoft') ||
                    name.contains('outlook') ||
                    name.contains('office');
                return isOutlook;
              }).toList();
        } else {
          calendars =
              _allCalendars.where((calendar) {
                final accountType = calendar.accountType?.toLowerCase() ?? '';
                final accountName = calendar.accountName?.toLowerCase() ?? '';
                return accountType.contains('google') ||
                    accountType.contains('gmail') ||
                    accountName.contains('google') ||
                    accountName.contains('gmail');
              }).toList();
        }
      }

      // Filter out holiday and special calendars
      final nonHolidayCalendars =
          calendars.where((c) => !_isHolidayOrSpecialCalendar(c)).toList();

      // Try to find primary calendars
      final primaryCalendars =
          nonHolidayCalendars.where((c) => _isPrimaryCalendar(c)).toList();

      if (primaryCalendars.isNotEmpty) {
        calendars = primaryCalendars;
      } else if (nonHolidayCalendars.isNotEmpty) {
        // Fallback: If no primary calendar is explicitly detected,
        // assume the first non-holiday calendar is the main one.
        // This ensures we don't show an empty list when a valid calendar exists.
        calendars = [nonHolidayCalendars.first];
      } else {
        calendars = [];
      }

      setState(() {
        _calendars = calendars;
        _isLoading = false;
        _hasFetched = true;
        _useOutlookOAuthFallback = false;
      });

      if (!kIsWeb && calendars.isEmpty && _emptyCalendarsAutoRetryCount < 2) {
        _emptyCalendarsAutoRetryCount++;
        unawaited(
          Future.delayed(const Duration(milliseconds: 800), () async {
            if (!mounted) return;
            if (_isLoading) return;
            if (_calendars.isNotEmpty) return;
            await _fetchCalendars();
          }),
        );
      }

      if (widget.initialProvider != null &&
          _currentStep == 0 &&
          _selectedCalendarIds.isEmpty) {
        final ids =
            calendars.map((c) => c.id).where((id) => id.isNotEmpty).toList();
        if (ids.isNotEmpty) {
          setState(() {
            _selectedCalendarIds
              ..clear()
              ..addAll(ids);
          });
          await _fetchEvents();
        }
      }
    } on CalendarSyncException catch (e) {
      setState(() {
        // e.toString() now returns a translation key
        _errorMessage = e.toString();
        _isLoading = false;
        _hasFetched = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'calendarSyncFailedLoadCalendars';
        _isLoading = false;
        _hasFetched = true;
      });
    }
  }

  Future<void> _fetchEvents() async {
    if (_isLoading) return; // Prevent concurrent fetches

    if (kIsWeb) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Reload existing events to ensure we have the latest data
      await _loadExistingEvents();

      final service = ref.read(calendarSyncServiceProvider);
      final allEvents = <ExternalEvent>[];

      for (final calendarId in _selectedCalendarIds) {
        final events =
            (kIsWeb || _useOutlookOAuthFallback) &&
                    _selectedProvider == CalendarProvider.outlook
                ? await service.retrieveOutlookEvents(
                  calendarId,
                  startDate: DateTime.now(),
                  endDate: DateTime.now().add(const Duration(days: 30)),
                  allowNonWeb: _useOutlookOAuthFallback,
                )
                : await service.retrieveEvents(
                  calendarId,
                  startDate: DateTime.now(),
                  endDate: DateTime.now().add(const Duration(days: 30)),
                );
        allEvents.addAll(events);
      }

      final newEvents =
          allEvents.where((event) => !_isDuplicate(event)).toList();

      // Sort by date
      newEvents.sort((a, b) {
        final startA = a.start ?? DateTime.now();
        final startB = b.start ?? DateTime.now();
        return startA.compareTo(startB);
      });

      setState(() {
        _events = newEvents;
        _isLoading = false;
        _currentStep = 1;
      });

      // Check for duplicates after fetching events (should be none now)
      _checkForDuplicates();
      setState(() {}); // Refresh UI with duplicate info
    } on CalendarSyncException catch (e) {
      setState(() {
        // e.toString() now returns a translation key
        _errorMessage = e.toString();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'calendarSyncFailedLoadEvents';
        _isLoading = false;
      });
    }
  }

  bool _isHolidayOrSpecialCalendar(ExternalCalendar calendar) {
    final name = calendar.name.toLowerCase();
    return name.contains('holiday') ||
        name.contains('observance') ||
        name.contains('birthday') ||
        name.contains('phases of the moon') ||
        name.contains('week numbers');
  }

  bool _isPrimaryCalendar(ExternalCalendar calendar) {
    final name = calendar.name.toLowerCase();
    final accountName = (calendar.accountName ?? '').toLowerCase();
    // Include calendars that match account name or are explicitly primary
    return calendar.isDefault ||
        name == accountName ||
        name.contains('primary') ||
        name == 'calendar';
  }



  Future<void> _syncSelectedEvents() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final l10n = ref.read(localizationProvider);
      final eventsToSync =
          _events
              .where((e) => _selectedEventIds.contains(e.id))
              .where(
                (e) =>
                    !_duplicateEventIds.contains(e.id) ||
                    !_isDuplicateCheckEnabled,
              )
              .toList();

      if (eventsToSync.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.getString('calendarSyncNoEventsToSync'))),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      final eventManager = ref.read(eventManagerProvider.notifier);
      int successCount = 0;
      int skippedCount = 0;
      final Map<String, List<String>> failedByReasonKey = <String, List<String>>{};

      String joinTitles(List<String> titles) {
        final cleaned =
            titles
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList();
        if (cleaned.isEmpty) {
          return l10n.getString('calendarSyncUnknownEventTitle');
        }
        if (cleaned.length == 1) return cleaned.first;
        if (cleaned.length == 2) {
          final andWord = l10n.getString('calendarSyncListAnd');
          return '${cleaned[0]} $andWord ${cleaned[1]}';
        }
        final andWord = l10n.getString('calendarSyncListAnd');
        final head = cleaned.sublist(0, cleaned.length - 1).join(', ');
        final last = cleaned.last;
        return '$head, $andWord $last';
      }

      for (final deviceEvent in eventsToSync) {
        if (deviceEvent.start == null ||
            deviceEvent.end == null) {
          skippedCount++;
          failedByReasonKey
              .putIfAbsent('calendarSyncSkipReasonMissingDate', () => <String>[])
              .add(deviceEvent.title);
          continue;
        }

        final newEvent = EventModel(
          id: '', // ID will be generated by backend/provider
          eventName: deviceEvent.title,
          eventVenue: deviceEvent.location,
          startTime: deviceEvent.start!,
          endTime: deviceEvent.end!,
          notes: null,
          eventLink: deviceEvent.url?.toString(),
        );

        final result = await eventManager.addEventWithResult(newEvent);
        if (result.success) {
          successCount++;
        } else {
          skippedCount++;
          final reasonKey = result.errorKey ?? 'eventAddFailedUnknown';
          failedByReasonKey
              .putIfAbsent(reasonKey, () => <String>[])
              .add(deviceEvent.title);
        }
      }

      if (mounted) {
        if (failedByReasonKey.isNotEmpty) {
          final failureLines =
              failedByReasonKey.entries.map((entry) {
                final titles = joinTitles(entry.value);
                final reason = l10n.getString(entry.key);
                return l10n.getString(
                  'calendarSyncEventImportFailed',
                  params: {'title': titles, 'reason': reason},
                );
              }).toList();

          final failuresText = failureLines.join('\n');
          final message =
              successCount > 0
                  ? '${l10n.getString(
                    'calendarSyncSyncedEventsSuccessWithSkipped',
                    params: {
                      'count': '$successCount',
                      'skipped': '$skippedCount',
                    },
                  )}\n$failuresText'
                  : failuresText;

          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          return;
        }

        setState(() => _isLoading = false);
        final message = l10n.getString(
          'calendarSyncSyncedEventsSuccess',
          params: {'count': '$successCount'},
        );
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'calendarSyncFailedSyncEvents';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('calendarSyncTitle')),
        leading:
            _currentStep == 1
                ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
                )
                : null,
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        // Resolve translation key from error message
                        l10n.getString(_errorMessage!),
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  Expanded(
                    child:
                        _currentStep == 0
                            ? _buildCalendarList(l10n)
                            : _buildEventList(l10n),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed:
                            _currentStep == 0
                                ? (_selectedCalendarIds.isNotEmpty
                                    ? _fetchEvents
                                    : null)
                                : (_selectedEventIds.isNotEmpty
                                    ? _syncSelectedEvents
                                    : null),
                        child: Text(
                          _currentStep == 0
                              ? l10n.getString('calendarSyncNext')
                              : l10n.getString('calendarSyncSyncSelected'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
    );
  }

  Widget _buildCalendarList(dynamic l10n) {
    // Get user gender for gender-aware messages
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final userProfile = userId != null ? ref.watch(userProfileProvider(userId)).asData?.value : null;
    final userGender = userProfile?.gender;
    
    if (kIsWeb && widget.initialProvider != null && !_hasFetched) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasFetched) {
      if (kIsWeb) {
        // For web, we already handled the signed-in case above
        // This remaining case should not happen, but keep as fallback
        return Center(
          child: ElevatedButton(
            onPressed: _fetchCalendars,
            child: Text(
              _selectedProvider == CalendarProvider.outlook
                  ? l10n.getString('calendarSyncLoadOutlookCalendars')
                  : l10n.getString('calendarSyncLoadCalendars'),
            ),
          ),
        );
      } else {
        // Mobile initial state
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _selectedProvider == CalendarProvider.outlook ? Icons.mail_outline : Icons.calendar_month,
                size: 64, 
                color: Colors.blue
              ),
              const SizedBox(height: 24),
              Text(
                l10n.getString('calendarSyncConnectMessage'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 32),
              if (_selectedProvider == CalendarProvider.google)
                ElevatedButton.icon(
                  onPressed: () async {
                    await _fetchCalendars();
                  },
                  icon: const Icon(Icons.g_mobiledata, size: 32),
                  label: Text(l10n.getString('calendarSyncConnectGoogle')),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
              if (_selectedProvider == CalendarProvider.outlook)
                OutlinedButton.icon(
                  onPressed: () async {
                    await _fetchCalendars();
                  },
                  icon: const Icon(Icons.mail_outline),
                  label: Text(l10n.getString('calendarSyncConnectOutlook')),
                ),
            ],
          ),
        );
      }
    }

    if (_calendars.isEmpty) {
      // Show provider-specific messages for no calendars found
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _selectedProvider == CalendarProvider.outlook
                      ? Icons.mail_outline
                      : Icons.calendar_today,
                  size: 64,
                  color: Colors.grey,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.getString('calendarSyncNoCalendarsFound'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _selectedProvider == CalendarProvider.outlook
                      ? (kIsWeb
                          ? l10n.getString('calendarSyncNoCalendarsOutlook', gender: userGender)
                          : (_isOutlookInstalled
                              ? l10n.getString('calendarSyncOutlookDetected', gender: userGender)
                              : l10n.getString('calendarSyncNoOutlookOnDevice', gender: userGender)))
                      : l10n.getString('calendarSyncNoCalendarsGoogle', gender: userGender),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _isOutlookInstalled && !kIsWeb && _selectedProvider == CalendarProvider.outlook
                        ? Colors.orange
                        : Colors.grey,
                    fontWeight: _isOutlookInstalled && !kIsWeb && _selectedProvider == CalendarProvider.outlook
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                ),
                // Show additional guidance for Outlook on mobile when app is installed
                if (!kIsWeb &&
                    _selectedProvider == CalendarProvider.outlook &&
                    _isOutlookInstalled)
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0),
                    child: Column(
                      children: [
                        Text(
                          l10n.getString('calendarSyncOpenOutlookGuidance', gender: userGender),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.getString('calendarSyncWaitForSync', gender: userGender),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () async {
                            final service = ref.read(
                              calendarSyncServiceProvider,
                            );
                            await service.openOutlookSettings();
                          },
                          icon: const Icon(Icons.settings),
                          label: Text(
                            l10n.getString('calendarSyncOpenOutlookSettings'),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _fetchCalendars,
                  child: Text(l10n.getString('calendarSyncRetry')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _calendars.length,
            itemBuilder: (context, index) {
              final calendar = _calendars[index];
              final isSelected = _selectedCalendarIds.contains(calendar.id);

              return CheckboxListTile(
                title: Text(
                  calendar.accountName ?? calendar.name,
                ),
                subtitle:
                    calendar.accountName != null &&
                            calendar.name != calendar.accountName
                        ? Text(calendar.name)
                        : null,
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedCalendarIds.add(calendar.id);
                    } else {
                      _selectedCalendarIds.remove(calendar.id);
                    }
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEventList(dynamic l10n) {
    if (_events.isEmpty) {
      return Center(child: Text(l10n.getString('eventsNoUpcomingFound')));
    }

    final duplicateCount = _duplicateEventIds.length;
    final selectedDuplicates =
        _selectedEventIds.intersection(_duplicateEventIds).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_selectedEventIds.length == _events.length) {
                      _selectedEventIds.clear();
                    } else {
                      _selectedEventIds.addAll(
                        _events
                            .map((e) => e.id)
                            .where((id) => id.isNotEmpty),
                      );
                    }
                  });
                },
                child: Text(
                  _selectedEventIds.length == _events.length
                      ? l10n.getString('calendarSyncDeselectAll')
                      : l10n.getString('calendarSyncSelectAll'),
                ),
              ),
            ],
          ),
        ),
        if (duplicateCount > 0)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              border: Border.all(color: Colors.orange.shade200),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.orange.shade700),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.getString(
                          'calendarSyncDuplicateEventsFound',
                          params: {'count': '$duplicateCount'},
                        ),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                      if (selectedDuplicates > 0)
                        Text(
                          l10n.getString(
                            'calendarSyncDuplicateSelectedWillSkip',
                            params: {'count': '$selectedDuplicates'},
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade700,
                          ),
                        ),
                    ],
                  ),
                ),
                Switch(
                  value: _isDuplicateCheckEnabled,
                  onChanged: (value) {
                    setState(() {
                      _isDuplicateCheckEnabled = value;
                      if (!value) {
                        _duplicateEventIds.clear();
                      } else {
                        _checkForDuplicates();
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _events.length,
            itemBuilder: (context, index) {
              final event = _events[index];
              final isSelected = _selectedEventIds.contains(event.id);
              final isDuplicate = _duplicateEventIds.contains(event.id);
              final enabled = !isDuplicate || !_isDuplicateCheckEnabled;

              return _buildImportEventListItem(
                context,
                ref,
                l10n,
                event,
                isSelected: isSelected,
                enabled: enabled,
                isDuplicate: isDuplicate,
              );
            },
          ),
        ),
      ],
    );
  }
}
