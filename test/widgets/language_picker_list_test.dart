import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/language_picker_list.dart';

Widget _host({
  required List<LanguagePickerEntry> entries,
  required ValueChanged<LanguagePickerEntry> onSelected,
  ValueChanged<LanguagePickerEntry>? onUnavailable,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                // Mirrors auth_screen.dart's picker dialog. `scrollable: true`
                // makes the dialog measure its content intrinsically, which is
                // exactly what a nested viewport cannot do.
                scrollable: true,
                title: const Text('Select language'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: LanguagePickerList(
                    entries: entries,
                    onSelected: onSelected,
                    onUnavailable: onUnavailable,
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('language list renders inside a scrollable AlertDialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        entries: const [
          LanguagePickerEntry(code: 'en', displayName: 'English'),
          LanguagePickerEntry(code: 'he', displayName: 'עברית'),
        ],
        onSelected: (_) {},
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('עברית'), findsOneWidget);
  });

  testWidgets('tapping a language reports the selection', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _host(
        entries: const [
          LanguagePickerEntry(code: 'en', displayName: 'English'),
          LanguagePickerEntry(code: 'es', displayName: 'Español'),
        ],
        onSelected: (entry) => selected = entry.code,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();

    expect(selected, 'es');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable languages route to the unavailable callback', (
    tester,
  ) async {
    String? selected;
    String? unavailable;
    await tester.pumpWidget(
      _host(
        entries: const [
          LanguagePickerEntry(
            code: 'ar',
            displayName: 'العربية',
            canUseNow: false,
          ),
        ],
        onSelected: (entry) => selected = entry.code,
        onUnavailable: (entry) => unavailable = entry.code,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية'));
    await tester.pumpAndSettle();

    expect(unavailable, 'ar');
    expect(selected, isNull);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });
}
