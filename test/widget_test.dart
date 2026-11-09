import 'package:flutter_test/flutter_test.dart';
import 'package:esakay_toda/main.dart';

void main() {
  testWidgets('eSakay TODA onboarding smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ESakayTodaApp(initialScreen: OnboardingScreen()));
    expect(find.text('eSakay TODA'), findsOneWidget);
  });
}