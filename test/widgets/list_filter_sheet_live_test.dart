// An open filter sheet shows two kinds of thing: what the user is editing, and
// what the rows behind it can currently support. Only the first is a snapshot.
//
// Regression guard for the second: a message that arrives, or a countdown that
// starts, while the sheet is on screen used to leave "Unread first",
// "Unread only (N)" and "Expiring soon" hidden until the user closed and
// reopened it. The sheet now reads those from a live value the screen publishes
// from its own build — which is also why publishing has to wait for the frame:
// asking a modal route to rebuild mid-build is what Flutter rejects, so a
// broken deferral shows up as a test failure here rather than as a silent bug.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/list_filter_bar.dart';

/// Stands in for the rows a list screen is built from.
class _Rows extends ChangeNotifier {
  _Rows({
    this.rowCount = 5,
    this.unreadCount = 0,
    this.hasRunningTimer = false,
  });

  int rowCount;
  int unreadCount;

  /// Matches only: a countdown runs until that match's chat starts, and it is
  /// what makes "Expiring soon" worth offering.
  bool hasRunningTimer;

  void change({int? rowCount, int? unreadCount, bool? hasRunningTimer}) {
    this.rowCount = rowCount ?? this.rowCount;
    this.unreadCount = unreadCount ?? this.unreadCount;
    this.hasRunningTimer = hasRunningTimer ?? this.hasRunningTimer;
    notifyListeners();
  }
}

/// A list screen that publishes to an open sheet the way the real ones do: from
/// its own build, because arriving data is what rebuilds it.
class _Host extends StatefulWidget {
  const _Host({
    required this.rows,
    required this.initial,
    required this.sortsFor,
    this.onApply,
  });

  final _Rows rows;
  final ListFilterState initial;
  final List<ListSortOption> Function(_Rows rows) sortsFor;
  final ValueChanged<ListFilterState?>? onApply;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final ListFilterSheetLiveSource _live = ListFilterSheetLiveSource(
    const ListFilterSheetLive(sortOptions: [], revision: 0),
  );

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = LocalizationState.loading();
    return AnimatedBuilder(
      animation: widget.rows,
      builder: (context, _) {
        final rows = widget.rows;
        final sorts = widget.sortsFor(rows);
        final unreadCount = rows.unreadCount;
        int countFor(ListFilterState draft) => rows.rowCount;

        _live.publish(
          ListFilterSheetLive(
            sortOptions: sorts,
            revision: rows.rowCount,
            extraToggleLabel: unreadCount == 0
                ? 'Unread only'
                : 'Unread only ($unreadCount)',
            extraToggleVisible: unreadCount > 0,
            resultCountFor: countFor,
          ),
        );

        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () {
                    showListFilterSheet(
                      context: context,
                      l10n: l10n,
                      intentKeys: const ['romantic', 'hiking'],
                      allIntents: const [],
                      resultCountFor: countFor,
                      genderOptions: const [],
                      sortOptions: sorts,
                      initial: widget.initial,
                      live: _live,
                    ).then((result) => widget.onApply?.call(result));
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void main() {
  const chatsPristine = ListFilterState(
    extraToggleKey: 'unread',
    sort: chatDefaultSort,
    defaultSort: chatDefaultSort,
  );

  Future<void> openSheet(
    WidgetTester tester, {
    required _Rows rows,
    required ListFilterState initial,
    required List<ListSortOption> Function(_Rows) sortsFor,
    ValueChanged<ListFilterState?>? onApply,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: _Host(
          rows: rows,
          initial: initial,
          sortsFor: sortsFor,
          onApply: onApply,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('options an open sheet reads from the rows', () {
    testWidgets('an order that only arriving data justifies shows up', (
      tester,
    ) async {
      final rows = _Rows(rowCount: 3, unreadCount: 0);
      await openSheet(
        tester,
        rows: rows,
        initial: chatsPristine,
        sortsFor: (r) => chatSortOptions(hasUnread: r.unreadCount > 0),
      );
      expect(find.text('Unread first'), findsNothing);
      expect(find.text('Show 3 results'), findsOneWidget);

      rows.change(rowCount: 4, unreadCount: 2);
      await tester.pumpAndSettle();

      expect(find.text('Unread first'), findsOneWidget);
      expect(find.text('Unread only (2)'), findsWidgets);
      // "Show N results" counts the rows that arrived, not the ones present
      // when the sheet opened.
      expect(find.text('Show 4 results'), findsOneWidget);
    });

    testWidgets('"Expiring soon" appears when a countdown starts', (
      tester,
    ) async {
      final rows = _Rows(hasRunningTimer: false);
      await openSheet(
        tester,
        rows: rows,
        initial: const ListFilterState(
          sort: matchDefaultSort,
          defaultSort: matchDefaultSort,
        ),
        sortsFor: (r) => matchSortOptions(hasExpiring: r.hasRunningTimer),
      );
      expect(find.text('Expiring soon'), findsNothing);

      rows.change(hasRunningTimer: true);
      await tester.pumpAndSettle();
      expect(find.text('Expiring soon'), findsOneWidget);
    });

    testWidgets('an order the rows no longer support is not left selected', (
      tester,
    ) async {
      ListFilterState? applied;
      final rows = _Rows(hasRunningTimer: true);
      await openSheet(
        tester,
        rows: rows,
        initial: const ListFilterState(
          sort: ListSortOption.expiringSoon,
          defaultSort: matchDefaultSort,
        ),
        sortsFor: (r) => matchSortOptions(hasExpiring: r.hasRunningTimer),
        onApply: (result) => applied = result,
      );
      // Chip plus the "not left selected" summary pill, both still there.
      expect(find.text('Expiring soon'), findsWidgets);

      // The last countdown ran out while the sheet sat open.
      rows.change(hasRunningTimer: false);
      await tester.pumpAndSettle();
      expect(find.text('Expiring soon'), findsNothing);

      await tester.tap(find.text('Show 5 results'));
      await tester.pumpAndSettle();
      expect(applied?.sort, matchDefaultSort);
    });

    testWidgets('a toggle with nothing left to narrow switches itself off', (
      tester,
    ) async {
      ListFilterState? applied;
      final rows = _Rows(unreadCount: 2);
      await openSheet(
        tester,
        rows: rows,
        initial: const ListFilterState(
          extraToggleKey: 'unread',
          extraToggleLabel: 'Unread only (2)',
          extraToggleActive: true,
          extraToggleVisible: true,
          sort: chatDefaultSort,
          defaultSort: chatDefaultSort,
        ),
        sortsFor: (r) => chatSortOptions(hasUnread: r.unreadCount > 0),
        onApply: (result) => applied = result,
      );
      expect(find.text('Unread only (2)'), findsWidgets);

      // The last unread was read: applying the toggle would now hand back an
      // empty list, which reads as lost conversations.
      rows.change(unreadCount: 0);
      await tester.pumpAndSettle();
      expect(find.text('Unread only'), findsNothing);

      await tester.tap(find.text('Show 5 results'));
      await tester.pumpAndSettle();
      expect(applied?.extraToggleActive, isFalse);
    });

    testWidgets('the draft the user is editing survives a live update', (
      tester,
    ) async {
      ListFilterState? applied;
      final rows = _Rows(unreadCount: 1);
      await openSheet(
        tester,
        rows: rows,
        initial: chatsPristine,
        sortsFor: (r) => chatSortOptions(hasUnread: r.unreadCount > 0),
        onApply: (result) => applied = result,
      );

      await tester.tap(find.text('Romantic'));
      await tester.tap(find.text('Name A–Z'));
      rows.change(rowCount: 9, unreadCount: 4);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show 9 results'));
      await tester.pumpAndSettle();
      expect(applied?.selectedIntentKey, 'romantic');
      expect(applied?.sort, ListSortOption.nameAsc);
    });
  });

  group('publishing from a build', () {
    testWidgets('only reaches the sheet once the frame is drawn', (
      tester,
    ) async {
      final rows = _Rows(unreadCount: 0);
      await openSheet(
        tester,
        rows: rows,
        initial: chatsPristine,
        sortsFor: (r) => chatSortOptions(hasUnread: r.unreadCount > 0),
      );

      // Mid-frame the rows change and the host rebuilds: the sheet must not be
      // asked to rebuild while that build is still running.
      rows.change(unreadCount: 3);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Unread first'), findsOneWidget);
    });

    test('a publish that shows nothing new still keeps the newest rows', () {
      // The count is a closure over the screen's rows, and rows can finish
      // resolving — a profile arriving, a gender map filling in — without
      // changing anything the sheet compares. Regression guard: a first
      // version of this returned early on "nothing to show", which left a
      // gender filter counting against an empty profile map.
      var rebuilds = 0;
      final source = ListFilterSheetLiveSource(
        ListFilterSheetLive(
          sortOptions: const [ListSortOption.recent],
          revision: 2,
          resultCountFor: (_) => 5,
        ),
      )..addListener(() => rebuilds++);
      addTearDown(source.dispose);

      source.publish(
        ListFilterSheetLive(
          sortOptions: const [ListSortOption.recent],
          revision: 2,
          resultCountFor: (_) => 4,
        ),
      );

      expect(rebuilds, 0);
      expect(source.value.resultCountFor!(const ListFilterState()), 4);
    });

    test('an unchanged publish has nothing to tell the sheet', () {
      const published = ListFilterSheetLive(
        sortOptions: [ListSortOption.recent],
        revision: 2,
        extraToggleLabel: 'Unread only (2)',
        extraToggleVisible: true,
      );

      ListFilterSheetLive withChanges({
        int revision = 2,
        List<ListSortOption> sortOptions = const [ListSortOption.recent],
        String? extraToggleLabel = 'Unread only (2)',
        bool extraToggleVisible = true,
      }) {
        return ListFilterSheetLive(
          sortOptions: sortOptions,
          revision: revision,
          extraToggleLabel: extraToggleLabel,
          extraToggleVisible: extraToggleVisible,
        );
      }

      // Every screen build makes a fresh instance with the same contents,
      // including a fresh count closure that cannot be compared.
      expect(published.sameAs(withChanges()), isTrue);
      expect(published.sameAs(withChanges(revision: 3)), isFalse);
      expect(published.sameAs(withChanges(extraToggleVisible: false)), isFalse);
      expect(
        published.sameAs(withChanges(extraToggleLabel: 'Unread only (3)')),
        isFalse,
      );
      expect(
        published.sameAs(
          withChanges(
            sortOptions: const [ListSortOption.recent, ListSortOption.nameAsc],
          ),
        ),
        isFalse,
      );
    });
  });
}
