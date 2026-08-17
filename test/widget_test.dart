import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/main.dart';

void main() {
  testWidgets('Raft Rumble boots to main menu', (WidgetTester tester) async {
    await tester.pumpWidget(const RaftRumbleApp());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('RAFT'), findsOneWidget);
    expect(find.text('RUMBLE'), findsOneWidget);
  });
}
