// windows/runner/flutter_window.cpp registers plugins by hand instead of
// calling GeneratedPluginRegistrant (see the rationale in that file). A plugin
// added to pubspec.yaml is therefore bundled and registered on the Dart side,
// but its native channel stays missing until it is listed there too — the app
// then fails at runtime with
// `Unable to establish connection on channel: dev.flutter.pigeon.<plugin>...`.
// This test fails when the two lists drift apart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Registered only through the custom channels, never through the plugin
/// registry.
const Set<String> intentionallyExcluded = {
  'geolocator_windows',
  'permission_handler_windows',
};

void main() {
  test('every bundled Windows plugin is registered in flutter_window.cpp', () {
    final cmake = File(
      'windows/flutter/generated_plugins.cmake',
    ).readAsStringSync();
    final list = RegExp(
      r'APPEND FLUTTER_PLUGIN_LIST([\s\S]*?)\n\)',
    ).firstMatch(cmake)?.group(1);
    expect(list, isNotNull, reason: 'FLUTTER_PLUGIN_LIST not found');

    final plugins = list!
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toSet();
    final expected = plugins.difference(intentionallyExcluded);

    final runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    final missingIncludes = expected
        .where((plugin) => !runner.contains('#include <$plugin/'))
        .toList();
    expect(
      missingIncludes,
      isEmpty,
      reason: 'Bundled plugin(s) missing from flutter_window.cpp: '
          '${missingIncludes.join(', ')}',
    );

    final registrationCount = RegExp(
      r'RegisterWithRegistrar\(',
    ).allMatches(runner).length;
    expect(
      registrationCount,
      expected.length,
      reason: 'flutter_window.cpp has $registrationCount '
          'RegisterWithRegistrar calls for ${expected.length} bundled plugins',
    );
  });
}
