import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grupay_client/core/network/ws_client.dart';

void main() {
  test('login and reconnect use the documented digest', () {
    expect(loginDigest('demo', 'demo123'), '8e2d25e2492ec21931d399f12dce23be');
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'clearing the message log persists and preserves other scopes',
    () async {
      SharedPreferences.setMockInitialValues({
        'message_log/current': <String>['received'],
        'message_log/other': <String>['sent'],
      });
      final client = WsClient()..scope = 'current';
      await client.clearMessageLog();
      final reopened = WsClient()..scope = 'current';
      expect(await reopened.messageLog(), isEmpty);
      reopened.scope = 'other';
      expect(await reopened.messageLog(), ['sent']);
    },
  );
  test(
    'authenticates again after a lost connection and stops after logout',
    () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = WsClient();
      final resumed = Completer<void>();
      var connections = 0;
      var retainedSession = false;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        connections++;
        final current = connections;
        socket.listen((raw) async {
          final message = jsonDecode(raw as String);
          if (message['type'] != 'auth') return;
          socket.add(
            jsonEncode({
              'type': 'auth.ok',
              'data': {
                'user': {'username': 'demo'},
                'settings': {},
              },
            }),
          );
          if (current == 1) await socket.close();
        });
      });
      client.addListener(() {
        if (!client.connected && client.nickname == 'demo') {
          retainedSession = true;
        }
        if (connections == 2 &&
            client.connected &&
            client.nickname == 'demo' &&
            !resumed.isCompleted) {
          resumed.complete();
        }
      });
      try {
        client.login(Uri.parse('ws://127.0.0.1:${server.port}/ws'), {
          'username': 'demo',
        });
        await resumed.future.timeout(const Duration(seconds: 8));
        expect(retainedSession, isTrue);
        expect(
          (await client.messageLog()).any(
            (line) => line.endsWith('接收  auth.ok'),
          ),
          isTrue,
        );
        client.logout();
        expect(client.nickname, isNull);
        expect(client.status, isEmpty);
      } finally {
        client.dispose();
        await server.close(force: true);
      }
    },
  );
}
