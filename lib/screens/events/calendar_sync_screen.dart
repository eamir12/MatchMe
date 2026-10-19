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
import 'package:matchme/utils/event_import_classifier.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/event_import_block_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:matchme/widgets/safe_text.dart';

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
  static const double _accountSectionSpacing = 8;
  int _currentStep = 0;
  List<ExternalCalendar> _calendars = [];
  final Set<String> _selectedCalendarIds = {};
  List<ExternalEvent> _events = [];
  final Set<String> _selectedEventIds = {};
  String? _selectedDeviceAccountFilter;
  bool _showOnlyPotentiallyImportable = false;
  bool _isLoading = false;
  String? _errorMessage;
  bool _hasFetched = false;
  late CalendarProvider _selectedProvider;
  final Map<String, List<EventModel>> _existingEventsByStartKey =
      <String, List<EventModel>>{};
  final Map<String, List<EventModel>> _existingEventsByDayKey =
      <String, List<EventModel>>{};
  final Set<String> _existingImportedSourceKeys = <String>{};
  final Set<String> _duplicateEventIds = {};
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
  late final EventManager _eventManager;
  AsyncValue<List<EventModel>> _latestExistingEvents =
      const AsyncValue.loading();
  ProviderSubscription<AsyncValue<List<EventModel>>>? _eventManagerSub;

  void _trace(String message) {
    print(message);
    developer.log(message, name: 'CalendarSyncScreen');
  }

  String _currentImportProviderKey() {
    return _selectedSource == CalendarSource.api
        ? _selectedProvider.name
        : 'device';
  }

  /// Email of the account whose calendar is being imported, resolved once
  /// per fetch. Enables the self-organized-small-meeting signal (organizer
  /// == the importing account).
  String? _importOwnerEmail;

  Future<String?> _resolveImportOwnerEmail() async {
    try {
      switch (_selectedProvider) {
        case CalendarProvider.google:
          return await CalendarSyncService.getCachedGoogleImportEmailFromPrefs();
        case CalendarProvider.outlook:
          final payload = await ref
              .read(calendarSyncServiceProvider)
              .getCachedOutlookImportPayload();
          final email = (payload?['userEmail'] as String?)?.trim();
          return email == null || email.isEmpty ? null : email;
        case CalendarProvider.apple:
        case CalendarProvider.device:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Device calendars carry their owning account on the calendar record;
  /// when it's an email we can use it as the organizer-comparison owner.
  String? _deviceAccountEmailForEvent(ExternalEvent event) {
    if (_selectedProvider != CalendarProvider.device) {
      return null;
    }
    for (final calendar in _calendars) {
      if (calendar.id == event.calendarId) {
        final account = calendar.accountName?.trim();
        return account != null && account.contains('@') ? account : null;
      }
    }
    return null;
  }

  String _usableImportLink(String? link, {String? provider}) {
    return usableImportLink(link, provider: provider);
  }

  EventImportBlockReason _blockReasonForEvent(ExternalEvent event) {
    return classifyExternalEventImport(
      event,
      provider: _currentImportProviderKey(),
      ownerEmail: _deviceAccountEmailForEvent(event) ?? _importOwnerEmail,
    );
  }

  bool _isImportableEvent(ExternalEvent event) {
    return _blockReasonForEvent(event).importable;
  }

  /// Scrubbed event fields captured at block time so an admin can later
  /// review the feedback and import the event if deemed public. The link
  /// is stored only when it's a usable public link — provider-calendar
  /// deep-links (Outlook OWA, Google Calendar, ICS) are the user's private
  /// calendar pointers and must never reach the feedback record.
  Map<String, dynamic> _importSnapshotFor(ExternalEvent event) {
    return {
      'event_name': event.title,
      'event_venue': event.location,
      'event_link': usableImportLink(
        event.url?.toString(),
        provider: _currentImportProviderKey(),
      ),
      'start_time': event.start?.toIso8601String(),
      'end_time': event.end?.toIso8601String(),
      'is_all_day': event.isAllDay,
      'event_description': event.description,
      'external_provider': _currentImportProviderKey(),
      'external_calendar_id': event.calendarId,
      'external_event_id': event.id,
    };
  }

  void _showImportBlockedMessage(
    LocalizationState l10n,
    EventImportBlockReason reason,
    ExternalEvent event,
  ) {
    if (!mounted || reason.importable) return;
    showEventImportBlockSheet(
      context,
      l10n,
      reason,
      eventTitle: event.title,
      provider: _currentImportProviderKey(),
      eventSnapshot: _importSnapshotFor(event),
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
        : l10n.getString('eventNoTitle');
    final location = event.location?.trim();
    final hasLocation = location != null && location.isNotEmpty;
    final showMap = hasLocation && !isVirtualMeetingLocation(location);
    final blockReason = _blockReasonForEvent(event);
    final isImportable = blockReason.importable;

    Widget content = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.55)
              : Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.9),
          width: isSelected ? 1.6 : 1.2,
        ),
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
          if (!enabled) {
            if (!isImportable) {
              _showImportBlockedMessage(l10n, blockReason, event);
            }
            return;
          }
          setState(() {
            if (isSelected) {
              _selectedEventIds.remove(event.id);
            } else {
              _selectedEventIds.add(event.id);
            }
          });
        },
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
                        if (!isDuplicate && !isImportable)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              l10n.getString(blockReason.badgeKey),
                              style: Theme.of(context).textTheme.labelSmall,
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
                    if (!isImportable) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.getString(blockReason.hintKey),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.85),
                        ),
                      ),
                    ],
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
                        TextButton.icon(
                          onPressed: () async {
                            await _openImportEventDetails(l10n, event);
                          },
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(l10n.getString('eventViewDetails')),
                        ),
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
                        const Spacer(),
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
                          onPressed: () {
                            if (!enabled) {
                              if (!isImportable) {
                                _showImportBlockedMessage(
                                  l10n,
                                  blockReason,
                                  event,
                                );
                              }
                              return;
                            }
                            setState(() {
                              if (isSelected) {
                                _selectedEventIds.remove(event.id);
                              } else {
                                _selectedEventIds.add(event.id);
                              }
                            });
                          },
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
    _eventManager = ref.read(eventManagerProvider.notifier);
    _eventManagerSub = ref.listenManual<AsyncValue<List<EventModel>>>(
      eventManagerProvider,
      (previous, next) {
        _latestExistingEvents = next;
        next.whenData((events) {
          _updateExistingEventLookups(events);
          if (!mounted) {
            return;
          }
          setState(_checkForDuplicates);
        });
      },
      fireImmediately: true,
    );
    _selectedProvider = widget.initialProvider ?? CalendarProvider.google;
    // Default to the online source wherever the device calendar has no
    // implementation. `device_calendar_plus` ships Android and iOS only, so on
    // web and desktop defaulting to CalendarSource.device landed the user on a
    // source that throws
    // `Bad state: DeviceCalendarPlusPlatform.instance has not been initialized`.
    _selectedSource =
        widget.initialSource ??
        (kIsWeb ||
                _selectedProvider == CalendarProvider.apple ||
                !CalendarSyncService.isDeviceCalendarSupported
            ? CalendarSource.api
            : CalendarSource.device);
    // An explicit device source on a platform without a device-calendar
    // implementation would reach `service.requestPermissions()` and throw a raw
    // `Bad state:` Dart error. Fall back to the online source instead.
    if (_selectedSource == CalendarSource.device &&
        !CalendarSyncService.isDeviceCalendarSupported) {
      _trace(
        'CalendarSyncScreen initState: device source unsupported here, using online source',
      );
      _selectedSource = CalendarSource.api;
    }
    _trace(
      'CalendarSyncScreen initState initialProvider=${widget.initialProvider} selectedProvider=$_selectedProvider selectedSource=$_selectedSource',
    );
    _loadSavedApplePublicCalendarUrl();
    Future.microtask(() async {
      await _eventManager.fetchUserEvents(forceRemote: true);
      if (!mounted) {
        return;
      }
      await _loadExistingEvents();
      if (mounted) {
        setState(_checkForDuplicates);
      }
    });
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
          if (_isLoading ||
              _currentStep != 0 ||
              _selectedCalendarIds.isNotEmpty) {
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
      final events = _latestExistingEvents.maybeWhen(
        data: (eventList) => eventList,
        orElse: () => <EventModel>[],
      );
      _updateExistingEventLookups(events);
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  String _startMatchKey(
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
      return 'd:${localDate.year}-${localDate.month}-${localDate.day}';
    }
    return 't:${startTime.toUtc().millisecondsSinceEpoch}';
  }

  String _dayMatchKey(DateTime startTime) {
    final localDate = startTime.isUtc ? startTime.toLocal() : startTime;
    return 'd:${localDate.year}-${localDate.month}-${localDate.day}';
  }

  String? _sourceEventKey({
    String? provider,
    String? calendarId,
    String? eventId,
  }) {
    final normalizedProvider = provider?.trim().toLowerCase();
    final normalizedEventId = eventId?.trim();
    if (normalizedProvider == null ||
        normalizedProvider.isEmpty ||
        normalizedEventId == null ||
        normalizedEventId.isEmpty) {
      return null;
    }
    return '$normalizedProvider::${calendarId?.trim() ?? ''}::$normalizedEventId';
  }

  void _updateExistingEventLookups(List<EventModel> events) {
    _existingEventsByStartKey.clear();
    _existingEventsByDayKey.clear();
    _existingImportedSourceKeys.clear();
    for (final event in events) {
      final startKey = _startMatchKey(
        event.startTime,
        endTime: event.endTime,
        isAllDay: event.isAllDay,
      );
      _existingEventsByStartKey
          .putIfAbsent(startKey, () => <EventModel>[])
          .add(event);
      _existingEventsByDayKey
          .putIfAbsent(_dayMatchKey(event.startTime), () => <EventModel>[])
          .add(event);
      final sourceKey = _sourceEventKey(
        provider: event.externalProvider,
        calendarId: event.externalCalendarId,
        eventId: event.externalEventId,
      );
      if (sourceKey != null) {
        _existingImportedSourceKeys.add(sourceKey);
      }
    }
  }

  String _normalizeVenue(String? venue) {
    if (venue == null || venue.trim().isEmpty) {
      return '';
    }
    var normalized = venue.toLowerCase().trim();
    final commaIndex = normalized.indexOf(',');
    if (commaIndex > 0) {
      normalized = normalized.substring(0, commaIndex);
    }
    normalized = normalized
        .replaceAll('theatre', 'theater')
        .replaceAll('centre', 'center')
        .replaceAll('theater', 'thtr')
        .replaceAll('center', 'ctr')
        .replaceAll('hall', 'hl')
        .replaceAll('stadium', 'stdm')
        .replaceAll('arena', 'arn')
        .replaceAll('pavilion', 'pav');
    const wordsToRemove = <String>[
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
    return normalized
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeEventLink(String? link) {
    if (link == null || link.trim().isEmpty) {
      return '';
    }
    try {
      final uri = Uri.parse(link.trim());
      var normalized = uri
          .replace(queryParameters: {}, fragment: '')
          .toString();
      normalized = normalized.replaceAll(RegExp(r'/+$'), '');
      return normalized.toLowerCase();
    } catch (_) {
      return link.split('?').first.toLowerCase().trim();
    }
  }

  String _normalizeEventName(String name) {
    var normalized = name.toLowerCase().trim();
    final suffixPatterns = <RegExp>[
      RegExp(r'\s+w/\s+.+$', caseSensitive: false),
      RegExp(r'\s+with\s+.+$', caseSensitive: false),
      RegExp(r'\s+feat\.?\s+.+$', caseSensitive: false),
      RegExp(r'\s+featuring\s+.+$', caseSensitive: false),
      RegExp(r'\s+plus\s+.+$', caseSensitive: false),
      RegExp(r'\s+\+\s+.+$', caseSensitive: false),
      RegExp(r'\s+and\s+.+$', caseSensitive: false),
      RegExp(r'\s+&\s+.+$', caseSensitive: false),
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
      RegExp(
        r'\s*[-–—]\s*(floor|balcony|mezzanine|orchestra|section|row|seat).*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*\((floor|balcony|mezzanine|orchestra|section)\s*.*\).*$',
        caseSensitive: false,
      ),
      RegExp(r'\s*[-–—]?\s*\d+\+.*$', caseSensitive: false),
      RegExp(r'\s*\(\d+\+\).*$', caseSensitive: false),
      RegExp(
        r'\s*[-–—]?\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}.*$',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*[-–—]\s*(admission|tickets?|pass|entry|show|doors?).*$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in suffixPatterns) {
      normalized = normalized.replaceFirst(pattern, '');
    }
    return normalized
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _areEventNamesMatching(String left, String right) {
    if (left == right) {
      return true;
    }
    if (left.length > right.length) {
      return left.contains(right) || right.contains(left);
    }
    return right.contains(left) || left.contains(right);
  }

  bool _timesPossiblyMatch(
    DateTime left,
    DateTime right, {
    bool leftIsAllDay = false,
    bool rightIsAllDay = false,
  }) {
    if (left.toUtc().difference(right.toUtc()).abs() <=
        const Duration(hours: 6)) {
      return true;
    }
    final leftLocal = left.isUtc ? left.toLocal() : left;
    final rightLocal = right.isUtc ? right.toLocal() : right;
    final sameLocalDay =
        leftLocal.year == rightLocal.year &&
        leftLocal.month == rightLocal.month &&
        leftLocal.day == rightLocal.day;
    return sameLocalDay && (leftIsAllDay || rightIsAllDay);
  }

  List<EventModel> _candidateExistingEvents(
    DateTime startTime, {
    DateTime? endTime,
    bool isAllDay = false,
  }) {
    final combined = <EventModel>[];
    final seen = <String>{};

    void addEvents(Iterable<EventModel> events) {
      for (final existing in events) {
        final key =
            '${existing.id}|${existing.startTime.toUtc().millisecondsSinceEpoch}|${existing.eventName}';
        if (seen.add(key)) {
          combined.add(existing);
        }
      }
    }

    addEvents(
      _existingEventsByStartKey[_startMatchKey(
            startTime,
            endTime: endTime,
            isAllDay: isAllDay,
          )] ??
          const <EventModel>[],
    );
    addEvents(
      _existingEventsByDayKey[_dayMatchKey(startTime)] ?? const <EventModel>[],
    );

    return combined;
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
    if (deviceEvent.start == null) {
      return false;
    }

    final sourceKey = _sourceEventKey(
      provider: _currentImportProviderKey(),
      calendarId: deviceEvent.calendarId,
      eventId: deviceEvent.id,
    );
    if (sourceKey != null && _existingImportedSourceKeys.contains(sourceKey)) {
      return true;
    }

    final candidates = _candidateExistingEvents(
      deviceEvent.start!,
      endTime: deviceEvent.end,
      isAllDay: deviceEvent.isAllDay,
    );
    if (candidates.isEmpty) {
      return false;
    }

    final normalizedName = _normalizeEventName(deviceEvent.title);
    final normalizedVenue = _normalizeVenue(deviceEvent.location);
    final normalizedLink = _normalizeEventLink(
      _usableImportLink(
        deviceEvent.url?.toString(),
        provider: _currentImportProviderKey(),
      ),
    );

    for (final existing in candidates) {
      final existingNormalizedName = _normalizeEventName(existing.eventName);
      final existingNormalizedVenue = _normalizeVenue(existing.eventVenue);
      final existingNormalizedLink = _normalizeEventLink(
        _usableImportLink(
          existing.eventLink,
          provider: existing.externalProvider,
        ),
      );
      final timesMatch = _timesPossiblyMatch(
        deviceEvent.start!,
        existing.startTime,
        leftIsAllDay: deviceEvent.isAllDay,
        rightIsAllDay: existing.isAllDay,
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
      if (namesMatch && venuesMatch && timesMatch) {
        return true;
      }
      if (normalizedLink.isNotEmpty &&
          existingNormalizedLink == normalizedLink &&
          timesMatch) {
        return true;
      }
      if (namesMatch &&
          normalizedVenue.isEmpty &&
          existingNormalizedVenue.isEmpty &&
          normalizedLink.isEmpty &&
          existingNormalizedLink.isEmpty &&
          timesMatch) {
        return true;
      }
    }

    return false;
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
    _eventManagerSub?.close();
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
      final l10n = ref.read(localizationProvider);
      final availableDeviceAccountLabels = _deviceAccountLabelsForCalendars(
        calendars,
        l10n,
      );

      setState(() {
        _calendars = calendars;
        _isLoading = false;
        _hasFetched = true;
        _useOutlookOAuthFallback = false;
        _isUsingPermissionFallbackOnline = usedPermissionFallbackOnline;
        if (_selectedDeviceAccountFilter != null &&
            !availableDeviceAccountLabels.contains(
              _selectedDeviceAccountFilter,
            )) {
          _selectedDeviceAccountFilter = null;
        }
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
      final keepAppleOnlineFormState = _shouldKeepAppleOnlineFormState(
        errorKey,
      );
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
      _importOwnerEmail = await _resolveImportOwnerEmail();

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
            : !kIsWeb &&
                  useOnlineApi &&
                  _selectedProvider == CalendarProvider.google
            ? await service.retrieveGoogleEventsNonWebOAuth(
                calendarId,
                startDate: startDate,
                endDate: endDate,
              )
            : useOnlineApi && _selectedProvider == CalendarProvider.google
            ? await service.retrieveEvents(
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
          .where((e) => !_duplicateEventIds.contains(e.id))
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
      final Map<String, List<String>> failedByReasonToken =
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
        // Defense-in-depth: the picker only allows selecting importable
        // events, but re-verify here so nothing private slips through.
        final blockReason = _blockReasonForEvent(deviceEvent);
        if (!blockReason.importable) {
          skippedCount++;
          failedByReasonToken
              .putIfAbsent(
                'eventAddRejectedPersonalOrPrivate',
                () => <String>[],
              )
              .add(deviceEvent.title);
          continue;
        }
        if (deviceEvent.start == null || deviceEvent.end == null) {
          skippedCount++;
          failedByReasonToken
              .putIfAbsent(
                'calendarSyncSkipReasonMissingDate',
                () => <String>[],
              )
              .add(deviceEvent.title);
          continue;
        }

        final newEvent = EventModel(
          id: '', // ID will be generated by backend/provider
          eventName: deviceEvent.title.trim().isNotEmpty
              ? deviceEvent.title.trim()
              : l10n.getString('eventNoTitle'),
          eventVenue: deviceEvent.location,
          startTime: deviceEvent.start!,
          endTime: deviceEvent.end!,
          eventLink: _usableImportLink(
            deviceEvent.url?.toString(),
            provider: _currentImportProviderKey(),
          ),
          description: deviceEvent.description,
          externalCalendarId: deviceEvent.calendarId.trim().isNotEmpty
              ? deviceEvent.calendarId.trim()
              : null,
          externalEventId: deviceEvent.id.trim().isNotEmpty
              ? deviceEvent.id.trim()
              : null,
          externalProvider: _currentImportProviderKey(),
          isAllDay: deviceEvent.isAllDay,
          markedPrivateInSource:
              blockReason == EventImportBlockReason.markedPrivate,
        );

        final result = await eventManager.addEventWithResult(newEvent);
        if (result.success) {
          successCount++;
        } else {
          skippedCount++;
          final reasonKey = result.errorKey ?? 'eventAddFailedUnknown';
          final diagnosticCode = result.diagnosticCode ?? '';
          print(
            '[EVENT_IMPORT_UI] Device import failed for "${deviceEvent.title}" reasonKey=$reasonKey diagnosticCode=${diagnosticCode.isEmpty ? 'none' : diagnosticCode}',
          );
          final reasonToken = diagnosticCode.isEmpty
              ? reasonKey
              : '$reasonKey||$diagnosticCode';
          failedByReasonToken
              .putIfAbsent(reasonToken, () => <String>[])
              .add(deviceEvent.title);
        }
      }

      if (mounted) {
        if (failedByReasonToken.isNotEmpty) {
          final failureLines = failedByReasonToken.entries.map((entry) {
            final titles = joinTitles(entry.value);
            final tokenParts = entry.key.split('||');
            final reason = l10n.getString(tokenParts.first);
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
    final isDeviceImportTitle = _selectedProvider == CalendarProvider.device;

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(
          isAppleOnlineImportTitle
              ? l10n.getString('calendarSyncAppleOnlineImportTitle')
              : isDeviceImportTitle
              ? l10n.getString('eventsImportDeviceCalendar')
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
      bottomNavigationBar: _isLoading
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton(
                  onPressed: _currentStep == 0
                      ? (_selectedCalendarIds.isNotEmpty ? _fetchEvents : null)
                      : (_selectedEventIds.isNotEmpty
                            ? _syncSelectedEvents
                            : null),
                  child: Text(
                    l10n.getString(
                      'onlineProvidersImportSelected',
                      params: {
                        'count': _currentStep == 0
                            ? '${_selectedCalendarIds.length}'
                            : '${_selectedEventIds.length}',
                      },
                    ),
                  ),
                ),
              ),
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
              ],
            ),
    );
  }

  Widget _buildDeviceSummaryCard(LocalizationState l10n) {
    final accountLabels = _currentStep == 0
        ? _deviceAccountLabelsForCalendars(_calendars, l10n)
        : (_events.isNotEmpty
              ? _deviceAccountLabelsForEvents(_events, l10n)
              : _deviceAccountLabelsForCalendars(_calendars, l10n));
    final selectedCount = _currentStep == 0
        ? _selectedCalendarIds.length
        : _selectedEventIds.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            Theme.of(context).colorScheme.secondary.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.getString(
              'calendarSyncDeviceSummaryBody',
              params: {
                'accounts': '${accountLabels.length}',
                'events': '${_events.length}',
                'selected': '$selectedCount',
              },
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                        ? (Theme.of(context).brightness == Brightness.dark
                              ? Colors.amber.shade300
                              : Colors.orange.shade800)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
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

    if (_selectedProvider == CalendarProvider.device) {
      final deviceAccountLabels = _deviceAccountLabelsForCalendars(
        _calendars,
        l10n,
      );
      final visibleCalendars = _visibleDeviceCalendars(l10n);
      final groupedCalendars = _groupDeviceCalendarsByAccount(
        l10n,
        calendars: visibleCalendars,
      );

      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          _buildDeviceSummaryCard(l10n),
          if (deviceAccountLabels.length > 1) ...[
            const SizedBox(height: 12),
            _buildDeviceAccountFilters(l10n, deviceAccountLabels),
          ],
          const SizedBox(height: 12),
          for (final entry in groupedCalendars.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: _accountSectionSpacing),
              child: _buildDeviceCalendarAccountSection(
                l10n,
                entry.key,
                entry.value,
              ),
            ),
        ],
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

    final deviceAccountLabels = _deviceAccountLabelsForEvents(_events, l10n);
    final visibleEvents = _visibleDeviceEvents(l10n);
    final groupedDeviceEvents = _groupDeviceEventsByAccount(
      l10n,
      events: visibleEvents,
    );
    final showDeviceAccountGrouping =
        _selectedProvider == CalendarProvider.device &&
        deviceAccountLabels.length > 1;
    final visibleSelectableCount = visibleEvents
        .where((event) => event.id.isNotEmpty && _isImportableEvent(event))
        .length;
    final visibleSelectedCount = visibleEvents
        .where((event) => _selectedEventIds.contains(event.id))
        .length;
    final allVisibleSelected =
        visibleSelectableCount > 0 &&
        visibleSelectableCount == visibleSelectedCount;

    if (_selectedProvider == CalendarProvider.device) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          _buildDeviceSummaryCard(l10n),
          if (showDeviceAccountGrouping) ...[
            const SizedBox(height: 12),
            _buildDeviceAccountFilters(l10n, deviceAccountLabels),
          ],
          const SizedBox(height: 12),
          _buildDeviceVisibilityFilters(l10n),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString(
                    'onlineProvidersSelectionSummary',
                    params: {
                      'selected': '$visibleSelectedCount',
                      'available': '$visibleSelectableCount',
                    },
                  ),
                ),
              ),
              TextButton(
                onPressed: visibleSelectableCount == 0
                    ? null
                    : () => _toggleSelectVisibleDeviceEvents(visibleEvents),
                child: Text(
                  allVisibleSelected
                      ? l10n.getString('calendarSyncDeselectAll')
                      : l10n.getString('calendarSyncSelectAll'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (visibleEvents.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Center(
                child: Text(l10n.getString('calendarSyncNoEventsMatchFilters')),
              ),
            )
          else if (showDeviceAccountGrouping)
            for (final entry in groupedDeviceEvents.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: _accountSectionSpacing),
                child: _buildDeviceEventAccountSection(
                  l10n,
                  entry.key,
                  entry.value,
                ),
              )
          else
            for (final event in visibleEvents)
              _buildImportEventListItem(
                context,
                ref,
                l10n,
                event,
                isSelected: _selectedEventIds.contains(event.id),
                enabled:
                    !_duplicateEventIds.contains(event.id) &&
                    _isImportableEvent(event),
                isDuplicate: _duplicateEventIds.contains(event.id),
              ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.getString(
                        'onlineProvidersSelectionSummary',
                        params: {
                          'selected': '$visibleSelectedCount',
                          'available': '$visibleSelectableCount',
                        },
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: visibleSelectableCount == 0
                        ? null
                        : () => _toggleSelectVisibleDeviceEvents(visibleEvents),
                    child: Text(
                      allVisibleSelected
                          ? l10n.getString('calendarSyncDeselectAll')
                          : l10n.getString('calendarSyncSelectAll'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _buildDeviceVisibilityFilters(l10n),
              ),
            ],
          ),
        ),
        if (visibleEvents.isEmpty)
          Expanded(
            child: Center(
              child: Text(l10n.getString('calendarSyncNoEventsMatchFilters')),
            ),
          )
        else
          Expanded(
            child: showDeviceAccountGrouping
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      for (final entry in groupedDeviceEvents.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _buildDeviceEventAccountSection(
                            l10n,
                            entry.key,
                            entry.value,
                          ),
                        ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
                    itemCount: visibleEvents.length,
                    itemBuilder: (context, index) {
                      final event = visibleEvents[index];
                      final isSelected = _selectedEventIds.contains(event.id);
                      final isDuplicate = _duplicateEventIds.contains(event.id);
                      final enabled = !isDuplicate && _isImportableEvent(event);

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

  Map<String, List<ExternalCalendar>> _groupDeviceCalendarsByAccount(
    dynamic l10n, {
    List<ExternalCalendar>? calendars,
  }) {
    if (_selectedProvider != CalendarProvider.device) {
      return <String, List<ExternalCalendar>>{};
    }
    final grouped = <String, List<ExternalCalendar>>{};
    for (final calendar in calendars ?? _calendars) {
      final accountLabel = _resolveAccountLabelForCalendar(calendar, l10n);
      grouped
          .putIfAbsent(accountLabel, () => <ExternalCalendar>[])
          .add(calendar);
    }
    return grouped;
  }

  Map<String, List<ExternalEvent>> _groupDeviceEventsByAccount(
    dynamic l10n, {
    Iterable<ExternalEvent>? events,
  }) {
    if (_selectedProvider != CalendarProvider.device) {
      return <String, List<ExternalEvent>>{};
    }
    final grouped = <String, List<ExternalEvent>>{};
    for (final event in events ?? _events) {
      final accountLabel = _resolveAccountLabelForEvent(event, l10n);
      grouped.putIfAbsent(accountLabel, () => <ExternalEvent>[]).add(event);
    }
    return grouped;
  }

  String _resolveAccountLabelForCalendar(
    ExternalCalendar calendar,
    dynamic l10n,
  ) {
    final accountName = calendar.accountName?.trim();
    if (accountName != null && accountName.isNotEmpty) {
      return accountName;
    }
    final calendarName = calendar.name.trim();
    if (calendarName.isNotEmpty) {
      return calendarName;
    }
    return l10n.getString('calendarSyncDeviceUnknownAccount');
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

  List<String> _deviceAccountLabelsForCalendars(
    List<ExternalCalendar> calendars,
    dynamic l10n,
  ) {
    final labels =
        calendars
            .map((calendar) => _resolveAccountLabelForCalendar(calendar, l10n))
            .toSet()
            .toList()
          ..sort();
    return labels;
  }

  List<String> _deviceAccountLabelsForEvents(
    List<ExternalEvent> events,
    dynamic l10n,
  ) {
    final labels =
        events
            .map((event) => _resolveAccountLabelForEvent(event, l10n))
            .toSet()
            .toList()
          ..sort();
    return labels;
  }

  List<ExternalCalendar> _visibleDeviceCalendars(dynamic l10n) {
    if (_selectedProvider != CalendarProvider.device ||
        _selectedDeviceAccountFilter == null) {
      return _calendars;
    }
    return _calendars.where((calendar) {
      return _resolveAccountLabelForCalendar(calendar, l10n) ==
          _selectedDeviceAccountFilter;
    }).toList();
  }

  List<ExternalEvent> _visibleDeviceEvents(dynamic l10n) {
    return _events.where((event) {
      if (_duplicateEventIds.contains(event.id)) {
        return false;
      }
      if (_selectedProvider == CalendarProvider.device &&
          _selectedDeviceAccountFilter != null &&
          _resolveAccountLabelForEvent(event, l10n) !=
              _selectedDeviceAccountFilter) {
        return false;
      }
      if (_showOnlyPotentiallyImportable && !_isImportableEvent(event)) {
        return false;
      }
      return true;
    }).toList();
  }

  void _toggleSelectVisibleDeviceEvents(List<ExternalEvent> events) {
    final selectableIds = events
        .where((event) => event.id.isNotEmpty && _isImportableEvent(event))
        .map((event) => event.id)
        .toSet();
    setState(() {
      final allSelected =
          selectableIds.isNotEmpty &&
          selectableIds.every(_selectedEventIds.contains);
      if (allSelected) {
        _selectedEventIds.removeAll(selectableIds);
      } else {
        _selectedEventIds.addAll(selectableIds);
      }
    });
  }

  Widget _buildDeviceAccountFilters(dynamic l10n, List<String> accountLabels) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 0,
      children: [
        ChoiceChip(
          label: Text(l10n.getString('onlineProvidersAllAccounts')),
          selected: _selectedDeviceAccountFilter == null,
          avatar: Icon(
            Icons.apps_rounded,
            size: 18,
            color: _selectedDeviceAccountFilter == null
                ? colorScheme.onSecondaryContainer
                : colorScheme.onSurfaceVariant,
          ),
          selectedColor: colorScheme.secondaryContainer,
          onSelected: (_) {
            setState(() {
              _selectedDeviceAccountFilter = null;
            });
          },
        ),
        ...accountLabels.map(
          (accountLabel) => ChoiceChip(
            label: Text(accountLabel, overflow: TextOverflow.visible),
            avatar: CircleAvatar(
              radius: 10,
              backgroundColor: _accountAccentColorForLabel(accountLabel),
              child: Icon(
                Icons.calendar_month_outlined,
                size: 12,
                color: _onAccountAccentColorForLabel(accountLabel),
              ),
            ),
            selected: _selectedDeviceAccountFilter == accountLabel,
            selectedColor: _accountBackgroundColorForLabel(
              accountLabel,
              selected: true,
            ),
            side: BorderSide(
              color: _accountBorderColorForLabel(
                accountLabel,
                selected: _selectedDeviceAccountFilter == accountLabel,
              ),
            ),
            onSelected: (_) {
              setState(() {
                _selectedDeviceAccountFilter = accountLabel;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceVisibilityFilters(LocalizationState l10n) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterChip(
          label: Text(l10n.getString('calendarSyncFilterImportableOnly')),
          selected: _showOnlyPotentiallyImportable,
          onSelected: (value) {
            setState(() {
              _showOnlyPotentiallyImportable = value;
            });
          },
        ),
      ],
    );
  }

  Future<void> _openImportEventDetails(
    LocalizationState l10n,
    ExternalEvent event,
  ) async {
    if (_selectedProvider == CalendarProvider.device) {
      final opened = await ref
          .read(calendarSyncServiceProvider)
          .openDeviceCalendarEvent(event.id);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('calendarSyncOpenEventFailed')),
          ),
        );
      }
      return;
    }

    final url = event.url;
    if (url != null && await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('calendarSyncOpenEventFailed'))),
      );
    }
  }

  Widget _buildDeviceCalendarAccountSection(
    dynamic l10n,
    String accountLabel,
    List<ExternalCalendar> calendars,
  ) {
    final accentColor = _accountAccentColorForLabel(accountLabel);
    return Container(
      decoration: BoxDecoration(
        color: _accountBackgroundColorForLabel(accountLabel),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accountBorderColorForLabel(accountLabel)),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: accentColor,
                  child: Icon(
                    Icons.calendar_month_outlined,
                    color: _onAccountAccentColorForLabel(accountLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    accountLabel,
                    maxLines: 2,
                    overflow: TextOverflow.visible,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...calendars.map((calendar) => _buildDeviceCalendarTile(calendar)),
        ],
      ),
    );
  }

  Widget _buildDeviceCalendarTile(ExternalCalendar calendar) {
    final isSelected = _selectedCalendarIds.contains(calendar.id);
    final accentColor = _accountAccentColorForLabel(
      calendar.accountName?.trim().isNotEmpty == true
          ? calendar.accountName!.trim()
          : calendar.name,
    );
    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedCalendarIds.remove(calendar.id);
          } else {
            _selectedCalendarIds.add(calendar.id);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.event_note_outlined, color: accentColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    calendar.name,
                    maxLines: 2,
                    overflow: TextOverflow.visible,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (calendar.accountName != null &&
                      calendar.accountName != calendar.name) ...[
                    const SizedBox(height: 4),
                    Text(
                      calendar.accountName!,
                      maxLines: 2,
                      overflow: TextOverflow.visible,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Checkbox(
              value: isSelected,
              onChanged: (_) {
                setState(() {
                  if (isSelected) {
                    _selectedCalendarIds.remove(calendar.id);
                  } else {
                    _selectedCalendarIds.add(calendar.id);
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceEventAccountSection(
    LocalizationState l10n,
    String accountLabel,
    List<ExternalEvent> events,
  ) {
    final accentColor = _accountAccentColorForLabel(accountLabel);
    final eventCountText = _buildEventCountText(l10n, events.length);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: _accountBackgroundColorForLabel(accountLabel),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _accountBorderColorForLabel(accountLabel),
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: accentColor,
                  child: Icon(
                    Icons.calendar_month_outlined,
                    color: _onAccountAccentColorForLabel(accountLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accountLabel,
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        eventCountText,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        ...events.map(
          (event) => _buildImportEventListItem(
            context,
            ref,
            l10n,
            event,
            isSelected: _selectedEventIds.contains(event.id),
            enabled:
                !_duplicateEventIds.contains(event.id) &&
                _isImportableEvent(event),
            isDuplicate: _duplicateEventIds.contains(event.id),
          ),
        ),
      ],
    );
  }

  String _buildEventCountText(LocalizationState l10n, int count) {
    final countText = l10n.formatCount(count);
    final eventWord = count == 1
        ? l10n.getString('onlineProvidersEventSingular')
        : l10n.getString('onlineProvidersEvents');
    if (l10n.currentLocale.languageCode == 'he' && count == 1) {
      return '$eventWord $countText';
    }
    return '$countText $eventWord';
  }

  int _stableColorHash(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  Color _accountAccentColorForLabel(String accountLabel) {
    final hash = _stableColorHash(accountLabel);
    final hue = (hash % 360).toDouble();
    final saturation = 0.62 + (((hash >> 4) % 18) / 100);
    final lightness = Theme.of(context).brightness == Brightness.dark
        ? 0.60 + (((hash >> 8) % 8) / 100)
        : 0.44 + (((hash >> 8) % 10) / 100);
    return HSLColor.fromAHSL(
      1,
      hue,
      saturation.clamp(0.0, 1.0),
      lightness,
    ).toColor();
  }

  Color _onAccountAccentColorForLabel(String accountLabel) {
    final brightness = ThemeData.estimateBrightnessForColor(
      _accountAccentColorForLabel(accountLabel),
    );
    return brightness == Brightness.dark ? Colors.white : Colors.black87;
  }

  Color _accountBackgroundColorForLabel(
    String accountLabel, {
    bool selected = false,
  }) {
    final accentColor = _accountAccentColorForLabel(accountLabel);
    final baseOpacity = selected ? 0.22 : 0.10;
    final darkModeBoost = Theme.of(context).brightness == Brightness.dark
        ? 0.08
        : 0.0;
    return accentColor.withValues(alpha: baseOpacity + darkModeBoost);
  }

  Color _accountBorderColorForLabel(
    String accountLabel, {
    bool selected = false,
  }) {
    final accentColor = _accountAccentColorForLabel(accountLabel);
    return accentColor.withValues(alpha: selected ? 0.55 : 0.26);
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
