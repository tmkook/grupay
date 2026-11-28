import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grupay_client/core/network/ws_client.dart';
import 'package:grupay_client/core/webview/injection_manager.dart';
import 'package:grupay_client/features/webview/product_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DashboardClient extends WsClient {
  int orderRequests = 0;

  @override
  Future<Map> request(String type, Map data) async {
    if (type == 'order.list') {
      orderRequests++;
      return {'orders': [], 'next_before_id': null};
    }
    return {};
  }
}

void main() {
  testWidgets('an unconfigured product cannot offer order acceptance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = WsClient()..settings['product_code'] = 'test-product';
    await tester.pumpWidget(
      MaterialApp(
        home: ProductPage(
          target: Uri.parse('https://product.example/product'),
          client: client,
          logout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('产品地址与服务端配置不符'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    client.dispose();
  });

  testWidgets('switching to the browser keeps the home list mounted', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = DashboardClient()
      ..nickname = '测试账号'
      ..settings['product_code'] = 'test-product';
    await tester.pumpWidget(
      MaterialApp(
        home: ProductPage(
          target: Uri.parse('https://product.example/product'),
          client: client,
          logout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    await tester.tap(find.text('主页'));
    await tester.pumpAndSettle();
    expect(client.orderRequests, 1);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('修改密码'), findsOneWidget);
    await tester.tap(find.text('站点'));
    await tester.pumpAndSettle();
    expect(find.text('产品地址与服务端配置不符'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主页'));
    await tester.pumpAndSettle();
    expect(client.orderRequests, 1);
    expect(find.text('暂无订单'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    client.dispose();
  });

  test('missing and insecure script addresses fail before download', () async {
    final scripts = InjectionManager();
    addTearDown(scripts.dispose);
    for (final url in [null, 'http://example.com/product.js']) {
      await expectLater(scripts.load(url), throwsFormatException);
    }
  });
}
