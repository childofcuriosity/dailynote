import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dailynote/pages/chat_page.dart';
import 'package:dailynote/pages/home_page.dart';
import 'package:dailynote/services/api_config.dart';
import 'package:dailynote/services/api_service.dart';
import 'package:dailynote/services/l10n.dart';
import 'package:dailynote/main.dart';

void main() {
  tearDown(() {
    ApiService.account = null;
    ApiService.sessionToken.value = null;
    AppLanguage.isChinese = false;
  });

  testWidgets(
    'Personal UI is Chinese and switching accounts resets the locale',
    (tester) async {
      AppLanguage.isChinese = true;
      ApiService.account = 'personal';
      ApiService.sessionToken.value = 'test-session';
      await tester.pumpWidget(const DailyNoteApp());
      await tester.pumpAndSettle();
      expect(find.text('日记助手 · 个人'), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('zh'),
      );
      await tester.tap(find.byTooltip('切换账户'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to DailyNote'), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('en'),
      );
    },
  );

  test('Localized placeholders retain dynamic values', () {
    expect(
      tr('Split into {0} diary entries', [3]),
      'Split into 3 diary entries',
    );
    AppLanguage.isChinese = true;
    expect(tr('Split into {0} diary entries', [3]), '已拆分为 3 条日记');
  });
  testWidgets('Account selection starts before any personal data loads', (
    tester,
  ) async {
    await tester.pumpWidget(const DailyNoteApp());
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Public demo'), findsOneWidget);
    expect(find.text('Personal account'), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    await tester.tap(find.text('Personal account'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
  });
  test('API defaults to same-origin proxy', () {
    expect(ApiConfig.baseUrl, Uri.base.resolve('/api').toString());
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('Text chat works without voice plugins at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Web text input');
      expect(find.text('Web text input'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Unavailable API shows retry instead of endless loading', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
