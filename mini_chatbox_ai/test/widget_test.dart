import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_3/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VibeSyncApp());
    expect(find.text('Now playing'), findsOneWidget);
  });
}
