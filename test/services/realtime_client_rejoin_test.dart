import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_client/realtime_client.dart';

/// Regression test for the realtime sync bug that made settings stop
/// propagating between devices.
///
/// Phoenix channels are scoped to a socket: when the socket goes away the
/// server drops every channel it carried, and the client has to send a new
/// `phx_join` for each topic. The vendored realtime client reconnected the
/// socket but never re-joined the channels, so after any socket drop - or
/// after an explicit `disconnect()` followed by a `connect()`, which is what
/// the web tab hide/show path does - every `postgres_changes` subscription
/// stayed dead for the rest of the process lifetime. A setting changed on one
/// device then simply never reached the other one.
void main() {
  group('RealtimeClient channel rejoin', () {
    late _FakePhoenixServer server;
    late RealtimeClient client;

    setUp(() async {
      server = await _FakePhoenixServer.start();
      client = RealtimeClient(
        'ws://${server.host}:${server.port}',
        logger: (kind, message, data) {
          // ignore: avoid_print
          print('[$kind] $message $data');
        },
      );
    });

    tearDown(() async {
      await client.disconnect();
      await server.close();
    });

    test('re-joins a channel that was lost with the socket', () async {
      client
          .channel('user_settings_1')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'users',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: 'user-1',
            ),
            callback: (_) {},
          )
          .subscribe();

      await server.waitForJoins('user_settings_1', 1);
      expect(client.isTopicLive('user_settings_1'), isTrue);

      // The socket drops without the app noticing (packet loss, a server
      // restart, the OS suspending the network stack).
      server.dropSockets();

      // The client reconnects on its own.
      await server.waitForSockets(2);
      await server.waitForJoins('user_settings_1', 2);

      expect(
        server.joinsFor('user_settings_1'),
        2,
        reason:
            'the channel must be re-joined on the new socket - without this '
            'the subscription is dead even though the client reports '
            '"subscribed"',
      );
      expect(client.isTopicLive('user_settings_1'), isTrue);
    });

    test('re-joins a channel after an explicit disconnect + connect', () async {
      client.channel('user_settings_1').subscribe();
      await server.waitForJoins('user_settings_1', 1);

      // This is exactly what the web "tab hidden" path used to do.
      await client.disconnect();
      // ignore: invalid_use_of_internal_member
      await client.connect();

      await server.waitForJoins('user_settings_1', 2);
      expect(
        server.joinsFor('user_settings_1'),
        2,
        reason:
            'a reconnect has to re-establish the channel, otherwise every '
            'postgres_changes subscription is silently dead after the first '
            'tab switch',
      );
    });

    test('does not join a channel that was never subscribed', () async {
      client.channel('subscribed_one').subscribe();
      await server.waitForJoins('subscribed_one', 1);

      // Creating a channel without subscribing to it must never produce a
      // join - neither now nor after a reconnect.
      client.channel('never_subscribed');

      server.dropSockets();
      await server.waitForSockets(2);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(server.joinsFor('never_subscribed'), 0);
      expect(server.joinsFor('subscribed_one'), 2);
    });
  });
}

/// A tiny in-process Phoenix server.
///
/// It speaks just enough of the protocol to let a channel join: every
/// `phx_join` is answered with a `phx_reply` that echoes the requested
/// postgres_changes filters back, the way the real server does.
class _FakePhoenixServer {
  _FakePhoenixServer._(this._httpServer) {
    _httpServer.listen(_handleRequest);
  }

  static Future<_FakePhoenixServer> start() async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakePhoenixServer._(httpServer);
  }

  final HttpServer _httpServer;
  final List<WebSocket> _sockets = <WebSocket>[];

  /// How many sockets the server has accepted in total (including dropped
  /// ones).
  int _acceptedSockets = 0;

  /// How many join frames the server has seen, by topic.
  final Map<String, int> joins = <String, int>{};

  String get host => _httpServer.address.host;

  int get port => _httpServer.port;

  int get socketCount => _acceptedSockets;

  int joinsFor(String topic) => joins[topic] ?? 0;

  Future<void> close() async {
    for (final socket in List<WebSocket>.from(_sockets)) {
      await socket.close();
    }
    await _httpServer.close(force: true);
  }

  /// Drops every open socket without a clean close handshake.
  void dropSockets() {
    for (final socket in List<WebSocket>.from(_sockets)) {
      socket.close();
    }
    _sockets.clear();
  }

  Future<void> waitForJoins(String topic, int count) async {
    await _waitFor(() => joinsFor(topic) >= count);
  }

  Future<void> waitForSockets(int count) async {
    await _waitFor(() => socketCount >= count);
  }

  Future<void> _waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for the fake Phoenix server');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _acceptedSockets++;
    _sockets.add(socket);
    socket.listen((data) {
      final frame = data is String
          ? data
          : utf8.decode((data as List<int>).whereType<int>().toList());
      _handleFrame(socket, frame);
    });
  }

  void _handleFrame(WebSocket socket, String frame) {
    final decoded = jsonDecode(frame);
    if (decoded is! List || decoded.length < 5) return;
    final topic = decoded[2] as String;
    final event = decoded[3] as String;
    final payload = decoded[4];

    if (event != 'phx_join') return;
    // The wire topic carries the `realtime:` prefix; the app refers to
    // channels without it.
    final subTopic = topic.startsWith('realtime:')
        ? topic.substring('realtime:'.length)
        : topic;
    joins.update(subTopic, (count) => count + 1, ifAbsent: () => 1);

    final response = <String, dynamic>{};
    final config = payload is Map ? payload['config'] : null;
    final filters = config is Map ? config['postgres_changes'] : null;
    if (filters is List && filters.isNotEmpty) {
      response['postgres_changes'] = [
        for (var i = 0; i < filters.length; i++)
          {
            ...(filters[i] as Map<String, dynamic>),
            'id': '${i + 1}',
          },
      ];
    }

    socket.add(
      jsonEncode([
        decoded[0],
        decoded[1],
        topic,
        'phx_reply',
        {'status': 'ok', 'response': response},
      ]),
    );
  }
}
