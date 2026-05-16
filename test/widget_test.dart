import 'package:flutter_test/flutter_test.dart';

import 'package:armin/app.dart';
import 'package:armin/core/services/armin_app_state.dart';

void main() {
  testWidgets('Armin home renders mock task queue', (tester) async {
    await tester.pumpWidget(ArminApp(state: ArminAppState()));
    await tester.pumpAndSettle();

    expect(find.text('Armin'), findsOneWidget);
    expect(find.text('Task Queue'), findsOneWidget);
    expect(find.text('New Task'), findsOneWidget);
  });
}
