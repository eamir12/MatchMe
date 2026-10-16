// Regression tests for the app-wide NO-TRUNCATION POLICY
// (lib/widgets/safe_text.dart):
//
// 1. Source scan — fails if `TextOverflow.ellipsis`/`clip`/`fade` or a plain
//    `Text(...)` AppBar title is reintroduced anywhere in lib/ or in the
//    matchme_admin package (both ship SafeText/ShrinkText).
// 2. Widget test — an AppBar title rendered with `ShrinkText` in a cramped
//    bar (back button + 3 actions, narrow surface) must paint the whole
//    string, never "Edit pho...".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/safe_text.dart';

void main() {
  group('source scan: no truncation escapes in lib/ or matchme_admin/lib', () {
    // Both packages in the repo: the app and the admin dashboard.
    final scanRoots = ['lib', 'matchme_admin/lib'];
    late List<File> dartFiles;

    setUpAll(() {
      dartFiles = [
        for (final root in scanRoots)
          ...Directory(root)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')),
      ];
    });

    String read(File f) => f.readAsStringSync();

    Iterable<String> linesMatching(
      RegExp pattern,
    ) sync* {
      for (final f in dartFiles) {
        final lines = read(f).split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            yield '${f.path}:${i + 1}: ${lines[i].trim()}';
          }
        }
      }
    }

    test('no TextOverflow.ellipsis/clip/fade outside policy comments', () {
      final offenders = linesMatching(
        RegExp(r'TextOverflow\.(ellipsis|clip|fade)'),
      ).where((l) => !l.contains('safe_text.dart')).toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'Use SafeText (wrap) or ShrinkText (shrink) instead of '
            'truncating overflow. Offenders:\n${offenders.join('\n')}',
      );
    });

    test('no plain Text(...) as an AppBar title', () {
      final pattern = RegExp(r'AppBar\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*'
          r'?title:\s*Text\(',
          multiLine: true, dotAll: true);
      final offenders = <String>[];
      for (final f in dartFiles) {
        final src = read(f);
        for (final m in pattern.allMatches(src)) {
          final line = src.substring(0, m.end).split('\n').length;
          offenders.add('${f.path}:$line');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'AppBar applies softWrap:false + ellipsis to its title, so a '
            'plain Text truncates when actions/back button squeeze the bar. '
            'Use ShrinkText. Offenders:\n${offenders.join('\n')}',
      );
    });
  });

  group('AppBar title never truncates', () {
    Future<void> pumpCrampedAppBar(
      WidgetTester tester, {
      required String title,
      int actionCount = 3,
    }) async {
      // Narrow surface: back button + 3 actions leave almost no room.
      await tester.binding.setSurfaceSize(const Size(280, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: ShrinkText(title),
              actions: [
                for (var i = 0; i < actionCount; i++)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () {},
                  ),
              ],
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('full title is painted in a cramped editor-style bar', (
      tester,
    ) async {
      const title = 'Edit photo';
      await pumpCrampedAppBar(tester, title: title);

      final textFinder = find.text(title);
      expect(textFinder, findsOneWidget);

      // The painted glyphs must fit inside the bar (no clipped tail).
      final Size textSize = tester.getSize(textFinder);
      expect(textSize.width, greaterThan(0));
      final barSize = tester.getSize(
        find.byType(AppBar).first,
      );
      expect(
        textSize.width,
        lessThanOrEqualTo(barSize.width),
        reason: 'Title overflows the AppBar width — it would be truncated.',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('long localized title shrinks instead of ellipsizing', (
      tester,
    ) async {
      const title =
          'يرجى تعديل صورة الملف الشخصي قبل المتابعة إلى الخطوة التالية';
      await pumpCrampedAppBar(tester, title: title);

      expect(find.text(title), findsOneWidget);
      final textSize = tester.getSize(find.text(title));
      final barSize = tester.getSize(find.byType(AppBar).first);
      expect(textSize.width, lessThanOrEqualTo(barSize.width));
      expect(tester.takeException(), isNull);
    });
  });
}
