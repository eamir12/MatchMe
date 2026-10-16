import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum OnlineProvider { google, outlook, apple }

const _connectedOnlineAccountsStorageKey = 'connected_online_accounts';

Map<String, dynamic> externalCalendarToJson(ExternalCalendar calendar) {
  return {
    'id': calendar.id,
    'name': calendar.name,
    'isReadOnly': calendar.isReadOnly,
    'isDefault': calendar.isDefault,
    'accountName': calendar.accountName,
    'accountType': calendar.accountType,
  };
}

ExternalCalendar externalCalendarFromJson(Map<String, dynamic> json) {
  return ExternalCalendar(
    id: (json['id'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    isReadOnly: json['isReadOnly'] == true,
    isDefault: json['isDefault'] == true,
    accountName: (json['accountName'] as String?) ?? '',
    accountType: (json['accountType'] as String?) ?? '',
  );
}

Map<String, dynamic> eventModelToStoredJson(EventModel event) {
  return {
    'id': event.id,
    'eventName': event.eventName,
    'eventVenue': event.eventVenue,
    'startTime': event.startTime.toIso8601String(),
    'endTime': event.endTime.toIso8601String(),
    'eventLink': event.eventLink,
    'notes': event.notes,
    'attendeeCount': event.attendeeCount,
    'externalCalendarId': event.externalCalendarId,
    'externalEventId': event.externalEventId,
    'externalProvider': event.externalProvider,
    'isAllDay': event.isAllDay,
    'description': event.description,
    'markedPrivateInSource': event.markedPrivateInSource,
    'importBlockReason': event.importBlockReason,
  };
}

EventModel eventModelFromStoredJson(Map<String, dynamic> json) {
  final rawAttendeeCount = json['attendeeCount'] ?? json['attendee_count'];
  final attendeeCount = rawAttendeeCount is num
      ? rawAttendeeCount.toInt()
      : int.tryParse('${rawAttendeeCount ?? ''}');
  final startRaw =
      (json['startTime'] ?? json['start_time']) as String? ??
      DateTime.now().toIso8601String();
  final endRaw = (json['endTime'] ?? json['end_time']) as String? ?? startRaw;
  return EventModel(
    id: (json['id'] as String?) ?? '',
    eventName: (json['eventName'] ?? json['event_name']) as String? ?? '',
    eventVenue: (json['eventVenue'] ?? json['event_venue']) as String?,
    startTime: DateTime.tryParse(startRaw) ?? DateTime.now(),
    endTime:
        DateTime.tryParse(endRaw) ??
        (DateTime.tryParse(startRaw) ?? DateTime.now()),
    eventLink: (json['eventLink'] ?? json['event_link']) as String?,
    notes: json['notes'] as String?,
    attendeeCount: attendeeCount,
    externalCalendarId:
        (json['externalCalendarId'] ?? json['external_calendar_id']) as String?,
    externalEventId:
        (json['externalEventId'] ?? json['external_event_id']) as String?,
    externalProvider:
        (json['externalProvider'] ?? json['external_provider']) as String?,
    isAllDay: (json['isAllDay'] ?? json['is_all_day']) == true,
    description: json['description'] as String?,
    markedPrivateInSource: (json['markedPrivateInSource'] as bool?) ?? false,
    importBlockReason: json['importBlockReason'] as String?,
  );
}

class ConnectedOnlineAccount {
  final OnlineProvider provider;
  final String accountId;
  final String accountName;
  final String? email;
  final List<ExternalCalendar> calendars;
  final List<EventModel> events;
  final String? accessToken;
  final DateTime? accessTokenExpiry;
  final String? applePublicCalendarUrl;
  final DateTime? lastSyncedAt;

  const ConnectedOnlineAccount({
    required this.provider,
    required this.accountId,
    required this.accountName,
    this.email,
    required this.calendars,
    required this.events,
    this.accessToken,
    this.accessTokenExpiry,
    this.applePublicCalendarUrl,
    this.lastSyncedAt,
  });

  ConnectedOnlineAccount copyWith({
    OnlineProvider? provider,
    String? accountId,
    String? accountName,
    String? email,
    List<ExternalCalendar>? calendars,
    List<EventModel>? events,
    String? accessToken,
    DateTime? accessTokenExpiry,
    String? applePublicCalendarUrl,
    DateTime? lastSyncedAt,
    bool clearAccessToken = false,
    bool clearAccessTokenExpiry = false,
    bool clearApplePublicCalendarUrl = false,
    bool clearLastSyncedAt = false,
  }) {
    return ConnectedOnlineAccount(
      provider: provider ?? this.provider,
      accountId: accountId ?? this.accountId,
      accountName: accountName ?? this.accountName,
      email: email ?? this.email,
      calendars: calendars ?? this.calendars,
      events: events ?? this.events,
      accessToken: clearAccessToken ? null : accessToken ?? this.accessToken,
      accessTokenExpiry: clearAccessTokenExpiry
          ? null
          : accessTokenExpiry ?? this.accessTokenExpiry,
      applePublicCalendarUrl: clearApplePublicCalendarUrl
          ? null
          : applePublicCalendarUrl ?? this.applePublicCalendarUrl,
      lastSyncedAt: clearLastSyncedAt
          ? null
          : lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider': provider.index,
      'accountId': accountId,
      'accountName': accountName,
      'email': email,
      'calendars': calendars.map(externalCalendarToJson).toList(),
      'events': events.map(eventModelToStoredJson).toList(),
      'accessToken': accessToken,
      'accessTokenExpiry': accessTokenExpiry?.toIso8601String(),
      'applePublicCalendarUrl': applePublicCalendarUrl,
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    };
  }

  factory ConnectedOnlineAccount.fromJson(Map<String, dynamic> json) {
    return ConnectedOnlineAccount(
      provider: OnlineProvider.values[(json['provider'] as int?) ?? 0],
      accountId: (json['accountId'] as String?) ?? '',
      accountName: (json['accountName'] as String?) ?? '',
      email: json['email'] as String?,
      calendars: ((json['calendars'] as List<dynamic>?) ?? const [])
          .map(
            (calendar) =>
                externalCalendarFromJson(calendar as Map<String, dynamic>),
          )
          .toList(),
      events: ((json['events'] as List<dynamic>?) ?? const [])
          .map(
            (event) => eventModelFromStoredJson(event as Map<String, dynamic>),
          )
          .toList(),
      accessToken: json['accessToken'] as String?,
      accessTokenExpiry: DateTime.tryParse(
        (json['accessTokenExpiry'] as String?) ?? '',
      ),
      applePublicCalendarUrl: json['applePublicCalendarUrl'] as String?,
      lastSyncedAt: DateTime.tryParse((json['lastSyncedAt'] as String?) ?? ''),
    );
  }
}

class ConnectedOnlineAccountsNotifier
    extends Notifier<List<ConnectedOnlineAccount>> {
  bool _didLoadAccounts = false;

  @override
  List<ConnectedOnlineAccount> build() {
    if (!_didLoadAccounts) {
      _didLoadAccounts = true;
      Future<void>(_loadAccounts);
    }
    return <ConnectedOnlineAccount>[];
  }

  Future<void> _loadAccounts() async {
    final accountsJson = await _readAccountsJson();
    if (accountsJson == null || accountsJson.isEmpty) {
      state = [];
      return;
    }
    try {
      final decoded = jsonDecode(accountsJson) as List<dynamic>;
      state = decoded
          .map(
            (item) =>
                ConnectedOnlineAccount.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      print('Error loading connected online accounts: $e');
      state = [];
    }
  }

  /// Read connected accounts JSON from SecureStorage, falling back to legacy
  /// plain SharedPreferences. The blob contains OAuth access tokens.
  static Future<String?> _readAccountsJson() async {
    try {
      final stored = await SecureStorageService.instance.read(
        _connectedOnlineAccountsStorageKey,
      );
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_connectedOnlineAccountsStorageKey);
    } catch (_) {}
    return null;
  }

  /// Persist connected accounts JSON to SecureStorage and remove any legacy
  /// plain SharedPreferences copy.
  static Future<void> _writeAccountsJson(String accountsJson) async {
    try {
      await SecureStorageService.instance.write(
        _connectedOnlineAccountsStorageKey,
        accountsJson,
      );
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_connectedOnlineAccountsStorageKey)) {
        await prefs.remove(_connectedOnlineAccountsStorageKey);
      }
    } catch (_) {}
  }

  Future<void> _saveAccounts() async {
    final accountsJson = jsonEncode(
      state.map((account) => account.toJson()).toList(),
    );
    await _writeAccountsJson(accountsJson);
  }

  /// Wipe the persisted blob (SecureStorage + legacy prefs) so a signed-out
  /// account's OAuth tokens, emails, and imported events never survive logout.
  static Future<void> clearPersistedAccounts() async {
    try {
      await SecureStorageService.instance.delete(
        _connectedOnlineAccountsStorageKey,
      );
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_connectedOnlineAccountsStorageKey)) {
        await prefs.remove(_connectedOnlineAccountsStorageKey);
      }
    } catch (_) {}
  }

  Future<void> addOrUpdateAccount(ConnectedOnlineAccount account) async {
    final next = [...state];
    final index = next.indexWhere(
      (current) =>
          current.provider == account.provider &&
          current.accountId == account.accountId,
    );
    if (index >= 0) {
      next[index] = account;
    } else {
      next.add(account);
    }
    state = next;
    await _saveAccounts();
  }

  Future<void> removeAccount(OnlineProvider provider, String accountId) async {
    state = state
        .where(
          (account) =>
              !(account.provider == provider && account.accountId == accountId),
        )
        .toList();
    await _saveAccounts();
  }

  bool containsAccount(OnlineProvider provider, String accountId) {
    return state.any(
      (account) =>
          account.provider == provider && account.accountId == accountId,
    );
  }

  List<ConnectedOnlineAccount> getAccountsByProvider(OnlineProvider provider) {
    return state.where((account) => account.provider == provider).toList();
  }
}

final connectedOnlineAccountsProvider =
    NotifierProvider<
      ConnectedOnlineAccountsNotifier,
      List<ConnectedOnlineAccount>
    >(ConnectedOnlineAccountsNotifier.new);

List<EventModel> getAllImportableEvents(List<ConnectedOnlineAccount> accounts) {
  final allEvents = <EventModel>[];
  for (final account in accounts) {
    allEvents.addAll(account.events);
  }
  allEvents.sort(
    (first, second) => first.startTime.compareTo(second.startTime),
  );
  return allEvents;
}
