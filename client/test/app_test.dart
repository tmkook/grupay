import 'package:flutter_test/flutter_test.dart';
import 'package:grupay_client/app/app.dart';

void main() {
  testWidgets('renders application shell', (tester) async {
    await tester.pumpWidget(const GruPayApp());

    expect(find.text('GruPay'), findsOneWidget);
  });
}
