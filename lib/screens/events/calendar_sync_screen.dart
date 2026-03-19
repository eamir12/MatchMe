import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:developer' as developer;
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';

enum CalendarProvider { google, outlook, apple, device }

enum CalendarSource { device, api }

class CalendarSyncScreen extends ConsumerStatefulWidget {
  final CalendarProvider? initialProvider;
  final CalendarSource? initialSource;
  final List<ExternalCalendar>? initialCalendars;

  const CalendarSyncScreen({
    super.key,
    this.initialProvider,
    this.initialSource,
    this.initialCalendars,
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
  bool _isUsingPermissionFallbackOnline = false;
  int _emptyCalendarsAutoRetryCount = 0;
  late CalendarSource _selectedSource;
  final TextEditingController _applePublicCalendarUrlController =
      TextEditingController();
  static const String _applePublicCalendarUrlPrefKey =
      'calendar_sync_apple_public_url';
  static final Uri _applePublicCalendarHelpUriEn = Uri.parse(
    'https://support.apple.com/en-us/guide/icloud/share-a-calendar-mm6b1a9479/icloud',
  );
  static final Uri _applePublicCalendarHelpUriEs = Uri.parse(
    'https://support.apple.com/es-es/guide/icloud/share-a-calendar-mm6b1a9479/icloud',
  );

  void _trace(String message) {
    debugPrint(message);
    developer.log(message, name: 'CalendarSyncScreen');
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
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.85),
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
    final title = event.title.trim().isNotEmpty
        ? event.title.trim()
        : 'No Title';
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
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                            textAlign: title.isRtl()
                                ? TextAlign.right
                                : TextAlign.left,
                            textDirection: title.isRtl()
                                ? ui.TextDirection.rtl
                                : ui.TextDirection.ltr,
                          ),
                        ),
                        if (isDuplicate)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
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
                      hasLocation
                          ? location
                          : l10n.getString('eventVenueNotSpecified'),
                    ),
                    const SizedBox(height: 4),
                    _buildDetailRow(
                      context,
                      l10n.getString('eventDateLabel'),
                      start != null
                          ? _formatDateOnly(start, l10n)
                          : l10n.getString('calendarSyncNoDate'),
                    ),
                    if (start != null && !event.isAllDay) ...[
                      const SizedBox(height: 4),
                      _buildDetailRow(
                        context,
                        l10n.getString('eventTimeLabel'),
                        formatTimeOfDateTimeWithPrefs(
                          context,
                          ref,
                          l10n,
                          start,
                        ),
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
                                        await launchUrl(
                                          url,
                                          mode: LaunchMode.externalApplication,
                                        );
                                      }
                                    }
                                  : null,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.link,
                                    size: 14,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      l10n.getString('eventViewDetails'),
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
                                    final success = await openGoogleMaps(
                                      location,
                                    );
                                    if (!success && context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.getString(
                                              'errorCouldNotOpenMaps',
                                            ),
                                          ),
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.5),
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
                            isSelected
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            color: enabled
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.4),
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
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1),
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

  List<ExternalCalendar> _prepareInitialCalendars(
    List<ExternalCalendar> calendars,
  ) {
    var filtered = calendars
        .where((calendar) => !_isHolidayOrSpecialCalendar(calendar))
        .toList();
    if (filtered.isNotEmpty) {
      filtered.sort((a, b) {
        if (a.isDefault == b.isDefault) return 0;
        return a.isDefault ? -1 : 1;
      });
    } else {
      filtered = <ExternalCalendar>[];
    }
    final isOnlineImport = kIsWeb || _selectedSource == CalendarSource.api;
    if (isOnlineImport && filtered.isNotEmpty) {
      ExternalCalendar mainCalendar = filtered.first;
      for (final calendar in filtered) {
        if (calendar.isDefault) {
          mainCalendar = calendar;
          break;
        }
      }
      return [mainCalendar];
    }
    return filtered;
  }

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider ?? CalendarProvider.google;
    _selectedSource =
        widget.initialSource ??
        (kIsWeb || _selectedProvider == CalendarProvider.apple
            ? CalendarSource.api
            : CalendarSource.device);
    _trace(
      'CalendarSyncScreen initState initialProvider=${widget.initialProvider} selectedProvider=$_selectedProvider selectedSource=$_selectedSource',
    );
    _loadSavedApplePublicCalendarUrl();
    _loadExistingEvents();
    _checkOutlookInstallation();

    final initialCalendars = widget.initialCalendars;
    if (kIsWeb && initialCalendars != null) {
      final preparedCalendars = _prepareInitialCalendars(initialCalendars);
      _calendars = preparedCalendars;
      _hasFetched =
          preparedCalendars.isNotEmpty ||
          _selectedProvider != CalendarProvider.apple;
      if (widget.initialProvider != null && preparedCalendars.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          if (_isLoading || _currentStep != 0 || _selectedCalendarIds.isNotEmpty) {
            return;
          }
          final ids = preparedCalendars
              .map((calendar) => calendar.id)
              .where((id) => id.isNotEmpty)
              .toList();
          if (ids.isEmpty) return;
          setState(() {
            _selectedCalendarIds
              ..clear()
              ..addAll(ids);
          });
          await _fetchEvents();
        });
      }
      return;
    }

    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.initialProvider == null) return;
        if (_hasFetched || _isLoading) return;
        _fetchCalendars();
      });
    } else {
      final shouldAutoFetch =
          !(_selectedProvider == CalendarProvider.apple &&
              _selectedSource == CalendarSource.api);
      if (shouldAutoFetch) {
        Future.delayed(Duration.zero, _fetchCalendars);
      }
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
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
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
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
      }
    }
  }

  bool _isDuplicate(ExternalEvent deviceEvent) {
    if (!_isDuplicateCheckEnabled || deviceEvent.start == null) {
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
    _applePublicCalendarUrlController.dispose();
    super.dispose();
  }

  Future<List<ExternalCalendar>> _loadOnlineCalendars(
    CalendarSyncService service,
  ) async {
    if (_selectedProvider == CalendarProvider.device) {
      return <ExternalCalendar>[];
    }
    if (_selectedProvider == CalendarProvider.outlook) {
      return service.retrieveOutlookCalendarsNonWebOAuth();
    }
    if (_selectedProvider == CalendarProvider.google) {
      return service.retrieveGoogleCalendarsNonWebOAuth();
    }
    return service.retrieveApplePublicCalendars(
      _applePublicCalendarUrlController.text,
    );
  }

  Future<void> _loadSavedApplePublicCalendarUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_applePublicCalendarUrlPrefKey)?.trim();
      if (!mounted || savedUrl == null || savedUrl.isEmpty) return;
      if (_applePublicCalendarUrlController.text.trim().isNotEmpty) return;
      _applePublicCalendarUrlController.text = savedUrl;
    } catch (_) {}
  }

  Future<void> _saveApplePublicCalendarUrlIfAny() async {
    final url = _applePublicCalendarUrlController.text.trim();
    if (url.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_applePublicCalendarUrlPrefKey, url);
    } catch (_) {}
  }

  bool _isCalendarPermissionError(CalendarSyncException error) {
    final key = error.toString();
    return key == 'calendarSyncPermissionDenied' ||
        key == 'calendarSyncPermissionFailed' ||
        key == 'calendarSyncPermissionBlocked';
  }

  bool _isGoogleAuthError(CalendarSyncException error) {
    final key = error.toString();
    return key == 'calendarSyncGoogleAuthRequired' || error.isAuthError;
  }

  bool _shouldKeepAppleOnlineFormState(String errorKey) {
    final isAppleOnlineImport =
        _selectedProvider == CalendarProvider.apple &&
        (_selectedSource == CalendarSource.api || kIsWeb);
    if (!isAppleOnlineImport) return false;
    return errorKey == 'calendarSyncApplePublicUrlRequired' ||
        errorKey == 'calendarSyncApplePublicUrlInvalid';
  }

  Future<bool> _promptBlockedCalendarPermissionSettings() async {
    if (!mounted) return true;
    final l10n = ref.read(localizationProvider);
    final settingsGuideKey = switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        'calendarSyncPermissionBlockedSettingsGuideAndroid',
      TargetPlatform.iOS => 'calendarSyncPermissionBlockedSettingsGuideIos',
      _ => 'calendarSyncPermissionBlockedSettingsGuide',
    };
    final selection = await showDialog<String>(
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
    if (selection == 'open_settings') {
      final service = ref.read(calendarSyncServiceProvider);
      await service.openCalendarPermissionSettings();
      return false;
    }
    if (selection == 'import_online') {
      return true;
    }
    return false;
  }

  Future<bool> _handleGoogleAuthError() async {
    if (!mounted) return true;
    final l10n = ref.read(localizationProvider);

    final signInSelected = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.getString('calendarSyncGoogleAuthRequired')),
          content: Text(
            l10n.getString('calendarSyncGoogleAuthRequiredMessage'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.getString('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.getString('signIn')),
            ),
          ],
        );
      },
    );

    if (signInSelected == true) {
      // The Google sign-in will be triggered automatically when we retry
      // the calendar retrieval with allowInteractive=true
      return true;
    }

    return false;
  }

  Future<bool> _handleBlockedCalendarPermission() async {
    _trace(
      'CalendarSyncScreen blocked permission, showing guidance before settings',
    );
    return await _promptBlockedCalendarPermissionSettings();
  }

  Future<void> _fetchCalendars() async {
    if (_isLoading) {
      _trace('CalendarSyncScreen fetchCalendars skipped isLoading=true');
      return;
    }
    _trace(
      'CalendarSyncScreen fetchCalendars start provider=$_selectedProvider source=$_selectedSource',
    );

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
      var usedPermissionFallbackOnline = false;
      var useApplePublicCalendarOnline = false;

      if (kIsWeb) {
        if (_selectedProvider == CalendarProvider.outlook) {
          calendars = await service.retrieveOutlookCalendars();
        } else if (_selectedProvider == CalendarProvider.google) {
          calendars = await service.retrieveCalendars();
        } else if (_selectedProvider == CalendarProvider.device) {
          calendars = <ExternalCalendar>[];
        } else {
          calendars = await _loadOnlineCalendars(service);
        }
      } else {
        useApplePublicCalendarOnline =
            _selectedProvider == CalendarProvider.apple &&
            _applePublicCalendarUrlController.text.trim().isNotEmpty;
        if (useApplePublicCalendarOnline) {
          await _saveApplePublicCalendarUrlIfAny();
        }
        if (_selectedSource == CalendarSource.api ||
            useApplePublicCalendarOnline) {
          calendars = await _loadOnlineCalendars(service);
        } else {
          try {
            await service.requestPermissions();
            _allCalendars = await service.retrieveCalendars();
            _trace(
              'CalendarSync device calendars total=${_allCalendars.length} provider=$_selectedProvider source=$_selectedSource',
            );
            for (final c in _allCalendars) {
              _trace(
                'CalendarSync device calendar id=${c.id} name=${c.name} accountName=${c.accountName ?? ''} accountType=${c.accountType ?? ''} isDefault=${c.isDefault}',
              );
            }

            if (_selectedProvider == CalendarProvider.device) {
              calendars = _allCalendars;
            } else if (_selectedProvider == CalendarProvider.outlook) {
              calendars = _allCalendars.where((calendar) {
                final accountType = calendar.accountType?.toLowerCase() ?? '';
                final accountName = calendar.accountName?.toLowerCase() ?? '';
                final name = calendar.name.toLowerCase();
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
            } else if (_selectedProvider == CalendarProvider.google) {
              calendars = _allCalendars.where((calendar) {
                final accountType = calendar.accountType?.toLowerCase() ?? '';
                final accountName = calendar.accountName?.toLowerCase() ?? '';
                return accountType.contains('google') ||
                    accountType.contains('gmail') ||
                    accountName.contains('google') ||
                    accountName.contains('gmail');
              }).toList();
            } else {
              calendars = _allCalendars.where((calendar) {
                final accountType = calendar.accountType?.toLowerCase() ?? '';
                final accountName = calendar.accountName?.toLowerCase() ?? '';
                final name = calendar.name.toLowerCase();
                return accountType.contains('icloud') ||
                    accountType.contains('caldav') ||
                    accountType.contains('apple') ||
                    accountType.contains('mac') ||
                    accountName.contains('icloud') ||
                    accountName.contains('apple') ||
                    accountName.contains('me.com') ||
                    accountName.contains('icloud.com') ||
                    name.contains('icloud') ||
                    name.contains('apple');
              }).toList();
            }

            if (calendars.isEmpty &&
                (_selectedProvider == CalendarProvider.google ||
                    _selectedProvider == CalendarProvider.outlook)) {
              calendars = _allCalendars;
            }
          } on CalendarSyncException catch (e) {
            if (!_isCalendarPermissionError(e)) {
              rethrow;
            }
            if (e.toString() == 'calendarSyncPermissionBlocked') {
              final shouldFallbackOnline =
                  await _handleBlockedCalendarPermission();
              if (!shouldFallbackOnline) {
                if (!mounted) return;
                setState(() {
                  _isLoading = false;
                });
                return;
              }
            }
            if (_selectedProvider == CalendarProvider.device) {
              rethrow;
            }
            _trace(
              'CalendarSyncScreen permission denied, switching to online provider=$_selectedProvider',
            );
            try {
              calendars = await _loadOnlineCalendars(service);
              usedPermissionFallbackOnline = true;
            } on CalendarSyncException catch (e) {
              if (_selectedProvider == CalendarProvider.google &&
                  _isGoogleAuthError(e)) {
                final shouldRetry = await _handleGoogleAuthError();
                if (shouldRetry && mounted) {
                  try {
                    calendars = await _loadOnlineCalendars(service);
                    usedPermissionFallbackOnline = true;
                  } catch (retryError) {
                    _trace('CalendarSyncScreen retry failed: $retryError');
                    rethrow;
                  }
                } else {
                  rethrow;
                }
              } else {
                rethrow;
              }
            }
          }
        }
      }

      // Filter out holiday and special calendars
      final nonHolidayCalendars = calendars
          .where((c) => !_isHolidayOrSpecialCalendar(c))
          .toList();
      if (nonHolidayCalendars.isNotEmpty) {
        nonHolidayCalendars.sort((a, b) {
          if (a.isDefault == b.isDefault) return 0;
          return a.isDefault ? -1 : 1;
        });
        calendars = nonHolidayCalendars;
      } else {
        calendars = [];
      }

      final isOnlineImport =
          kIsWeb ||
          _selectedSource == CalendarSource.api ||
          usedPermissionFallbackOnline ||
          useApplePublicCalendarOnline;
      if (isOnlineImport && calendars.isNotEmpty) {
        ExternalCalendar mainCalendar = calendars.first;
        for (final calendar in calendars) {
          if (calendar.isDefault) {
            mainCalendar = calendar;
            break;
          }
        }
        calendars = [mainCalendar];
      }

      _trace(
        'CalendarSync filtered calendars count=${calendars.length} provider=$_selectedProvider source=$_selectedSource',
      );

      setState(() {
        _calendars = calendars;
        _isLoading = false;
        _hasFetched = true;
        _useOutlookOAuthFallback = false;
        _isUsingPermissionFallbackOnline = usedPermissionFallbackOnline;
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
        final ids = calendars
            .map((c) => c.id)
            .where((id) => id.isNotEmpty)
            .toList();
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
      _trace(
        'CalendarSyncScreen fetchCalendars CalendarSyncException=${e.message}',
      );
      final errorKey = e.toString();
      final keepAppleOnlineFormState = _shouldKeepAppleOnlineFormState(errorKey);
      setState(() {
        _errorMessage = errorKey;
        _isLoading = false;
        _hasFetched = !keepAppleOnlineFormState;
        if (keepAppleOnlineFormState) {
          _calendars = <ExternalCalendar>[];
          _selectedCalendarIds.clear();
        }
      });
    } catch (e) {
      _trace('CalendarSyncScreen fetchCalendars error=$e');
      setState(() {
        _errorMessage = 'calendarSyncFailedLoadCalendars';
        _isLoading = false;
        _hasFetched = true;
      });
    }
  }

  Future<void> _fetchEvents() async {
    if (_isLoading) {
      _trace('CalendarSyncScreen fetchEvents skipped isLoading=true');
      return;
    }
    _trace(
      'CalendarSyncScreen fetchEvents start provider=$_selectedProvider source=$_selectedSource selectedCalendars=${_selectedCalendarIds.length}',
    );

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
      final now = DateTime.now();
      final startDate = now.subtract(const Duration(days: 7));
      final endDate = now.add(const Duration(days: 90));
      final fallbackStartDate = now.subtract(const Duration(days: 365));
      final fallbackEndDate = now.add(const Duration(days: 365));

      for (final calendarId in _selectedCalendarIds) {
        final useOnlineApi =
            kIsWeb ||
            _selectedSource == CalendarSource.api ||
            (_selectedProvider == CalendarProvider.apple &&
                _applePublicCalendarUrlController.text.trim().isNotEmpty) ||
            _isUsingPermissionFallbackOnline;
        var events =
            useOnlineApi && _selectedProvider == CalendarProvider.outlook
            ? await service.retrieveOutlookEvents(
                calendarId,
                startDate: startDate,
                endDate: endDate,
                allowNonWeb: !kIsWeb || _useOutlookOAuthFallback,
              )
            : useOnlineApi && _selectedProvider == CalendarProvider.google
            ? await service.retrieveGoogleEventsNonWebOAuth(
                calendarId,
                startDate: startDate,
                endDate: endDate,
              )
            : useOnlineApi && _selectedProvider == CalendarProvider.apple
            ? await service.retrieveApplePublicEvents(
                calendarId,
                startDate: startDate,
                endDate: endDate,
              )
            : await service.retrieveEvents(
                calendarId,
                startDate: startDate,
                endDate: endDate,
              );
        if (!useOnlineApi && events.isEmpty) {
          _trace(
            'CalendarSync fallback event window calendarId=$calendarId provider=$_selectedProvider source=$_selectedSource',
          );
          events = await service.retrieveEvents(
            calendarId,
            startDate: fallbackStartDate,
            endDate: fallbackEndDate,
          );
        }
        _trace(
          'CalendarSync fetched events calendarId=$calendarId count=${events.length} provider=$_selectedProvider source=$_selectedSource online=$useOnlineApi',
        );
        allEvents.addAll(events);
      }

      final newEvents = allEvents.where((event) {
        final start = event.start;
        if (start == null || start.isBefore(now)) return false;
        return !_isDuplicate(event);
      }).toList();

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
      _trace(
        'CalendarSync total events imported=${newEvents.length} selectedCalendars=${_selectedCalendarIds.length}',
      );

      // Check for duplicates after fetching events (should be none now)
      _checkForDuplicates();
      setState(() {}); // Refresh UI with duplicate info
    } on CalendarSyncException catch (e) {
      _trace(
        'CalendarSyncScreen fetchEvents CalendarSyncException=${e.message}',
      );
      setState(() {
        // e.toString() now returns a translation key
        _errorMessage = e.toString();
        _isLoading = false;
      });
    } catch (e) {
      _trace('CalendarSyncScreen fetchEvents error=$e');
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

  Future<void> _syncSelectedEvents() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final l10n = ref.read(localizationProvider);
      final eventsToSync = _events
          .where((e) => _selectedEventIds.contains(e.id))
          .where(
            (e) =>
                !_duplicateEventIds.contains(e.id) || !_isDuplicateCheckEnabled,
          )
          .toList();

      if (eventsToSync.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.getString('calendarSyncNoEventsToSync')),
            ),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      final eventManager = ref.read(eventManagerProvider.notifier);
      int successCount = 0;
      int skippedCount = 0;
      final Map<String, List<String>> failedByReasonKey =
          <String, List<String>>{};

      String joinTitles(List<String> titles) {
        final cleaned = titles
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
        if (deviceEvent.start == null || deviceEvent.end == null) {
          skippedCount++;
          failedByReasonKey
              .putIfAbsent(
                'calendarSyncSkipReasonMissingDate',
                () => <String>[],
              )
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
          final failureLines = failedByReasonKey.entries.map((entry) {
            final titles = joinTitles(entry.value);
            final reason = l10n.getString(entry.key);
            return l10n.getString(
              'calendarSyncEventImportFailed',
              params: {'title': titles, 'reason': reason},
            );
          }).toList();

          final failuresText = failureLines.join('\n');
          final message = successCount > 0
              ? '${l10n.getString('calendarSyncSyncedEventsSuccessWithSkipped', params: {'count': '$successCount', 'skipped': '$skippedCount'})}\n$failuresText'
              : failuresText;

          setState(() => _isLoading = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          return;
        }

        setState(() => _isLoading = false);
        final message = l10n.getString(
          'calendarSyncSyncedEventsSuccess',
          params: {'count': '$successCount'},
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
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
    final isAppleOnlineImportTitle =
        _currentStep == 0 &&
        _selectedProvider == CalendarProvider.apple &&
        (_selectedSource == CalendarSource.api || kIsWeb);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isAppleOnlineImportTitle
              ? l10n.getString('calendarSyncAppleOnlineImportTitle')
              : l10n.getString('calendarSyncTitle'),
        ),
        leading: _currentStep == 1
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
              )
            : null,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      l10n.getString(_errorMessage!),
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Expanded(
                  child: _currentStep == 0
                      ? _buildCalendarList(l10n)
                      : _buildEventList(l10n),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _currentStep == 0
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
    final userProfile = userId != null
        ? ref.watch(userProfileProvider(userId)).asData?.value
        : null;
    final userGender = userProfile?.gender;

    if (kIsWeb &&
        widget.initialProvider != null &&
        _selectedProvider != CalendarProvider.apple &&
        !_hasFetched) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasFetched) {
      if (kIsWeb) {
        if (_selectedProvider == CalendarProvider.apple) {
          return Center(
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildApplePublicCalendarUrlField(l10n),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _fetchCalendars();
                    },
                    icon: const Icon(Icons.phone_iphone),
                    label: Text(l10n.getString('calendarSyncConnectApple')),
                  ),
                ],
              ),
            ),
          );
        }
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
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _selectedProvider == CalendarProvider.outlook
                    ? Icons.mail_outline
                    : _selectedProvider == CalendarProvider.apple
                    ? Icons.phone_iphone
                    : _selectedProvider == CalendarProvider.device
                    ? Icons.devices_outlined
                    : Icons.calendar_month,
                size: 64,
                color: Colors.blue,
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
              if (_selectedProvider == CalendarProvider.apple)
                SizedBox(
                  width: 360,
                  child: Column(
                    children: [
                      _buildApplePublicCalendarUrlField(l10n),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await _fetchCalendars();
                        },
                        icon: const Icon(Icons.phone_iphone),
                        label: Text(l10n.getString('calendarSyncConnectApple')),
                      ),
                    ],
                  ),
                ),
              if (_selectedProvider == CalendarProvider.device)
                OutlinedButton.icon(
                  onPressed: () async {
                    await _fetchCalendars();
                  },
                  icon: const Icon(Icons.devices_outlined),
                  label: Text(l10n.getString('calendarSyncConnectDevice')),
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
                      : _selectedProvider == CalendarProvider.apple
                      ? Icons.phone_iphone
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
                            ? l10n.getString(
                                'calendarSyncNoCalendarsOutlook',
                                gender: userGender,
                              )
                            : (_isOutlookInstalled
                                  ? l10n.getString(
                                      'calendarSyncOutlookDetected',
                                      gender: userGender,
                                    )
                                  : l10n.getString(
                                      'calendarSyncNoOutlookOnDevice',
                                      gender: userGender,
                                    )))
                      : _selectedProvider == CalendarProvider.apple
                      ? ((_selectedSource == CalendarSource.api || kIsWeb)
                            ? l10n.getString(
                                'calendarSyncApplePublicNoCalendars',
                                gender: userGender,
                              )
                            : l10n.getString(
                                'calendarSyncNoCalendarsApple',
                                gender: userGender,
                              ))
                      : _selectedProvider == CalendarProvider.device
                      ? l10n.getString('calendarSyncNoCalendarsDevice')
                      : l10n.getString(
                          'calendarSyncNoCalendarsGoogle',
                          gender: userGender,
                        ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        _isOutlookInstalled &&
                            !kIsWeb &&
                            _selectedProvider == CalendarProvider.outlook
                        ? Colors.orange
                        : Colors.grey,
                    fontWeight:
                        _isOutlookInstalled &&
                            !kIsWeb &&
                            _selectedProvider == CalendarProvider.outlook
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
                          l10n.getString(
                            'calendarSyncOpenOutlookGuidance',
                            gender: userGender,
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.getString(
                            'calendarSyncWaitForSync',
                            gender: userGender,
                          ),
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
                if (_selectedProvider == CalendarProvider.apple &&
                    (_selectedSource == CalendarSource.api || kIsWeb)) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 420,
                    child: _buildApplePublicCalendarUrlField(l10n),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_selectedProvider == CalendarProvider.apple &&
            (_selectedSource == CalendarSource.api || kIsWeb))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildApplePublicCalendarUrlField(l10n),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _calendars.length,
            itemBuilder: (context, index) {
              final calendar = _calendars[index];
              final isSelected = _selectedCalendarIds.contains(calendar.id);

              return CheckboxListTile(
                title: Text(calendar.accountName ?? calendar.name),
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
    final selectedDuplicates = _selectedEventIds
        .intersection(_duplicateEventIds)
        .length;
    final groupedDeviceEvents = _groupDeviceEventsByAccount(l10n);
    final showDeviceAccountGrouping =
        _selectedProvider == CalendarProvider.device &&
        groupedDeviceEvents.length > 1;

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
                        _events.map((e) => e.id).where((id) => id.isNotEmpty),
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
          child: showDeviceAccountGrouping
              ? ListView(
                  children: [
                    for (final entry in groupedDeviceEvents.entries) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .secondaryContainer
                              .withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          entry.key,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      for (final event in entry.value)
                        _buildImportEventListItem(
                          context,
                          ref,
                          l10n,
                          event,
                          isSelected: _selectedEventIds.contains(event.id),
                          enabled:
                              !_duplicateEventIds.contains(event.id) ||
                              !_isDuplicateCheckEnabled,
                          isDuplicate: _duplicateEventIds.contains(event.id),
                        ),
                    ],
                  ],
                )
              : ListView.builder(
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

  Map<String, List<ExternalEvent>> _groupDeviceEventsByAccount(dynamic l10n) {
    if (_selectedProvider != CalendarProvider.device) {
      return <String, List<ExternalEvent>>{};
    }
    final grouped = <String, List<ExternalEvent>>{};
    for (final event in _events) {
      final accountLabel = _resolveAccountLabelForEvent(event, l10n);
      grouped.putIfAbsent(accountLabel, () => <ExternalEvent>[]).add(event);
    }
    return grouped;
  }

  String _resolveAccountLabelForEvent(ExternalEvent event, dynamic l10n) {
    final calendar = _calendars.cast<ExternalCalendar?>().firstWhere(
      (c) => c?.id == event.calendarId,
      orElse: () => null,
    );
    if (calendar != null) {
      final accountName = calendar.accountName?.trim();
      if (accountName != null && accountName.isNotEmpty) {
        return accountName;
      }
      final calendarName = calendar.name.trim();
      if (calendarName.isNotEmpty) {
        return calendarName;
      }
    }
    return l10n.getString('calendarSyncDeviceUnknownAccount');
  }

  Uri _applePublicCalendarHelpUriForLocale(LocalizationState l10n) {
    final languageCode = l10n.currentLocale.languageCode.toLowerCase();
    if (languageCode.startsWith('es')) {
      return _applePublicCalendarHelpUriEs;
    }
    return _applePublicCalendarHelpUriEn;
  }

  Widget _buildApplePublicCalendarUrlField(dynamic l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.getString('calendarSyncApplePublicUrlHelp'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () async {
            final helpUri = _applePublicCalendarHelpUriForLocale(l10n);
            final launched = await launchUrl(
              helpUri,
              mode: LaunchMode.externalApplication,
            );
            if (!launched && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.getString('calendarSyncApplePublicHelpLinkOpenFailed'),
                  ),
                ),
              );
            }
          },
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            alignment: Alignment.centerLeft,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(
            children: [
              const Icon(Icons.help_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('calendarSyncApplePublicHelpLinkLabel'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _applePublicCalendarUrlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _fetchCalendars(),
          decoration: InputDecoration(
            labelText: l10n.getString('calendarSyncApplePublicUrlLabel'),
            hintText: l10n.getString('calendarSyncApplePublicUrlHint'),
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
