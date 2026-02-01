import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive_slow/src/ui/gdrive_login_screen.dart';

void main() {
  testWidgets('shows default buttons on non-web platforms', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GDriveSlowLoginScreen(onSignIn: () async => false),
      ),
    );

    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
  });
}
