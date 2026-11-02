// Guards the sort contract the four list call sites share:
//   * Matches defaults to "latest activity", Chats to "recent";
//   * an order that cannot change anything (no running countdown, nothing
//     unread) is not offered at all;
//   * a pick that has fallen out of the offer falls back to the screen default
//     instead of ordering by something the sheet no longer shows;
//   * "Newest" stays selectable, and the sheet's Clear returns to the screen's
//     own default rather than to a hard-coded option.
//
// These live in one file because the rules sit in shared helpers precisely so
// the Matches tab, the Chats tab and Home's two sections cannot drift.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/list_filter_bar.dart';

MatchModel _match({
  required String id,
  required DateTime createdAt,
  DateTime? expiresAt,
}) {
  return MatchModel(
    id: id,
    userAId: 'user-a',
    userBId: 'user-b',
    matchedIntent: 'romantic',
    matchType: 'proximity',
    createdAt: createdAt,
    otherUserId: 'user-b',
    expiresAt: expiresAt,
  );
}

void main() {
  final l10n = LocalizationState.loading();

  group('which orders are offered', () {
    test(
      'Matches leads with latest activity and keeps Newest as an option',
      () {
        final options = matchSortOptions(hasExpiring: true);
        expect(options.first, ListSortOption.latestActivity);
        expect(matchDefaultSort, ListSortOption.latestActivity);
        expect(options, contains(ListSortOption.recent));
      },
    );

    test('Expiring soon appears only while a timer runs', () {
      expect(
        matchSortOptions(hasExpiring: false),
        isNot(contains(ListSortOption.expiringSoon)),
      );
      expect(
        matchSortOptions(hasExpiring: true),
        contains(ListSortOption.expiringSoon),
      );
      // Nothing else changes, so the section never appears or disappears.
      expect(
        matchSortOptions(hasExpiring: false).length + 1,
        matchSortOptions(hasExpiring: true).length,
      );
    });

    test('Unread first appears only while something is unread', () {
      expect(
        chatSortOptions(hasUnread: false),
        isNot(contains(ListSortOption.unreadFirst)),
      );
      expect(
        chatSortOptions(hasUnread: true),
        contains(ListSortOption.unreadFirst),
      );
      expect(chatDefaultSort, ListSortOption.recent);
    });
  });

  group('a stale pick', () {
    test('keeps an order that is still offered', () {
      expect(
        resolveSort(
          ListSortOption.expiringSoon,
          matchSortOptions(hasExpiring: true),
          matchDefaultSort,
        ),
        ListSortOption.expiringSoon,
      );
    });

    test('falls back to the screen default once it is not', () {
      // The last countdown expired / the last unread was read.
      expect(
        resolveSort(
          ListSortOption.expiringSoon,
          matchSortOptions(hasExpiring: false),
          matchDefaultSort,
        ),
        matchDefaultSort,
      );
      expect(
        resolveSort(
          ListSortOption.unreadFirst,
          chatSortOptions(hasUnread: false),
          chatDefaultSort,
        ),
        chatDefaultSort,
      );
    });
  });

  group('activity + running timer', () {
    final created = DateTime.utc(2026, 10, 1, 9);

    test('a chat message later than the match counts as the activity', () {
      final later = _match(id: 'm1', createdAt: created);
      final activity = {'m1': created.add(const Duration(hours: 5))};
      expect(later.activityAt(activity), created.add(const Duration(hours: 5)));
    });

    test('a match with no chat message is its own activity', () {
      final fresh = _match(id: 'm2', createdAt: created);
      expect(fresh.activityAt(const {}), created);
      // A message older than the match (a re-synced row) never drags it back.
      expect(
        fresh.activityAt({'m2': created.subtract(const Duration(days: 1))}),
        created,
      );
    });

    test('the timer runs only before a chat starts and before expiry', () {
      final live = _match(
        id: 'm3',
        createdAt: created,
        expiresAt: DateTime.utc(2026, 10, 30),
      );
      expect(
        live.hasRunningTimer(
          chatStarted: false,
          now: DateTime.utc(2026, 10, 20),
        ),
        isTrue,
      );
      expect(
        live.hasRunningTimer(
          chatStarted: true,
          now: DateTime.utc(2026, 10, 20),
        ),
        isFalse,
      );
      expect(
        live.hasRunningTimer(
          chatStarted: false,
          now: DateTime.utc(2026, 11, 20),
        ),
        isFalse,
      );
    });
  });

  group('the sheet with a non-recent default', () {
    Future<void> openSheet(
      WidgetTester tester, {
      required ListFilterState initial,
      required List<ListSortOption> sortOptions,
      ValueChanged<ListFilterState?>? onResult,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localizationProvider.overrideWithValue(l10n)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showListFilterSheet(
                        context: context,
                        l10n: l10n,
                        intentKeys: const [],
                        allIntents: const [],
                        resultCountFor: (_) => 7,
                        showMatchType: false,
                        genderOptions: const [],
                        sortOptions: sortOptions,
                        initial: initial,
                      ).then((result) => onResult?.call(result));
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    test('the default order is not a change, so nothing is flagged', () {
      const pristine = ListFilterState(
        sort: matchDefaultSort,
        defaultSort: matchDefaultSort,
      );
      expect(pristine.isPristine, isTrue);
      expect(pristine.activeCount, 0);

      // "Newest" is still a real option, it is just no longer the default.
      const newest = ListFilterState(
        sort: ListSortOption.recent,
        defaultSort: matchDefaultSort,
      );
      expect(newest.isPristine, isFalse);
    });

    testWidgets('renders the trimmed option list only', (tester) async {
      ListFilterState? applied;
      await openSheet(
        tester,
        initial: const ListFilterState(
          sort: matchDefaultSort,
          defaultSort: matchDefaultSort,
        ),
        sortOptions: matchSortOptions(hasExpiring: false),
        onResult: (result) => applied = result,
      );

      expect(find.text('Latest activity'), findsOneWidget);
      expect(find.text('Newest'), findsOneWidget);
      // Not offered: no expiring match, so no chip and no hidden selection.
      expect(find.text('Expiring soon'), findsNothing);

      await tester.tap(find.text('Show 7 results'));
      await tester.pumpAndSettle();
      expect(applied?.sort, ListSortOption.latestActivity);
      expect(applied?.defaultSort, ListSortOption.latestActivity);
    });

    testWidgets('Clear drops a sort-only change back to the default', (
      tester,
    ) async {
      ListFilterState? applied;
      await openSheet(
        tester,
        initial: const ListFilterState(
          sort: ListSortOption.nameAsc,
          defaultSort: matchDefaultSort,
        ),
        sortOptions: matchSortOptions(hasExpiring: true),
        onResult: (result) => applied = result,
      );

      // The pick shows up as a removable pill so the order is never silent.
      expect(find.text('Name A–Z'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Clear'), findsNothing);

      await tester.tap(find.text('Show 7 results'));
      await tester.pumpAndSettle();
      expect(applied?.sort, ListSortOption.latestActivity);
    });
  });
}
