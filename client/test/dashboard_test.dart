import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:grupay_client/core/network/ws_client.dart';
import 'package:grupay_client/features/orders/dashboard.dart';

class DashboardDevice extends WsClient {
  int listReads = 0;

  void setConnected(bool value) {
    connected = value;
    notifyListeners();
  }

  void setServing(bool value) {
    serving = value;
    notifyListeners();
  }

  @override
  Future<Map> request(String type, Map data) async {
    if (type == 'order.list') {
      listReads++;
      return {'orders': [], 'next_before_id': null};
    }
    if (type == 'device.set') {
      return {
        'status': data['status'] ?? (serving ? 1 : 0),
        'weight': data['weight'] ?? device['weight'] ?? 1,
        'daily_limit': data['daily_limit'] ?? device['daily_limit'] ?? 0,
        'pending_limit': data['pending_limit'] ?? device['pending_limit'] ?? 5,
      };
    }
    return {
      'date': '2026-11-24',
      'received': 1,
      'paid': 1,
      'account': {'date': '2026-11-24', 'received': 7},
    };
  }
}

class UpdatingDevice extends DashboardDevice {
  @override
  Future<(Uri, String)?> availableUpdate(int installedBuild) async =>
      (Uri.parse('https://example.test/releases/grupay-1.0.0+2.apk'), 'a' * 64);
}

void main() {
  testWidgets(
    'automatic update downloads once and waits for an idle device before installing',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final device = UpdatingDevice()..serving = true;
      var active = 1;
      final methods = <String>[];
      const channel = MethodChannel('grupay/updates');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return call.method == 'build' ? 1 : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(
          home: Dashboard(
            client: device,
            showUa: () async {},
            onLogout: () {},
            active: () => active,
            canStart: () => true,
            tab: 0,
            onTabSelected: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(methods, ['build', 'download']);
      device.serving = false;
      await tester.pump(const Duration(seconds: 5));
      expect(methods, ['build', 'download']);
      active = 0;
      await tester.pump(const Duration(seconds: 5));
      expect(methods, ['build', 'download', 'install']);
      await tester.pumpWidget(const SizedBox.shrink());
      device.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'home updates live and account and device statistics update independently',
    (tester) async {
      final device = DashboardDevice()
        ..nickname = '测试设备'
        ..connected = true;
      var tab = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setTab) => Dashboard(
              client: device,
              showUa: () async {},
              onLogout: () {},
              active: () => 0,
              canStart: () => true,
              recheck: (_) async => '订单已支付',
              tab: tab,
              onTabSelected: (i) => setTab(() => tab = i),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无订单'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      device.setConnected(false);
      device.setConnected(true);
      await tester.pumpAndSettle();
      expect(device.listReads, 2);
      expect(find.text('未登录'), findsOneWidget);
      expect(find.text('测试设备'), findsNothing);
      expect(find.text('产品账号未登录'), findsOneWidget);
      final destinations = tester.widgetList<NavigationDestination>(
        find.byType(NavigationDestination),
      );
      expect(destinations.map((item) => item.label), ['主页', '站点', '统计', '设置']);
      expect(find.textContaining('在途任务'), findsNothing);
      device.events.add({
        'type': 'order.update',
        'data': {
          'id': 1,
          'order_no': 'GR-test',
          'amount': 10,
          'status': 'paid',
          'revision': 3,
          'created_at': 0,
        },
      });
      await tester.pump();
      expect(find.text('10'), findsOneWidget);
      expect(find.text('查单 0 次'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.text('订单详情'), findsOneWidget);
      Navigator.of(tester.element(find.text('订单详情'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('查单'));
      await tester.pumpAndSettle();
      expect(find.text('订单已支付'), findsOneWidget);
      await tester.tap(find.text('统计'));
      await tester.pumpAndSettle();
      final tabs = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(tabs.selected, {false});

      expect(find.text('2026-11-24 · 本机'), findsOneWidget);
      await tester.tap(find.text('全部统计'));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-24 · 账号全部设备'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      device.events.add({
        'type': 'stats.data',
        'data': {'date': '2026-11-24', 'received': 2},
      });
      await tester.pump();
      expect(find.text('7'), findsOneWidget);
      device.events.add({
        'type': 'stats.account',
        'data': {'date': '2026-11-24', 'received': 8},
      });
      await tester.pump();
      expect(find.text('8'), findsOneWidget);
      await tester.tap(find.text('本机统计'));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      device.dispose();
    },
  );

  testWidgets('home shows the unmet dispatch condition', (tester) async {
    final device = DashboardDevice()
      ..nickname = '测试设备'
      ..connected = true
      ..serving = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Dashboard(
          client: device,
          showUa: () async {},
          onLogout: () {},
          active: () => 0,
          canStart: () => true,
          productReady: true,
          tab: 0,
          onTabSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('接单中'), findsOneWidget);
    device.setServing(false);
    await tester.pump();
    expect(find.text('已暂停接单'), findsOneWidget);
    device.setConnected(false);
    await tester.pump();
    expect(find.text('重新连接中…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    device.dispose();
  });

  testWidgets(
    'dispatch settings save quota and weight and control acceptance',
    (tester) async {
      final device = DashboardDevice()
        ..nickname = '测试设备'
        ..connected = true
        ..serving = true
        ..device = {'weight': 1, 'daily_limit': 0, 'pending_limit': 5};
      await tester.pumpWidget(
        MaterialApp(
          home: Dashboard(
            client: device,
            showUa: () async {},
            onLogout: () {},
            active: () => 0,
            canStart: () => true,
            tab: 3,
            onTabSelected: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('接单设置'));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), '1000');
      await tester.enterText(find.byType(TextFormField).at(1), '5');
      await tester.enterText(find.byType(TextFormField).at(2), '3');
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(device.device['weight'], 5);
      expect(device.device['daily_limit'], 1000);
      expect(device.device['pending_limit'], 3);
      await tester.tap(find.text('接单设置'));
      await tester.pumpAndSettle();
      expect(find.text('接单中'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(device.serving, isTrue);
      expect(find.text('已暂停接单'), findsOneWidget);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(device.serving, isFalse);
      expect(device.device['status'], 0);
      await tester.pumpWidget(const SizedBox.shrink());
      device.dispose();
    },
  );
}
