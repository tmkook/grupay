import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grupay_client/core/network/ws_client.dart';
import 'package:grupay_client/features/orders/order_runner.dart';

class Device extends WsClient {
  Device() {
    settings['product_code'] = 'test-product';
  }

  final replies = <String>[];
  final placementFailures = <Map>[];
  bool drop = false;
  @override
  Future<Map> request(String type, Map data) async {
    replies.add(type);
    if (type == 'order.failed') placementFailures.add(data);
    if (type == 'order.query.begin') return {'allowed': true};
    if (type == 'order.ack') return {'can_execute': true};
    if (drop) {
      drop = false;
      throw StateError('connection lost');
    }
    if (type == 'order.placed') {
      return {
        'status': 'placed',
        'deadline_at': DateTime.now().millisecondsSinceEpoch + 300000,
      };
    }
    return {'status': 'paid'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const task = {
    'order_no': 'GR-test',
    'attempt': 1,
    'amount': 10,
    'status': 'assigned',
  };
  test(
    'a product call timeout reports an unknown placement with a reason',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final device = Device()..serving = true;
      final runner = OrderRunner(
        device,
        (method, args) async => throw TimeoutException('WebView'),
        () => 'owner',
      );
      await runner.step(task);
      expect(device.placementFailures.single, {
        'order_no': 'GR-test',
        'attempt': 1,
        'outcome': 'unknown',
        'reason': '等待产品页返回建单结果超时',
      });
    },
  );
  test(
    'lost placed reply is replayed without a second product order',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final device = Device()
        ..serving = true
        ..drop = true;
      var calls = 0;
      final runner = OrderRunner(device, (method, args) async {
        if (method == 'getPayUrl') {
          calls++;
          return {
            'ok': true,
            'data': {'payUrl': 'https://product.example/pay', 'tradeNo': 'T'},
          };
        }
        return {
          'ok': true,
          'data': {'method': 'GET', 'url': '/state'},
        };
      }, () => 'owner');
      await expectLater(runner.step(task), throwsStateError);
      await runner.step({...task, 'status': 'placing'});
      expect(calls, 1);
      expect(device.replies, ['order.ack', 'order.placed', 'order.placed']);
      expect(runner.tasks['GR-test']?['status'], 'placed');
    },
  );
  test('replays the link and its original query snapshot together', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final device = Device()
      ..serving = true
      ..drop = true;
    var calls = 0;
    final runner = OrderRunner(device, (method, args) async {
      calls++;
      expect(method, 'getPayUrl');
      expect(args, [10, 'GR-test', 'owner']);
      return {
        'ok': true,
        'data': {
          'payUrl': 'https://product.example/pay',
          'tradeNo': 'T',
          'query_params': {'method': 'GET', 'url': '/state/T'},
        },
      };
    }, () => 'owner');
    await expectLater(runner.step(task), throwsStateError);
    await runner.step(task);
    expect(calls, 1);
    expect(runner.tasks['GR-test']?['query_params'], {
      'method': 'GET',
      'url': '/state/T',
      'tradeNo': 'T',
      'account': 'owner',
    });
  });
  test('upstream login failure clears device readiness', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final device = Device()..serving = true;
    var reauth = 0;
    final runner = OrderRunner(
      device,
      (m, a) async => {
        'ok': false,
        'reason': '上游建单调用异常（上游状态码 4005436）',
        'outcome': 'unknown',
        'reauth': true,
      },
      () => 'owner',
      () async => reauth++,
    );
    await runner.step(task);
    expect(reauth, 1);
    expect(device.placementFailures.single['outcome'], 'unknown');
  });
  test(
    'execution marker survives restart and forbids another product call',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'order-test-product//GR-test': jsonEncode({
          ...task,
          'status': 'executing',
        }),
      });
      final device = Device();
      final runner = OrderRunner(
        device,
        (m, a) => throw StateError('unexpected script'),
        () => 'owner',
      );
      await runner.step(task);
      expect(device.replies, ['order.failed']);
    },
  );
  test('expired orders auto-recheck while under the query limit', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final device = Device();
    final runner = OrderRunner(
      device,
      (m, a) async => {
        'ok': true,
        'data': {'status': 'pending'},
      },
      () => 'owner',
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    runner.receive('order.resume', {
      'server_time': now,
      'orders': [
        {
          ...task,
          'status': 'expired',
          'deadline_at': now - 60000,
          'query_count': 10,
          'query_params': {'account': 'owner', 'tradeNo': 'T'},
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      device.replies,
      containsAllInOrder(['order.query.begin', 'order.query.result']),
    );
    expect(runner.tasks.containsKey('GR-test'), true);
    runner.tasks['GR-test']!['query_count'] = OrderRunner.expiredQueryLimit;
    runner.pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(runner.tasks.containsKey('GR-test'), false);
    runner.dispose();
  });
  test('21 pending payments limit parallel queries to 20 and reject mismatched trade', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final device = Device(), gate = Completer<void>();
    var calls = 0;
    final runner = OrderRunner(device, (m, a) async {
      calls++;
      await gate.future;
      return {
        'ok': true,
        'data': {
          'status': 'paid',
          'account': 'owner',
          'amount': 10,
          'tradeNo': 'other',
        },
      };
    }, () => 'owner');
    final now = DateTime.now().millisecondsSinceEpoch;
    runner.receive('order.resume', {
      'server_time': now,
      'orders': [
        for (var i = 0; i < 21; i++)
          {
            ...task,
            'order_no': 'GR$i',
            'status': 'placed',
            'deadline_at': now + 300000,
            'query_params': {'account': 'owner', 'tradeNo': 'T$i'},
          },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls, 20);
    runner.pump();
    expect(calls, 20);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    runner.pump();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 21);
    expect(
      device.replies.where((type) => type == 'order.query.begin'),
      hasLength(21),
    );
    expect(
      device.replies.where((type) => type == 'order.query.result'),
      hasLength(21),
    );
    expect(device.replies, isNot(contains('order.paid')));
    runner.dispose();
  });
}
