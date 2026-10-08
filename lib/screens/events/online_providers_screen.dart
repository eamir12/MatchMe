import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/calendar_sync_provider.dart';
import 'package:matchme/providers/connected_online_accounts_provider.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/events/apple_calendar_import_screen.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/utils/event_import_classifier.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/event_import_block_sheet.dart';
import 'package:url_launcher/url_launcher.dart';

class OnlineProvidersScreen extends ConsumerStatefulWidget {
  const OnlineProvidersScreen({super.key});

  @override
  ConsumerState<OnlineProvidersScreen> createState() =>
      _OnlineProvidersScreenState();
}

class _OnlineProvidersScreenState extends ConsumerState<OnlineProvidersScreen> {
  static const double _accountSectionSpacing = 8;
  bool _isLoading = false;
  bool _isImporting = false;
  bool _showOnlyPotentiallyImportable = false;
  String? _errorMessage;
  String? _selectedAccountFilterId;
  final Set<String> _selectedEventKeys = <String>{};
  final Set<String> _duplicateEventKeys = <String>{};
  final Set<String> _refreshingAccountIds = <String>{};
  final Map<String, List<EventModel>> _existingEventsByStartKey =
      <String, List<EventModel>>{};
  final Map<String, List<EventModel>> _existingEventsByDayKey =
      <String, List<EventModel>>{};
  final Set<String> _existingImportedSourceKeys = <String>{};
  late final EventManager _eventManager;
  AsyncValue<List<EventModel>> _latestExistingEvents =
      const AsyncValue.loading();
  ProviderSubscription<AsyncValue<List<EventModel>>>? _eventManagerSub;
  ProviderSubscription<List<ConnectedOnlineAccount>>? _connectedAccountsSub;

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
          setState(_recalculateDuplicates);
        });
      },
      fireImmediately: true,
    );
    _connectedAccountsSub = ref.listenManual<List<ConnectedOnlineAccount>>(
      connectedOnlineAccountsProvider,
      (previous, next) {
        if (!mounted) {
          return;
        }
        setState(() {
          _pruneUnavailableSelections(next);
          _recalculateDuplicates();
        });
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void dispose() {
    _eventManagerSub?.close();
    _connectedAccountsSub?.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _eventManager.fetchUserEvents(forceRemote: true);
    if (!mounted) {
      return;
    }
    await _loadExistingEvents();
    await _refreshAllAccounts(showSpinner: false);
  }

  Future<void> _loadExistingEvents() async {
    try {
      final events = _latestExistingEvents.maybeWhen(
        data: (eventList) => eventList,
        orElse: () => <EventModel>[],
      );
      _updateExistingEventLookups(events);
      if (mounted) {
        setState(() {
          _recalculateDuplicates();
        });
      }
    } catch (_) {}
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

  String _selectionKey(ConnectedOnlineAccount account, EventModel event) {
    final rawEventId = event.externalEventId?.trim().isNotEmpty == true
        ? event.externalEventId!.trim()
        : event.id.trim().isNotEmpty
        ? event.id.trim()
        : _createEventKey(
            event.eventName,
            event.startTime,
            endTime: event.endTime,
            isAllDay: event.isAllDay,
          );
    return '${account.accountId}::$rawEventId';
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

  bool _isDuplicate(ConnectedOnlineAccount account, EventModel event) {
    final sourceKey = _sourceEventKey(
      provider: event.externalProvider,
      calendarId: event.externalCalendarId,
      eventId: event.externalEventId,
    );
    if (sourceKey != null && _existingImportedSourceKeys.contains(sourceKey)) {
      return true;
    }

    final candidates = _candidateExistingEvents(
      event.startTime,
      endTime: event.endTime,
      isAllDay: event.isAllDay,
    );
    if (candidates.isEmpty) {
      return false;
    }

    final normalizedName = _normalizeEventName(event.eventName);
    final normalizedVenue = _normalizeVenue(event.eventVenue);
    final normalizedLink = _normalizeEventLink(
      _usableImportLink(event.eventLink, provider: event.externalProvider),
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
        event.startTime,
        existing.startTime,
        leftIsAllDay: event.isAllDay,
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

  String _usableImportLink(String? link, {String? provider}) {
    return usableImportLink(link, provider: provider);
  }

  EventImportBlockReason _blockReasonForEvent(EventModel event) {
    return classifyEventModelImport(event);
  }

  bool _isImportableEvent(EventModel event) {
    return _blockReasonForEvent(event).importable;
  }

  bool _isVisibleOnlineProviderEvent(EventModel event) {
    return !event.startTime.isBefore(DateTime.now());
  }

  List<EventModel> _filterVisibleOnlineProviderEvents(
    Iterable<EventModel> events,
  ) {
    final filtered = events.where(_isVisibleOnlineProviderEvent).toList();
    filtered.sort(
      (first, second) => first.startTime.compareTo(second.startTime),
    );
    return filtered;
  }

  /// Scrubbed event fields captured at block time so an admin can later
  /// review the feedback and import the event if deemed public. The link
  /// is stored only when it's a usable public link — provider-calendar
  /// deep-links (Outlook OWA, Google Calendar, ICS) are the user's private
  /// calendar pointers and must never reach the feedback record.
  Map<String, dynamic> _importSnapshotFor(EventModel event) {
    return {
      'event_name': event.eventName,
      'event_venue': event.eventVenue,
      'event_link': usableImportLink(
        event.eventLink,
        provider: event.externalProvider,
      ),
      'start_time': event.startTime.toIso8601String(),
      'end_time': event.endTime.toIso8601String(),
      'is_all_day': event.isAllDay,
      'event_description': event.description,
      'external_provider': event.externalProvider,
      'external_calendar_id': event.externalCalendarId,
      'external_event_id': event.externalEventId,
    };
  }

  void _showImportBlockedMessage(
    LocalizationState l10n,
    EventImportBlockReason reason,
    EventModel event,
  ) {
    if (!mounted || reason.importable) return;
    showEventImportBlockSheet(
      context,
      l10n,
      reason,
      eventTitle: event.eventName,
      provider: event.externalProvider,
      eventSnapshot: _importSnapshotFor(event),
    );
  }

  void _recalculateDuplicates() {
    _duplicateEventKeys.clear();
    final accounts = ref.read(connectedOnlineAccountsProvider);
    for (final account in accounts) {
      for (final event in account.events) {
        if (_isDuplicate(account, event)) {
          _duplicateEventKeys.add(_selectionKey(account, event));
        }
      }
    }
    _selectedEventKeys.removeWhere(_duplicateEventKeys.contains);
  }

  void _pruneUnavailableSelections(List<ConnectedOnlineAccount> accounts) {
    final validSelectionKeys = <String>{};
    for (final account in accounts) {
      for (final event in account.events) {
        if (_isVisibleOnlineProviderEvent(event)) {
          validSelectionKeys.add(_selectionKey(account, event));
        }
      }
    }
    _selectedEventKeys.removeWhere((key) => !validSelectionKeys.contains(key));
  }

  String _localizedMessage(LocalizationState l10n, Object error) {
    if (error is CalendarSyncException) {
      final key = error.userMessage;
      if (key != null && key.trim().isNotEmpty) {
        final localized = l10n.getString(key);
        if (localized.trim().isNotEmpty && localized != key) {
          return localized;
        }
        return key;
      }
      return error.message;
    }
    return error.toString();
  }

  String? _localizedMessageOrNull(LocalizationState l10n, Object error) {
    if (error is CalendarSyncException &&
        (error.userMessage == 'onlineProvidersAccountAlreadyAdded' ||
            error.userMessage == 'calendarSyncGoogleConfigError')) {
      return null;
    }
    final message = _localizedMessage(l10n, error).trim();
    if (message.isEmpty) {
      return null;
    }
    return message;
  }

  Future<void> _refreshAllAccounts({bool showSpinner = true}) async {
    final accounts = ref.read(connectedOnlineAccountsProvider);
    if (accounts.isEmpty) {
      if (mounted && showSpinner) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        if (showSpinner) {
          _isLoading = true;
        }
        _errorMessage = null;
        _refreshingAccountIds
          ..clear()
          ..addAll(accounts.map((account) => account.accountId));
      });
    }

    final l10n = ref.read(localizationProvider);
    String? firstError;
    for (final account in accounts) {
      try {
        await _refreshAccount(account, showErrorSnackBar: false);
      } catch (error) {
        firstError ??= _localizedMessageOrNull(l10n, error);
      }
    }

    final refreshedAccounts = ref.read(connectedOnlineAccountsProvider);
    final hasVisibleData = refreshedAccounts.any(
      (account) => account.calendars.isNotEmpty || account.events.isNotEmpty,
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _refreshingAccountIds.clear();
      _errorMessage = hasVisibleData ? null : firstError;
      _recalculateDuplicates();
    });
  }

  Future<void> _refreshAccount(
    ConnectedOnlineAccount account, {
    bool showErrorSnackBar = true,
  }) async {
    if (mounted) {
      setState(() {
        _refreshingAccountIds.add(account.accountId);
      });
    }

    try {
      final updated = await _loadAccountData(account);
      await ref
          .read(connectedOnlineAccountsProvider.notifier)
          .addOrUpdateAccount(updated);
      if (!mounted) return;
      setState(() {
        _refreshingAccountIds.remove(account.accountId);
        _recalculateDuplicates();
      });
    } catch (error) {
      if (!mounted) rethrow;
      setState(() {
        _refreshingAccountIds.remove(account.accountId);
      });
      if (showErrorSnackBar) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString(
                'onlineProvidersAccountRefreshFailed',
                params: {'account': account.accountName},
              ),
            ),
          ),
        );
      }
      rethrow;
    }
  }

  Future<ConnectedOnlineAccount> _loadAccountData(
    ConnectedOnlineAccount account,
  ) async {
    final service = ref.read(calendarSyncServiceProvider);
    switch (account.provider) {
      case OnlineProvider.google:
        final token = account.accessToken?.trim() ?? '';
        if (token.isEmpty) {
          throw CalendarSyncException(
            'Google authentication required',
            userMessage: 'onlineProvidersReconnectRequired',
            isAuthError: true,
          );
        }
        final calendars = await service.retrieveGoogleCalendarsWithAccessToken(
          accessToken: token,
          userEmail: account.email,
        );
        final filteredCalendars = _mainCalendarsOnly(
          OnlineProvider.google,
          calendars,
        );
        final events = await _loadGoogleEvents(
          filteredCalendars,
          token,
          ownerEmail: account.email,
        );
        final accountLabel = _resolveAccountLabel(
          provider: OnlineProvider.google,
          accountName: account.accountName,
          email: account.email,
          calendars: filteredCalendars,
        );
        return account.copyWith(
          accountName: accountLabel,
          calendars: filteredCalendars,
          events: events,
          lastSyncedAt: DateTime.now(),
        );
      case OnlineProvider.outlook:
        return _loadOutlookAccountData(account, service);
      case OnlineProvider.apple:
        final url = account.applePublicCalendarUrl?.trim() ?? '';
        if (url.isEmpty) {
          throw CalendarSyncException(
            'Apple calendar URL required',
            userMessage: 'calendarSyncApplePublicUrlRequired',
          );
        }
        final calendars = await service.retrieveApplePublicCalendars(url);
        final events = await _loadAppleEvents(
          url,
          calendars,
          ownerEmail: account.email,
        );
        final accountLabel = _resolveAccountLabel(
          provider: OnlineProvider.apple,
          accountName: account.accountName,
          email: account.email,
          calendars: calendars,
        );
        return account.copyWith(
          accountName: accountLabel,
          calendars: calendars,
          events: events,
          lastSyncedAt: DateTime.now(),
        );
    }
  }

  Future<ConnectedOnlineAccount> _loadOutlookAccountData(
    ConnectedOnlineAccount account,
    CalendarSyncService service,
  ) async {
    final preferredEmail = _preferredOutlookEmail(account);
    var token = account.accessToken?.trim() ?? '';
    var expiry = account.accessTokenExpiry;
    var resolvedEmail = account.email?.trim();

    if (token.isEmpty || _isTokenExpired(expiry)) {
      final payload = await _authenticateOutlookAccount(
        service,
        preferredEmail: preferredEmail,
      );
      token = payload.$1;
      expiry = payload.$2;
      resolvedEmail = payload.$3;
    }

    try {
      return await _buildOutlookAccountData(
        account,
        service: service,
        accessToken: token,
        accessTokenExpiry: expiry,
        resolvedEmail: resolvedEmail,
      );
    } on CalendarSyncException catch (error) {
      if (!error.isAuthError) {
        rethrow;
      }
      final payload = await _authenticateOutlookAccount(
        service,
        preferredEmail: preferredEmail,
      );
      return _buildOutlookAccountData(
        account,
        service: service,
        accessToken: payload.$1,
        accessTokenExpiry: payload.$2,
        resolvedEmail: payload.$3,
      );
    }
  }

  Future<ConnectedOnlineAccount> _buildOutlookAccountData(
    ConnectedOnlineAccount account, {
    required CalendarSyncService service,
    required String accessToken,
    required DateTime? accessTokenExpiry,
    required String? resolvedEmail,
  }) async {
    if (accessToken.trim().isEmpty) {
      throw CalendarSyncException(
        'Outlook authentication required',
        userMessage: 'onlineProvidersReconnectRequired',
        isAuthError: true,
      );
    }
    final calendars = await service.retrieveOutlookCalendarsWithAccessToken(
      accessToken: accessToken,
      userEmail: resolvedEmail,
    );
    final filteredCalendars = _mainCalendarsOnly(
      OnlineProvider.outlook,
      calendars,
    );
    final events = await _loadOutlookEvents(
      filteredCalendars,
      accessToken,
      ownerEmail: resolvedEmail,
    );
    final accountLabel = _resolveAccountLabel(
      provider: OnlineProvider.outlook,
      accountName: account.accountName,
      email: resolvedEmail,
      calendars: filteredCalendars,
    );
    return account.copyWith(
      accountName: accountLabel,
      email: resolvedEmail,
      calendars: filteredCalendars,
      events: events,
      accessToken: accessToken,
      accessTokenExpiry: accessTokenExpiry,
      lastSyncedAt: DateTime.now(),
    );
  }

  Future<(String, DateTime?, String?)> _authenticateOutlookAccount(
    CalendarSyncService service, {
    required String? preferredEmail,
  }) async {
    final payload = await service.authenticateOutlookImportAccount(
      allowNonWeb: true,
      preferredUserEmail: preferredEmail,
    );
    final token = (payload?['token'] as String?)?.trim() ?? '';
    if (token.isEmpty) {
      throw CalendarSyncException(
        'Outlook authentication required',
        userMessage: 'onlineProvidersReconnectRequired',
        isAuthError: true,
      );
    }
    final resolvedEmail =
        (payload?['userEmail'] as String?)?.trim().isNotEmpty == true
        ? (payload!['userEmail'] as String).trim()
        : preferredEmail;
    if (preferredEmail != null &&
        preferredEmail.isNotEmpty &&
        resolvedEmail != null &&
        resolvedEmail.isNotEmpty &&
        resolvedEmail.toLowerCase() != preferredEmail.toLowerCase()) {
      throw CalendarSyncException(
        'Outlook authentication returned a different account: $resolvedEmail',
        userMessage: 'onlineProvidersReconnectRequired',
        isAuthError: true,
      );
    }
    return (token, payload?['expiry'] as DateTime?, resolvedEmail);
  }

  String? _preferredOutlookEmail(ConnectedOnlineAccount account) {
    final candidates = <String?>[
      account.email,
      account.accountName,
      ...account.calendars.map((calendar) => calendar.accountName),
    ];
    for (final candidate in candidates) {
      final normalized = candidate?.trim();
      if (normalized != null &&
          normalized.isNotEmpty &&
          normalized.contains('@')) {
        return normalized;
      }
    }
    return account.email?.trim().isNotEmpty == true
        ? account.email!.trim()
        : null;
  }

  bool _isTokenExpired(DateTime? expiry) {
    if (expiry == null) {
      return false;
    }
    return DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 1)));
  }

  Future<List<EventModel>> _loadGoogleEvents(
    List<ExternalCalendar> calendars,
    String accessToken, {
    String? ownerEmail,
  }) async {
    final service = ref.read(calendarSyncServiceProvider);
    final events = <EventModel>[];
    final mainCalendars = _mainCalendarsOnly(OnlineProvider.google, calendars);
    for (final calendar in mainCalendars) {
      final externalEvents = await service.retrieveGoogleEventsWithAccessToken(
        calendar.id,
        accessToken: accessToken,
      );
      events.addAll(
        externalEvents.map(
          (event) => _toEventModel(
            event,
            calendar: calendar,
            provider: OnlineProvider.google,
            ownerEmail: ownerEmail,
          ),
        ),
      );
    }
    return _filterVisibleOnlineProviderEvents(events);
  }

  Future<List<EventModel>> _loadOutlookEvents(
    List<ExternalCalendar> calendars,
    String accessToken, {
    String? ownerEmail,
  }) async {
    final service = ref.read(calendarSyncServiceProvider);
    final events = <EventModel>[];
    final mainCalendars = _mainCalendarsOnly(OnlineProvider.outlook, calendars);
    for (final calendar in mainCalendars) {
      final externalEvents = await service.retrieveOutlookEventsWithAccessToken(
        calendar.id,
        accessToken: accessToken,
      );
      events.addAll(
        externalEvents.map(
          (event) => _toEventModel(
            event,
            calendar: calendar,
            provider: OnlineProvider.outlook,
            ownerEmail: ownerEmail,
          ),
        ),
      );
    }
    return _filterVisibleOnlineProviderEvents(events);
  }

  Future<List<EventModel>> _loadAppleEvents(
    String publicCalendarUrl,
    List<ExternalCalendar> calendars, {
    String? ownerEmail,
  }) async {
    final service = ref.read(calendarSyncServiceProvider);
    final events = await service.retrieveApplePublicEvents(publicCalendarUrl);
    final calendar = calendars.isNotEmpty
        ? calendars.first
        : ExternalCalendar(
            id: publicCalendarUrl,
            name: publicCalendarUrl,
            isReadOnly: true,
            isDefault: true,
            accountName: publicCalendarUrl,
            accountType: 'apple_public_ics',
          );
    final mapped = events
        .map(
          (event) => _toEventModel(
            event,
            calendar: calendar,
            provider: OnlineProvider.apple,
            ownerEmail: ownerEmail,
          ),
        )
        .toList();
    return _filterVisibleOnlineProviderEvents(mapped);
  }

  EventModel _toEventModel(
    ExternalEvent event, {
    required ExternalCalendar calendar,
    required OnlineProvider provider,
    String? ownerEmail,
  }) {
    final start = event.start ?? DateTime.now();
    final end =
        event.end ??
        event.start?.add(const Duration(hours: 1)) ??
        DateTime.now().add(const Duration(hours: 1));
    final blockReason = classifyExternalEventImport(
      event,
      provider: provider.name,
      ownerEmail: ownerEmail,
    );
    return EventModel(
      id: event.id.trim().isNotEmpty
          ? event.id.trim()
          : _createEventKey(
              event.title,
              start,
              endTime: end,
              isAllDay: event.isAllDay,
            ),
      eventName: event.title.trim().isNotEmpty
          ? event.title.trim()
          : ref.read(localizationProvider).getString('eventNoTitle'),
      eventVenue: event.location,
      startTime: start,
      endTime: end,
      eventLink: event.url?.toString(),
      description: event.description,
      externalCalendarId: calendar.id,
      externalEventId: event.id,
      externalProvider: provider.name,
      isAllDay: event.isAllDay,
      markedPrivateInSource: isMarkedPrivateInSourceCalendar(
        availability: event.availability,
        transparency: event.transparency,
        visibility: event.visibility,
        sensitivity: event.sensitivity,
      ),
      importBlockReason: blockReason.importable ? null : blockReason.name,
    );
  }

  bool _isHolidayOrSpecialCalendar(ExternalCalendar calendar) {
    final name = calendar.name.toLowerCase();
    return name.contains('holiday') ||
        name.contains('holidays') ||
        name.contains('observance') ||
        name.contains('birthday') ||
        name.contains('birthdays') ||
        name.contains('phases of the moon') ||
        name.contains('week numbers');
  }

  List<ExternalCalendar> _mainCalendarsOnly(
    OnlineProvider provider,
    List<ExternalCalendar> calendars,
  ) {
    if (provider == OnlineProvider.apple || calendars.isEmpty) {
      return calendars;
    }

    final defaults = calendars.where((calendar) => calendar.isDefault).toList();
    if (defaults.isNotEmpty) {
      return defaults;
    }

    final nonSpecial = calendars
        .where((calendar) => !_isHolidayOrSpecialCalendar(calendar))
        .toList();
    if (nonSpecial.isEmpty) {
      return calendars.take(1).toList();
    }

    final writable = nonSpecial
        .where((calendar) => !calendar.isReadOnly)
        .toList();
    if (writable.isNotEmpty) {
      return writable.take(1).toList();
    }

    return nonSpecial.take(1).toList();
  }

  String _normalizeAccountIdentifier(String raw) {
    return raw.trim().toLowerCase();
  }

  String _buildAccountId(OnlineProvider provider, String identifier) {
    return '${provider.name}:${_normalizeAccountIdentifier(identifier)}';
  }

  void _throwIfAccountAlreadyConnected(
    OnlineProvider provider,
    String identifier,
  ) {
    final accountId = _buildAccountId(provider, identifier);
    final alreadyConnected = ref
        .read(connectedOnlineAccountsProvider.notifier)
        .containsAccount(provider, accountId);
    if (alreadyConnected) {
      throw CalendarSyncException(
        'Account already connected: $accountId',
        userMessage: 'onlineProvidersAccountAlreadyAdded',
      );
    }
  }

  String _resolveAccountLabel({
    required OnlineProvider provider,
    required String accountName,
    required String? email,
    required List<ExternalCalendar> calendars,
  }) {
    if (email?.trim().isNotEmpty == true) {
      return email!.trim();
    }
    if (accountName.trim().isNotEmpty) {
      return accountName.trim();
    }
    final calendarAccountName = calendars.isNotEmpty
        ? calendars.first.accountName?.trim()
        : null;
    if (calendarAccountName != null && calendarAccountName.isNotEmpty) {
      return calendarAccountName;
    }
    final l10n = ref.read(localizationProvider);
    switch (provider) {
      case OnlineProvider.google:
        return l10n.getString('eventsImportGoogle');
      case OnlineProvider.outlook:
        return l10n.getString('eventsImportOutlook');
      case OnlineProvider.apple:
        return l10n.getString('eventsImportApple');
    }
  }

  Future<void> _showAddAccountDialog() async {
    final l10n = ref.read(localizationProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(l10n.getString('onlineProvidersAddAccount')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProviderButton(
                label: l10n.getString('eventsImportGoogle'),
                assetPath: 'assets/images/providers/google.png',
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _addGoogleAccount(forceAccountSelection: true);
                },
              ),
              const SizedBox(height: 12),
              _buildProviderButton(
                label: l10n.getString('eventsImportOutlook'),
                assetPath: 'assets/images/providers/microsoft.png',
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _addOutlookAccount();
                },
              ),
              const SizedBox(height: 12),
              _buildProviderButton(
                label: l10n.getString('eventsImportApple'),
                assetPath: 'assets/images/providers/apple.png',
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _addAppleAccount();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.getString('cancel')),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProviderButton({
    required String label,
    String? assetPath,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: Text(label, textAlign: TextAlign.center)),
          if (assetPath != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 20,
              height: 20,
              child: Image.asset(
                assetPath,
                fit: BoxFit.contain,
                errorBuilder:
                    (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) {
                      return const SizedBox.shrink();
                    },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _addGoogleAccount({
    bool forceAccountSelection = false,
    Map<String, dynamic>? existingPayload,
    String? preferredEmail,
  }) async {
    final l10n = ref.read(localizationProvider);
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final service = ref.read(calendarSyncServiceProvider);
      final payload =
          existingPayload ??
          await service.authenticateGoogleImportAccount(
            forceAccountSelection: forceAccountSelection,
          );
      if (payload == null) {
        debugPrint(
          '[CalendarSync] _addGoogleAccount: payload is NULL, stopping '
          '(forceAccountSelection=$forceAccountSelection, existingPayload=${existingPayload != null})',
        );
        setState(() {
          _isLoading = false;
          // Previously this returned silently, so a failed hand-off looked
          // like the app did nothing at all. Tell the user what happened.
          _errorMessage = l10n.getString('calendarSyncGoogleAuthRequired');
        });
        return;
      }
      final token = (payload['token'] as String?)?.trim() ?? '';
      final expiry = payload['expiry'] as DateTime?;
      final email =
          (payload['userEmail'] as String?)?.trim() ?? preferredEmail?.trim();
      debugPrint(
        '[CalendarSync] _addGoogleAccount: got payload tokenLen=${token.length} '
        'expiry=$expiry email=$email',
      );
      final calendars = _mainCalendarsOnly(
        OnlineProvider.google,
        await service.retrieveGoogleCalendarsWithAccessToken(
          accessToken: token,
          userEmail: email,
        ),
      );
      debugPrint(
        '[CalendarSync] _addGoogleAccount: ${calendars.length} main calendar(s) '
        '-> ${calendars.map((c) => c.id).toList()}',
      );
      final events = await _loadGoogleEvents(
        calendars,
        token,
        ownerEmail: email,
      );
      debugPrint(
        '[CalendarSync] _addGoogleAccount: ${events.length} event(s) fetched',
      );
      final identifier = email?.isNotEmpty == true
          ? email!
          : (calendars.isNotEmpty
                ? (calendars.first.accountName ?? token)
                : token);
      _throwIfAccountAlreadyConnected(OnlineProvider.google, identifier);
      final accountId = _buildAccountId(OnlineProvider.google, identifier);
      final account = ConnectedOnlineAccount(
        provider: OnlineProvider.google,
        accountId: accountId,
        accountName: _resolveAccountLabel(
          provider: OnlineProvider.google,
          accountName: email ?? '',
          email: email,
          calendars: calendars,
        ),
        email: email,
        calendars: calendars,
        events: events,
        accessToken: token,
        accessTokenExpiry: expiry,
        lastSyncedAt: DateTime.now(),
      );
      await ref
          .read(connectedOnlineAccountsProvider.notifier)
          .addOrUpdateAccount(account);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = null;
        _recalculateDuplicates();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'onlineProvidersAccountAdded',
              params: {'account': account.accountName},
            ),
          ),
        ),
      );
    } catch (error) {
      debugPrint('[CalendarSync] _addGoogleAccount FAILED: $error');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _localizedMessageOrNull(l10n, error);
      });
      debugPrint(
        '[CalendarSync] _addGoogleAccount error shown to user: ${_errorMessage ?? '(null)'}',
      );
    }
  }

  Future<void> _addOutlookAccount({
    bool forceAccountSelection = false,
    Map<String, dynamic>? existingPayload,
    String? preferredEmail,
  }) async {
    final l10n = ref.read(localizationProvider);
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final service = ref.read(calendarSyncServiceProvider);
      final payload =
          existingPayload ??
          await service.authenticateOutlookImportAccount(
            allowNonWeb: true,
            forceAccountSelection: forceAccountSelection,
            preferredUserEmail: preferredEmail,
          );
      if (payload == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }
      final token = (payload['token'] as String?)?.trim() ?? '';
      final expiry = payload['expiry'] as DateTime?;
      final email =
          (payload['userEmail'] as String?)?.trim() ?? preferredEmail?.trim();
      final calendars = _mainCalendarsOnly(
        OnlineProvider.outlook,
        await service.retrieveOutlookCalendarsWithAccessToken(
          accessToken: token,
          userEmail: email,
        ),
      );
      final events = await _loadOutlookEvents(
        calendars,
        token,
        ownerEmail: email,
      );
      final identifier = email?.isNotEmpty == true
          ? email!
          : (calendars.isNotEmpty
                ? (calendars.first.accountName ?? token)
                : token);
      _throwIfAccountAlreadyConnected(OnlineProvider.outlook, identifier);
      final accountId = _buildAccountId(OnlineProvider.outlook, identifier);
      final account = ConnectedOnlineAccount(
        provider: OnlineProvider.outlook,
        accountId: accountId,
        accountName: _resolveAccountLabel(
          provider: OnlineProvider.outlook,
          accountName: email ?? '',
          email: email,
          calendars: calendars,
        ),
        email: email,
        calendars: calendars,
        events: events,
        accessToken: token,
        accessTokenExpiry: expiry,
        lastSyncedAt: DateTime.now(),
      );
      await ref
          .read(connectedOnlineAccountsProvider.notifier)
          .addOrUpdateAccount(account);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = null;
        _recalculateDuplicates();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'onlineProvidersAccountAdded',
              params: {'account': account.accountName},
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _localizedMessageOrNull(l10n, error);
      });
    }
  }

  Future<void> _addAppleAccount() async {
    final l10n = ref.read(localizationProvider);
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => const AppleCalendarImportScreen(),
        fullscreenDialog: true,
      ),
    );

    if (url == null || url.trim().isEmpty) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final service = ref.read(calendarSyncServiceProvider);
      final calendars = await service.retrieveApplePublicCalendars(url);
      final events = await _loadAppleEvents(url, calendars);
      final accountName = _resolveAccountLabel(
        provider: OnlineProvider.apple,
        accountName: calendars.isNotEmpty ? calendars.first.name : url,
        email: null,
        calendars: calendars,
      );
      final account = ConnectedOnlineAccount(
        provider: OnlineProvider.apple,
        accountId: _buildAccountId(OnlineProvider.apple, url),
        accountName: accountName,
        calendars: calendars,
        events: events,
        applePublicCalendarUrl: url,
        lastSyncedAt: DateTime.now(),
      );
      await ref
          .read(connectedOnlineAccountsProvider.notifier)
          .addOrUpdateAccount(account);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = null;
        _recalculateDuplicates();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'onlineProvidersAccountAdded',
              params: {'account': account.accountName},
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _localizedMessageOrNull(l10n, error);
      });
    }
  }

  /// Provider name alone, for contexts that should not be resolved to a
  /// specific account (e.g. the remove-confirmation dialog).
  String _providerName(OnlineProvider provider) {
    final l10n = ref.read(localizationProvider);
    switch (provider) {
      case OnlineProvider.google:
        return l10n.getString('eventsImportGoogle');
      case OnlineProvider.outlook:
        return l10n.getString('eventsImportOutlook');
      case OnlineProvider.apple:
        return l10n.getString('eventsImportApple');
    }
  }

  Future<void> _removeAccount(ConnectedOnlineAccount account) async {
    final l10n = ref.read(localizationProvider);
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.getString('onlineProvidersRemoveAccount')),
          content: Text(
            l10n.getString(
              'onlineProvidersRemoveAccountConfirm',
              // Name the provider as well as the account: two Google accounts
              // look identical in the list, and this is the dialog that cuts
              // off access to someone's calendar.
              params: {
                'account':
                    '${_providerName(account.provider)} · ${account.accountName}',
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.getString('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.getString('remove')),
            ),
          ],
        );
      },
    );
    if (shouldRemove != true) return;

    await ref
        .read(connectedOnlineAccountsProvider.notifier)
        .removeAccount(account.provider, account.accountId);

    // Drop the cached provider credentials once the last account of that
    // provider is gone.
    //
    // Each ConnectedOnlineAccount carries its own access token, so removing the
    // entry discards that copy. But CalendarSyncService *also* keeps a single
    // "most recently used" token per provider in secure storage, and that copy
    // used to survive the removal - so a disconnected calendar left a live
    // access token on the device, and a later import could silently reuse it.
    //
    // Only cleared when no other account of the same provider remains, so
    // removing one of several Google accounts does not disturb the rest.
    final stillHasProvider = ref
        .read(connectedOnlineAccountsProvider)
        .any((a) => a.provider == account.provider);
    if (!stillHasProvider) {
      switch (account.provider) {
        case OnlineProvider.google:
          await CalendarSyncService.clearGoogleImportTokenCache();
          debugPrint(
            '[CalendarSync] cleared cached Google credentials after removing '
            'the last Google account',
          );
        case OnlineProvider.outlook:
          await CalendarSyncService.clearOutlookImportTokenCache();
          debugPrint(
            '[CalendarSync] cleared cached Outlook credentials after removing '
            'the last Outlook account',
          );
        case OnlineProvider.apple:
          // Apple Calendar uses a public .ics URL rather than OAuth, so there
          // are no credentials to revoke. The URL went with the removed entry.
          break;
      }
    }

    if (!mounted) return;
    setState(() {
      _selectedEventKeys.removeWhere(
        (key) => key.startsWith('${account.accountId}::'),
      );
      if (_selectedAccountFilterId == account.accountId) {
        _selectedAccountFilterId = null;
      }
      _recalculateDuplicates();
    });
  }

  Future<void> _importSelectedEvents() async {
    final accounts = ref.read(connectedOnlineAccountsProvider);
    final selectedEntries = <MapEntry<ConnectedOnlineAccount, EventModel>>[];
    for (final account in accounts) {
      for (final event in account.events) {
        final key = _selectionKey(account, event);
        if (_selectedEventKeys.contains(key) &&
            _isVisibleOnlineProviderEvent(event) &&
            !_duplicateEventKeys.contains(key) &&
            _isImportableEvent(event)) {
          selectedEntries.add(MapEntry(account, event));
        }
      }
    }
    if (selectedEntries.isEmpty) return;

    final l10n = ref.read(localizationProvider);
    print(
      '[EVENT_IMPORT_UI] Starting online-provider import for ${selectedEntries.length} selected events',
    );
    setState(() {
      _isImporting = true;
    });

    final eventManager = ref.read(eventManagerProvider.notifier);
    var successCount = 0;
    final failedByReasonToken = <String, List<String>>{};

    for (final entry in selectedEntries) {
      final sourceEvent = entry.value;
      final result = await eventManager.addEventWithResult(
        EventModel(
          id: '',
          eventName: sourceEvent.eventName,
          eventVenue: sourceEvent.eventVenue,
          startTime: sourceEvent.startTime,
          endTime: sourceEvent.endTime,
          eventLink: _usableImportLink(
            sourceEvent.eventLink,
            provider: sourceEvent.externalProvider,
          ),
          description: sourceEvent.description,
          isAllDay: sourceEvent.isAllDay,
          externalCalendarId: sourceEvent.externalCalendarId,
          externalEventId: sourceEvent.externalEventId,
          externalProvider: sourceEvent.externalProvider,
          markedPrivateInSource: sourceEvent.markedPrivateInSource,
          importBlockReason: sourceEvent.importBlockReason,
        ),
      );
      if (result.success) {
        successCount++;
        print(
          '[EVENT_IMPORT_UI] Imported "${sourceEvent.eventName}" successfully',
        );
      } else {
        final reasonKey = result.errorKey ?? 'eventAddFailedUnknown';
        final diagnosticCode = result.diagnosticCode ?? '';
        print(
          '[EVENT_IMPORT_UI] Failed to import "${sourceEvent.eventName}" reasonKey=$reasonKey diagnosticCode=${diagnosticCode.isEmpty ? 'none' : diagnosticCode}',
        );
        final reasonToken = diagnosticCode.isEmpty
            ? reasonKey
            : '$reasonKey||$diagnosticCode';
        failedByReasonToken
            .putIfAbsent(reasonToken, () => <String>[])
            .add(sourceEvent.eventName);
      }
    }

    await _loadExistingEvents();

    if (!mounted) return;
    setState(() {
      _isImporting = false;
      _recalculateDuplicates();
      _selectedEventKeys.removeWhere(_duplicateEventKeys.contains);
    });
    print(
      '[EVENT_IMPORT_UI] Import finished successCount=$successCount failureCount=${failedByReasonToken.values.fold<int>(0, (sum, titles) => sum + titles.length)}',
    );

    if (failedByReasonToken.isNotEmpty) {
      final failures = failedByReasonToken.entries
          .map((entry) {
            final tokenParts = entry.key.split('||');
            final reason = l10n.getString(tokenParts.first);
            return l10n.getString(
              'calendarSyncEventImportFailed',
              params: {'title': entry.value.join(', '), 'reason': reason},
            );
          })
          .join('\n');

      final message = successCount > 0
          ? '${l10n.getString('calendarSyncSyncedEventsSuccess', params: {'count': '$successCount'})}\n$failures'
          : failures;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.getString(
            'calendarSyncSyncedEventsSuccess',
            params: {'count': '$successCount'},
          ),
        ),
      ),
    );
  }

  String _formatDateOnly(LocalizationState l10n, DateTime dateTime) {
    final locale = l10n.currentLocale.toLanguageTag();
    return DateFormat.yMMMd(locale).format(dateTime);
  }

  /// Connected accounts paired with the events that pass the current filters.
  ///
  /// Accounts are **not** dropped when they have no matching events. Doing so
  /// made account management unreachable: the remove/refresh controls live in
  /// the account section header, so an account with nothing to import - exactly
  /// the account a user is most likely to want to remove - rendered no section
  /// at all and could not be managed. `_buildAccountSection` already renders an
  /// `onlineProvidersNoEvents` placeholder for that case.
  ///
  /// Use [_visibleAccounts] instead when counting or selecting events.
  List<ConnectedOnlineAccount> _accountsWithVisibleEvents(
    List<ConnectedOnlineAccount> accounts,
  ) {
    final filteredAccounts = <ConnectedOnlineAccount>[];
    for (final account in accounts) {
      if (_selectedAccountFilterId != null &&
          account.accountId != _selectedAccountFilterId) {
        continue;
      }
      final visibleEvents = account.events.where((event) {
        if (!_isVisibleOnlineProviderEvent(event)) {
          return false;
        }
        final key = _selectionKey(account, event);
        if (_duplicateEventKeys.contains(key)) {
          return false;
        }
        if (_showOnlyPotentiallyImportable && !_isImportableEvent(event)) {
          return false;
        }
        return true;
      }).toList();
      filteredAccounts.add(account.copyWith(events: visibleEvents));
    }
    return filteredAccounts;
  }

  /// The subset of [_accountsWithVisibleEvents] that actually has events to
  /// show. Used for the summary counts and selection state, so an account with
  /// no matching events contributes nothing to either.
  List<ConnectedOnlineAccount> _visibleAccounts(
    List<ConnectedOnlineAccount> accounts,
  ) {
    return _accountsWithVisibleEvents(
      accounts,
    ).where((account) => account.events.isNotEmpty).toList();
  }

  int _visibleSelectableCount(List<ConnectedOnlineAccount> accounts) {
    var count = 0;
    for (final account in accounts) {
      for (final event in account.events) {
        if (_isImportableEvent(event)) {
          count++;
        }
      }
    }
    return count;
  }

  int _visibleSelectedCount(List<ConnectedOnlineAccount> accounts) {
    var count = 0;
    for (final account in accounts) {
      for (final event in account.events) {
        if (_selectedEventKeys.contains(_selectionKey(account, event))) {
          count++;
        }
      }
    }
    return count;
  }

  void _toggleSelectVisible(List<ConnectedOnlineAccount> accounts) {
    final selectableKeys = <String>{};
    for (final account in accounts) {
      for (final event in account.events) {
        final key = _selectionKey(account, event);
        if (_isImportableEvent(event)) {
          selectableKeys.add(key);
        }
      }
    }
    setState(() {
      final allSelected =
          selectableKeys.isNotEmpty &&
          selectableKeys.every(_selectedEventKeys.contains);
      if (allSelected) {
        _selectedEventKeys.removeAll(selectableKeys);
      } else {
        _selectedEventKeys.addAll(selectableKeys);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final accounts = ref.watch(connectedOnlineAccountsProvider);
    // Every account matching the account filter is rendered, even with no
    // matching events, so its remove/refresh controls stay reachable.
    final managedAccounts = _accountsWithVisibleEvents(accounts);
    final visibleAccounts = _visibleAccounts(accounts);
    final visibleSelectableCount = _visibleSelectableCount(visibleAccounts);
    final visibleSelectedCount = _visibleSelectedCount(visibleAccounts);
    final hasAccounts = accounts.isNotEmpty;
    final visibleEventCount = visibleAccounts.fold<int>(
      0,
      (total, account) => total + account.events.length,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('eventsImportOnlineProviders')),
        actions: [
          IconButton(
            onPressed: hasAccounts ? () => _refreshAllAccounts() : null,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.getString('refresh'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddAccountDialog,
        icon: const Icon(Icons.add),
        label: Text(l10n.getString('onlineProvidersAddAccount')),
      ),
      bottomNavigationBar: hasAccounts
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton(
                  onPressed: _isImporting || _selectedEventKeys.isEmpty
                      ? null
                      : _importSelectedEvents,
                  child: _isImporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          l10n.getString(
                            'onlineProvidersImportSelected',
                            params: {
                              'count': l10n.formatCount(
                                _selectedEventKeys.length,
                              ),
                            },
                          ),
                        ),
                ),
              ),
            )
          : null,
      body: _isLoading && !hasAccounts
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshAllAccounts,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                children: [
                  if (_errorMessage != null) ...[
                    _buildErrorBanner(l10n, _errorMessage!),
                    const SizedBox(height: 12),
                  ],
                  if (!hasAccounts)
                    _buildEmptyState(l10n)
                  else ...[
                    _buildSummaryCard(
                      l10n,
                      accountCount: accounts.length,
                      eventCount: visibleEventCount,
                      selectedCount: _selectedEventKeys.length,
                    ),
                    const SizedBox(height: 12),
                    _buildAccountFilters(l10n, accounts),
                    const SizedBox(height: 12),
                    _buildVisibilityFilters(l10n),
                    const SizedBox(height: 12),
                    _buildSelectionRow(
                      l10n,
                      visibleAccounts,
                      visibleSelectableCount,
                      visibleSelectedCount,
                    ),
                    const SizedBox(height: 12),
                    if (managedAccounts.isEmpty)
                      _buildNoFilterResults(l10n)
                    else
                      ...managedAccounts.map(
                        (account) => Padding(
                          padding: const EdgeInsets.only(
                            bottom: _accountSectionSpacing,
                          ),
                          child: _buildAccountSection(account, l10n),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildErrorBanner(LocalizationState l10n, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: _refreshAllAccounts,
            child: Text(l10n.getString('retry')),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(
    LocalizationState l10n, {
    required int accountCount,
    required int eventCount,
    required int selectedCount,
  }) {
    return Container(
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
              'onlineProvidersSummaryBody',
              params: {
                'accounts': l10n.formatCount(accountCount),
                'events': l10n.formatCount(eventCount),
                'selected': l10n.formatCount(selectedCount),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountFilters(
    LocalizationState l10n,
    List<ConnectedOnlineAccount> accounts,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: Text(l10n.getString('onlineProvidersAllAccounts')),
          selected: _selectedAccountFilterId == null,
          avatar: Icon(
            Icons.apps_rounded,
            size: 18,
            color: _selectedAccountFilterId == null
                ? colorScheme.onSecondaryContainer
                : colorScheme.onSurfaceVariant,
          ),
          selectedColor: colorScheme.secondaryContainer,
          onSelected: (_) {
            setState(() {
              _selectedAccountFilterId = null;
            });
          },
        ),
        ...accounts.map(
          (account) => ChoiceChip(
            label: Text(account.accountName, overflow: TextOverflow.visible),
            avatar: CircleAvatar(
              radius: 10,
              backgroundColor: _accountAccentColor(account),
              child: Icon(
                _providerIcon(account.provider),
                size: 12,
                color: _onAccountAccentColor(account),
              ),
            ),
            selected: _selectedAccountFilterId == account.accountId,
            selectedColor: _accountBackgroundColor(account, selected: true),
            side: BorderSide(
              color: _accountBorderColor(
                account,
                selected: _selectedAccountFilterId == account.accountId,
              ),
            ),
            onSelected: (_) {
              setState(() {
                _selectedAccountFilterId = account.accountId;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildVisibilityFilters(LocalizationState l10n) {
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

  Widget _buildSelectionRow(
    LocalizationState l10n,
    List<ConnectedOnlineAccount> visibleAccounts,
    int visibleSelectableCount,
    int visibleSelectedCount,
  ) {
    final allVisibleSelected =
        visibleSelectableCount > 0 &&
        visibleSelectedCount == visibleSelectableCount;
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.getString(
              'onlineProvidersSelectionSummary',
              params: {
                'selected': l10n.formatCount(visibleSelectedCount),
                'available': l10n.formatCount(visibleSelectableCount),
              },
            ),
          ),
        ),
        TextButton(
          onPressed: visibleSelectableCount == 0
              ? null
              : () => _toggleSelectVisible(visibleAccounts),
          child: Text(
            allVisibleSelected
                ? l10n.getString('calendarSyncDeselectAll')
                : l10n.getString('calendarSyncSelectAll'),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(LocalizationState l10n) {
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Center(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
              ),
              child: Icon(
                Icons.cloud_sync_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.getString('onlineProvidersNoAccounts'),
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.getString('onlineProvidersAddAccountHint'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoFilterResults(LocalizationState l10n) {
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Center(
        child: Text(l10n.getString('calendarSyncNoEventsMatchFilters')),
      ),
    );
  }

  String _accountIdentifier(ConnectedOnlineAccount account) {
    return account.email?.trim().isNotEmpty == true
        ? account.email!.trim()
        : account.accountName;
  }

  String _buildAccountEventCountText(
    LocalizationState l10n,
    ConnectedOnlineAccount account,
  ) {
    final count = account.events.length;
    final countText = l10n.formatCount(count);
    final eventWord = count == 1
        ? l10n.getString('onlineProvidersEventSingular')
        : l10n.getString('onlineProvidersEvents');
    if (l10n.currentLocale.languageCode == 'he' && count == 1) {
      return '$eventWord $countText';
    }
    return '$countText $eventWord';
  }

  Widget _buildAccountSection(
    ConnectedOnlineAccount account,
    LocalizationState l10n,
  ) {
    final isRefreshing = _refreshingAccountIds.contains(account.accountId);
    final accountAccentColor = _accountAccentColor(account);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: _accountBackgroundColor(account),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _accountBorderColor(account)),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: accountAccentColor,
                  child: Icon(
                    _providerIcon(account.provider),
                    color: _onAccountAccentColor(account),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _accountIdentifier(account),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _buildAccountEventCountText(l10n, account),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isRefreshing)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          accountAccentColor,
                        ),
                      ),
                    ),
                  ),
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'refresh') {
                      try {
                        await _refreshAccount(account);
                      } catch (_) {}
                    } else if (value == 'remove') {
                      await _removeAccount(account);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'refresh',
                      child: Text(l10n.getString('refresh')),
                    ),
                    PopupMenuItem<String>(
                      value: 'remove',
                      child: Text(l10n.getString('remove')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (account.events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.getString('onlineProvidersNoEvents')),
          )
        else ...[
          const SizedBox(height: 2),
          ...account.events.map(
            (event) => _buildEventCard(account, event, l10n),
          ),
        ],
      ],
    );
  }

  Future<void> _openEventLink(
    BuildContext context,
    LocalizationState l10n,
    String rawUrl,
  ) async {
    final uri = Uri.tryParse(rawUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty) {
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
    if (!launched) _showEventLinkOpenFailed(context, l10n, rawUrl);
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
          onPressed: () {
            _openEventLink(context, l10n, rawUrl);
          },
        ),
      ),
    );
  }

  Widget _buildEventCard(
    ConnectedOnlineAccount account,
    EventModel event,
    LocalizationState l10n,
  ) {
    final selectionKey = _selectionKey(account, event);
    final isDuplicate = _duplicateEventKeys.contains(selectionKey);
    final isSelected = _selectedEventKeys.contains(selectionKey);
    final blockReason = _blockReasonForEvent(event);
    final isImportable = blockReason.importable;
    final enabled = !isDuplicate && isImportable;
    final usableEventLink = _usableImportLink(
      event.eventLink,
      provider: event.externalProvider,
    );
    final location = event.eventVenue?.trim();
    final hasLocation = location != null && location.isNotEmpty;
    final showMap = hasLocation && !isVirtualMeetingLocation(location);
    final hasLink = usableEventLink.isNotEmpty;

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
        excludeFromSemantics: true,
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
              _selectedEventKeys.remove(selectionKey);
            } else {
              _selectedEventKeys.add(selectionKey);
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      event.eventName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: event.eventName.isRtl()
                          ? TextAlign.right
                          : TextAlign.left,
                      textDirection: event.eventName.isRtl()
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
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade800,
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
                l10n.getString('eventDateLabel'),
                _formatDateOnly(l10n, event.startTime),
              ),
              if (!event.isAllDay) ...[
                const SizedBox(height: 4),
                _buildDetailRow(
                  l10n.getString('eventTimeLabel'),
                  formatTimeOfDateTimeWithPrefs(
                    context,
                    ref,
                    l10n,
                    event.startTime,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              _buildDetailRow(
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
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (hasLink)
                    TextButton.icon(
                      onPressed: () async {
                        await _openEventLink(context, l10n, usableEventLink);
                      },
                      icon: const Icon(Icons.link, size: 18),
                      label: Text(l10n.getString('eventViewDetails')),
                    ),
                  if (showMap) ...[
                    IconButton(
                      tooltip: l10n.getString('eventOpenInMaps'),
                      onPressed: enabled
                          ? () async {
                              final success = await openGoogleMaps(location);
                              if (!success && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.getString('errorCouldNotOpenMaps'),
                                    ),
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.error,
                                  ),
                                );
                              }
                            }
                          : null,
                      padding: const EdgeInsets.all(12),
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer.withValues(alpha: 0.3),
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        side: BorderSide(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.5),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.map_outlined, size: 20),
                    ),
                  ],
                  const Spacer(),
                  Checkbox(
                    value: isSelected,
                    semanticLabel: event.eventName,
                    onChanged: enabled
                        ? (selected) {
                            setState(() {
                              if (selected == true) {
                                _selectedEventKeys.add(selectionKey);
                              } else {
                                _selectedEventKeys.remove(selectionKey);
                              }
                            });
                          }
                        : null,
                  ),
                ],
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

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(value)),
      ],
    );
  }

  IconData _providerIcon(OnlineProvider provider) {
    switch (provider) {
      case OnlineProvider.google:
        return Icons.mail_outline;
      case OnlineProvider.outlook:
        return Icons.calendar_today_outlined;
      case OnlineProvider.apple:
        return Icons.apple;
    }
  }

  int _stableColorHash(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  Color _accountAccentColor(ConnectedOnlineAccount account) {
    final hash = _stableColorHash(account.accountId);
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

  Color _onAccountAccentColor(ConnectedOnlineAccount account) {
    final brightness = ThemeData.estimateBrightnessForColor(
      _accountAccentColor(account),
    );
    return brightness == Brightness.dark ? Colors.white : Colors.black87;
  }

  Color _accountBackgroundColor(
    ConnectedOnlineAccount account, {
    bool selected = false,
  }) {
    final accentColor = _accountAccentColor(account);
    final baseOpacity = selected ? 0.22 : 0.10;
    final darkModeBoost = Theme.of(context).brightness == Brightness.dark
        ? 0.08
        : 0.0;
    return accentColor.withValues(alpha: baseOpacity + darkModeBoost);
  }

  Color _accountBorderColor(
    ConnectedOnlineAccount account, {
    bool selected = false,
  }) {
    final accentColor = _accountAccentColor(account);
    return accentColor.withValues(alpha: selected ? 0.55 : 0.26);
  }
}
