import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/new_options_provider.dart';

AppProfileOption _option({
  required String fieldKey,
  required String optionKey,
  String? profileValue,
  String? filterValue,
  String displayKey = '',
  int sortOrder = 0,
}) {
  return AppProfileOption(
    fieldKey: fieldKey,
    optionKey: optionKey,
    profileValue: profileValue,
    filterValue: filterValue,
    profileDisplayKey: displayKey,
    filterDisplayKey: displayKey,
    profileSortOrder: sortOrder,
    filterSortOrder: sortOrder,
  );
}

List<String> _keys(List<AppProfileOption> options) =>
    options.map((o) => o.optionKey).toList();

void main() {
  test('the "other" religion option is moved to the end', () {
    final options = [
      _option(
        fieldKey: 'religion',
        optionKey: 'other',
        profileValue: 'Other',
        displayKey: 'religionOther',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'christianity',
        profileValue: 'Christianity',
        displayKey: 'religionChristianity',
        sortOrder: 2,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'islam',
        profileValue: 'Islam',
        displayKey: 'religionIslam',
        sortOrder: 3,
      ),
    ];

    final ordered = orderBeliefOptions(options, fieldKey: 'religion');

    expect(_keys(ordered), ['christianity', 'islam', 'other']);
  });

  test('the "any" religion filter option stays first', () {
    final options = [
      _option(
        fieldKey: 'religion',
        optionKey: 'any_religion',
        filterValue: 'any',
        displayKey: 'settingsReligionAny',
        sortOrder: 0,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'christianity',
        profileValue: 'Christianity',
        filterValue: 'christianity',
        displayKey: 'religionChristianity',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'other',
        profileValue: 'Other',
        filterValue: 'other',
        displayKey: 'religionOther',
        sortOrder: 2,
      ),
    ];

    final ordered = orderBeliefOptions(options, fieldKey: 'religion');

    expect(_keys(ordered), ['any_religion', 'christianity', 'other']);
  });

  test('the "other" branch is the last denomination of its religion', () {
    final options = [
      _option(
        fieldKey: 'denomination',
        optionKey: 'christianity__other',
        profileValue: 'christianity__other',
        displayKey: 'denominationChristianityOther',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'denomination',
        optionKey: 'christianity__catholic',
        profileValue: 'christianity__catholic',
        displayKey: 'denominationChristianityCatholic',
        sortOrder: 2,
      ),
    ];

    final ordered = orderBeliefOptions(options, fieldKey: 'denomination');

    expect(_keys(ordered), ['christianity__catholic', 'christianity__other']);
  });

  test('practice options run from least often to most often', () {
    final options = [
      _option(
        fieldKey: 'practice',
        optionKey: 'daily',
        profileValue: 'daily',
        displayKey: 'practiceDaily',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'weekly',
        profileValue: 'weekly',
        displayKey: 'practiceWeekly',
        sortOrder: 2,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'monthly',
        profileValue: 'monthly',
        displayKey: 'practiceMonthly',
        sortOrder: 3,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'few_times_a_year',
        profileValue: 'few_times_a_year',
        displayKey: 'practiceFewTimesAYear',
        sortOrder: 4,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'rarely_or_never',
        profileValue: 'rarely_or_never',
        displayKey: 'practiceRarelyOrNever',
        sortOrder: 5,
      ),
    ];

    final ordered = orderBeliefOptions(options, fieldKey: 'practice');

    expect(_keys(ordered), [
      'rarely_or_never',
      'few_times_a_year',
      'monthly',
      'weekly',
      'daily',
    ]);
  });

  test('options of other fields keep their stored order', () {
    final options = [
      _option(
        fieldKey: 'diet',
        optionKey: 'vegan',
        profileValue: 'Vegan',
        displayKey: 'lifestyleDietVegan',
        sortOrder: 3,
      ),
      _option(
        fieldKey: 'diet',
        optionKey: 'anything',
        profileValue: 'Anything',
        displayKey: 'lifestyleDietAnything',
        sortOrder: 1,
      ),
    ];

    final ordered = orderBeliefOptions(options, fieldKey: 'diet');

    expect(_keys(ordered), ['vegan', 'anything']);
  });
}
