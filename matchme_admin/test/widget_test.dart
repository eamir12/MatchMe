// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matchme_admin/main.dart';

void main() {
  testWidgets('Admin app builds', (WidgetTester tester) async {
    // AdminApp is a ConsumerWidget (Riverpod), so it needs a ProviderScope
    // ancestor. Without one it throws "No ProviderScope found" before it can
    // ever build its MaterialApp.
    await tester.pumpWidget(const ProviderScope(child: AdminApp()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
