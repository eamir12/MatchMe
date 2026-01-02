import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';

void main() {
  test('date_of_birth string with time/UTC is normalized to date-only', () {
    final data = {'id': '1', 'name': 'Alice', 'dateOfBirth': '2000-01-01T00:00:00Z'};
    final profile = UserProfile.fromMap(data);
    expect(profile.dateOfBirth, DateTime(2000, 1, 1));
  });

  test('date_of_birth string in local format is normalized to date-only', () {
    final data = {'id': '2', 'name': 'Bob', 'date_of_birth': '1995-12-31'};
    final profile = UserProfile.fromMap(data);
    expect(profile.dateOfBirth, DateTime(1995, 12, 31));
  });

  test('date_of_birth parsing handles null gracefully', () {
    final data = {'id': '3', 'name': 'Carla'};
    final profile = UserProfile.fromMap(data);
    expect(profile.dateOfBirth, isNull);
  });
}
