import 'package:flutter_test/flutter_test.dart';

String formatChangeLabel(String changeLabel, String fieldLabel) {
  final trimmed = changeLabel.trim();
  final lastRune = trimmed.isNotEmpty ? trimmed.runes.last : 0;
  final punctuationRunes = <int>{46, 58, 8230}; // '.', ':', '…'
  final endWithPunct = lastRune != 0 && punctuationRunes.contains(lastRune);
  return endWithPunct ? '$changeLabel $fieldLabel' : '$changeLabel: $fieldLabel';
}

void main() {
  test('does not double-colon when changeLabel ends with ellipsis', () {
    final a = formatChangeLabel('Requesting change…', 'Name');
    expect(a, 'Requesting change… Name');
  });

  test('adds colon when changeLabel has no trailing punctuation', () {
    final a = formatChangeLabel('Requesting change', 'Name');
    expect(a, 'Requesting change: Name');
  });

  test('handles changeLabel ending with dot', () {
    final a = formatChangeLabel('Requesting change.', 'Name');
    expect(a, 'Requesting change. Name');
  });
}
