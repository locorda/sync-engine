import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows login screen with cancel button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GDriveLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
        ],
        home: GDriveLoginScreen(onSignIn: () async => false),
      ),
    );

    // Wait for localizations to load
    await tester.pumpAndSettle();

    // Cancel button should always be present
    expect(find.byType(OutlinedButton), findsOneWidget);

    // Sign-in button varies by platform (FilledButton on native, custom on web)
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
  });
}
