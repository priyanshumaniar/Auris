import 'package:auris/ui/widgets/auris_input_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget field) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Form(child: field))),
    );

bool _obscured(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).obscureText;

void main() {
  testWidgets('a password field starts hidden and the eye reveals it',
      (tester) async {
    await _pump(
      tester,
      const AurisInputField(textHint: 'Password', obscureText: true),
    );
    expect(_obscured(tester), isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(_obscured(tester), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(_obscured(tester), isTrue);
  });

  testWidgets('an ordinary field has no eye button', (tester) async {
    await _pump(tester, const AurisInputField(textHint: 'Email'));
    expect(_obscured(tester), isFalse);
    expect(find.byTooltip('Show password'), findsNothing);
  });

  testWidgets('revealing keeps what was typed', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      AurisInputField(
        textHint: 'Password',
        obscureText: true,
        controller: controller,
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'secret-123');
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(controller.text, 'secret-123');
    expect(find.text('secret-123'), findsOneWidget);
  });
}
