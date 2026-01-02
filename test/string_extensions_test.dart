import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/string_extensions.dart';

void main() {
  test('formatAsFirstNameLastInitial wraps with LRM and produces initial', () {
    final input = 'John Smith';
    final out = input.formatAsFirstNameLastInitial();
    expect(out.startsWith('\u200E'), true);
    expect(out.endsWith('\u200E'), true);
    expect(out.contains('John'), true);
    expect(out.contains('S.'), true);
  });

  test('formatAsFirstNameLastInitial handles single name', () {
    final input = 'Alice';
    final out = input.formatAsFirstNameLastInitial();
    expect(out, '\u200EAlice\u200E');
  });
}
