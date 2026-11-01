import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/list_filter_bar.dart';

/// The filter sheet's Clear affordance.
///
/// Regression guard: an inverted condition once made Clear appear only while the
/// sheet was empty and hide it as soon as the user picked a filter — the exact
/// moment it is most needed. These tests pin the intended behaviour.
void main() {
  final l10n = LocalizationState.loading();

  Future<void> openSheet(
    WidgetTester tester, {
    required ListFilterState initial,
    List<ListSortOption> sortOptions = const [],
    List<Map<String, String>> genderOptions = const [],
    int Function(ListFilterState)? resultCountFor,
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
                      intentKeys: const ['romantic', 'hiking'],
                      allIntents: const [],
                      resultCountFor: resultCountFor ?? (_) => 7,
                      showMatchType: true,
                      genderOptions: genderOptions,
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

  Finder clearButton() => find.widgetWithText(TextButton, 'Clear');

  testWidgets('no Clear when nothing is set', (tester) async {
    await openSheet(tester, initial: const ListFilterState());
    expect(clearButton(), findsNothing);
  });

  testWidgets('Clear appears once an intent filter is chosen', (tester) async {
    await openSheet(
      tester,
      initial: const ListFilterState(selectedIntentKey: 'hiking'),
    );
    expect(clearButton(), findsOneWidget);
  });

  testWidgets('Clear appears once a match type is chosen', (tester) async {
    await openSheet(
      tester,
      initial: const ListFilterState(matchType: MatchTypeFilter.proximity),
    );
    expect(clearButton(), findsOneWidget);
  });

  testWidgets('Clear appears for a sort-only change', (tester) async {
    // Sorting does not increment activeCount, so this is the case an
    // activeCount-based check would get wrong.
    await openSheet(
      tester,
      initial: const ListFilterState(sort: ListSortOption.nameAsc),
      sortOptions: const [ListSortOption.recent, ListSortOption.nameAsc],
    );
    expect(clearButton(), findsOneWidget);
  });

  testWidgets('Clear resets filters and sort to defaults', (tester) async {
    await openSheet(
      tester,
      initial: const ListFilterState(
        selectedIntentKey: 'hiking',
        matchType: MatchTypeFilter.event,
        sort: ListSortOption.nameAsc,
      ),
      sortOptions: const [ListSortOption.recent, ListSortOption.nameAsc],
    );

    await tester.tap(clearButton());
    await tester.pumpAndSettle();

    // Back to the pristine state, so Clear goes away again and no pills remain.
    expect(clearButton(), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('a non-default sort does not inflate the filter badge', (
    tester,
  ) async {
    // Sorting narrows nothing, so counting it would misreport how much the
    // list is reduced.
    const withSort = ListFilterState(sort: ListSortOption.nameAsc);
    expect(withSort.activeCount, 0);
    expect(withSort.isPristine, isFalse);

    const withFilter = ListFilterState(selectedIntentKey: 'hiking');
    expect(withFilter.activeCount, 1);
  });

  testWidgets('removing a summary pill drops that filter', (tester) async {
    await openSheet(
      tester,
      initial: const ListFilterState(selectedIntentKey: 'hiking'),
    );

    // The intent shows up as a removable pill in the header. Matched on the
    // remove affordance rather than the label text, which falls back to the raw
    // key when no AppIntent row exists to translate it.
    final removePill = find.byIcon(Icons.close_rounded);
    expect(removePill, findsOneWidget);

    await tester.tap(removePill);
    await tester.pumpAndSettle();

    // Removing the only filter makes the state pristine again.
    expect(removePill, findsNothing);
    expect(clearButton(), findsNothing);
  });

  testWidgets('gender options narrow the list and report the chosen key', (
    tester,
  ) async {
    ListFilterState? applied;
    await openSheet(
      tester,
      initial: const ListFilterState(),
      genderOptions: const [
        {'key': 'female', 'displayKey': 'gender_female'},
        {'key': 'male', 'displayKey': 'gender_male'},
      ],
      resultCountFor: (draft) => draft.selectedGenderKey == 'female' ? 4 : 7,
      onResult: (result) => applied = result,
    );

    expect(find.text('GENDER'), findsOneWidget);
    // "All" also labels the match-type card, so assert on the option chips
    // unique to the new section instead.
    expect(find.text('Female'), findsOneWidget);
    expect(find.text('Male'), findsOneWidget);

    await tester.tap(find.text('Female'));
    await tester.pumpAndSettle();

    expect(find.text('Show 4 results'), findsOneWidget);
    await tester.tap(find.text('Show 4 results'));
    await tester.pumpAndSettle();

    expect(applied?.selectedGenderKey, 'female');
  });

  testWidgets('a gender filter counts as one active filter', (tester) async {
    const state = ListFilterState(selectedGenderKey: 'female');
    expect(state.activeCount, 1);
    expect(state.isPristine, isFalse);
  });

  testWidgets('the extra toggle is hidden when it has nothing to act on', (
    tester,
  ) async {
    await openSheet(
      tester,
      initial: const ListFilterState(
        extraToggleKey: 'unread',
        extraToggleLabel: 'Unread only',
        extraToggleVisible: false,
      ),
    );

    expect(find.text('Unread only'), findsNothing);
    expect(find.text('OPTIONS'), findsNothing);
  });

  testWidgets('the extra toggle stays visible while it is active', (
    tester,
  ) async {
    await openSheet(
      tester,
      initial: const ListFilterState(
        extraToggleKey: 'unread',
        extraToggleLabel: 'Unread only',
        extraToggleVisible: false,
        extraToggleActive: true,
      ),
    );

    // Even with nothing left to narrow, the switch must stay reachable so the
    // user can turn the filter off. The label appears twice: the summary pill
    // and the switch title.
    expect(find.text('Unread only'), findsWidgets);
    expect(find.text('OPTIONS'), findsOneWidget);
  });
}
