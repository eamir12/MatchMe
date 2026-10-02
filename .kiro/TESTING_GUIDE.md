# Testing Guide - External Ad Network Integration

**Date**: April 22, 2026  
**Status**: Ready to Implement

## Table of Contents
1. [Setup](#setup)
2. [Running Tests](#running-tests)
3. [Test Structure](#test-structure)
4. [Implementing Tests](#implementing-tests)
5. [Mocking Strategy](#mocking-strategy)
6. [Coverage Goals](#coverage-goals)
7. [Troubleshooting](#troubleshooting)

## Setup

### Step 1: Add Testing Dependencies

Add these dependencies to your `pubspec.yaml` dev_dependencies:

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  build_runner: ^2.13.1
  riverpod_generator: ^4.0.0+1
  
  # Testing libraries
  mockito: ^4.4.0
  mocktail: ^1.4.0
  coverage: ^7.2.0
```

Run:
```bash
flutter pub get
```

### Step 2: Create Test Configuration

Create `test/test_setup.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  // This file will contain shared test setup
}
```

### Step 3: Verify Test Structure

Your test directory should look like:
```
test/
├── services/
│   ├── external_ad_service_test.dart
│   ├── mobile_ad_service_test.dart
│   └── web_ad_service_test.dart
├── widgets/
│   └── banner_ad_widget_test.dart
├── integration/
│   └── ad_flow_integration_test.dart
└── test_setup.dart
```

## Running Tests

### Run All Tests
```bash
flutter test
```

### Run Specific Test File
```bash
flutter test test/services/external_ad_service_test.dart
```

### Run Tests with Coverage
```bash
flutter test --coverage
```

### Run Tests with Verbose Output
```bash
flutter test --verbose
```

### Run Tests in Watch Mode
```bash
flutter test --watch
```

### Run Tests with Specific Pattern
```bash
flutter test --name "should create an ad network"
```

## Test Structure

### Unit Tests (test/services/)
Test individual services in isolation with mocked dependencies.

**File**: `test/services/external_ad_service_test.dart`
```dart
void main() {
  group('ExternalAdService', () {
    late ExternalAdService service;
    
    setUp(() {
      // Initialize service with mocks
    });
    
    group('Ad Network Management', () {
      test('should create an ad network', () async {
        // Test implementation
      });
    });
  });
}
```

### Widget Tests (test/widgets/)
Test widgets in isolation with mocked providers.

**File**: `test/widgets/banner_ad_widget_test.dart`
```dart
void main() {
  group('BannerAdWidget', () {
    testWidgets('should display banner ad widget', (WidgetTester tester) async {
      // Test implementation
    });
  });
}
```

### Integration Tests (test/integration/)
Test complete flows with multiple services working together.

**File**: `test/integration/ad_flow_integration_test.dart`
```dart
void main() {
  group('Ad Flow Integration Tests', () {
    test('should complete full ad lifecycle', () async {
      // Test implementation
    });
  });
}
```

## Implementing Tests

### Step 1: Implement Unit Tests for ExternalAdService

Edit `test/services/external_ad_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:mocktail/mocktail.dart';

// Mock Supabase client
class MockSupabaseClient extends Mock implements SupabaseClient {}

void main() {
  group('ExternalAdService', () {
    late ExternalAdService service;
    late MockSupabaseClient mockSupabase;

    setUp(() {
      mockSupabase = MockSupabaseClient();
      // TODO: Initialize service with mock
      // service = ExternalAdService(supabaseClient: mockSupabase);
    });

    group('Ad Network Management', () {
      test('should create an ad network', () async {
        // TODO: Implement test
        // 1. Mock the Supabase response
        // 2. Call service.createAdNetwork()
        // 3. Verify the result
        expect(true, isTrue);
      });

      test('should retrieve all ad networks', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });

      test('should update an ad network', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });

      test('should delete an ad network', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });
    });

    group('Ad Unit Management', () {
      test('should create an ad unit', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });

      test('should retrieve ad units by placement', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });
    });

    group('Revenue Tracking', () {
      test('should record ad impression', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });

      test('should calculate revenue correctly', () async {
        // TODO: Implement test
        expect(true, isTrue);
      });
    });
  });
}
```

### Step 2: Implement Unit Tests for MobileAdService

Edit `test/services/mobile_ad_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/mobile_ad_service.dart';

void main() {
  group('MobileAdService', () {
    late MobileAdService service;

    setUp(() {
      service = MobileAdService(
        admobAppId: 'ca-app-pub-test',
      );
    });

    group('Initialization', () {
      test('should initialize successfully', () async {
        await service.initialize();
        expect(service.isInitialized, isTrue);
      });

      test('should not initialize without app ID', () async {
        final serviceNoId = MobileAdService(admobAppId: null);
        await serviceNoId.initialize();
        expect(serviceNoId.isInitialized, isFalse);
      });
    });

    group('Banner Ads', () {
      test('should load banner ad', () async {
        await service.initialize();
        // TODO: Mock ad loading
        // final loaded = await service.loadBannerAd('home_inline');
        // expect(loaded, isTrue);
        expect(true, isTrue);
      });
    });

    group('Disposal', () {
      test('should dispose resources', () async {
        await service.initialize();
        service.dispose();
        expect(true, isTrue);
      });
    });
  });
}
```

### Step 3: Implement Widget Tests

Edit `test/widgets/banner_ad_widget_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/widgets/banner_ad_widget.dart';

void main() {
  group('BannerAdWidget', () {
    testWidgets('should display banner ad widget', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: BannerAdWidget(
                placement: 'home_inline',
              ),
            ),
          ),
        ),
      );

      // TODO: Verify widget renders
      expect(find.byType(BannerAdWidget), findsOneWidget);
    });

    testWidgets('should call onAdLoaded callback', (WidgetTester tester) async {
      bool adLoaded = false;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: BannerAdWidget(
                placement: 'home_inline',
                onAdLoaded: () {
                  adLoaded = true;
                },
              ),
            ),
          ),
        ),
      );

      // TODO: Trigger ad load
      // await tester.pumpAndSettle();
      // expect(adLoaded, isTrue);
      expect(true, isTrue);
    });

    testWidgets('should display with custom dimensions', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: BannerAdWidget(
                placement: 'home_inline',
                width: 300,
                height: 50,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(BannerAdWidget), findsOneWidget);
    });
  });
}
```

## Mocking Strategy

### Mock Supabase Client

```dart
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockSupabaseClient extends Mock implements SupabaseClient {}

class MockPostgrestQueryBuilder extends Mock implements PostgrestQueryBuilder {}

// Usage in tests
void main() {
  group('ExternalAdService', () {
    late MockSupabaseClient mockSupabase;
    late ExternalAdService service;

    setUp(() {
      mockSupabase = MockSupabaseClient();
      
      // Mock the from() method
      when(() => mockSupabase.from('ad_networks'))
          .thenReturn(MockPostgrestQueryBuilder());
      
      // service = ExternalAdService(supabaseClient: mockSupabase);
    });
  });
}
```

### Mock Riverpod Providers

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Ad Widget with Mocked Provider', () {
    testWidgets('should display ad from mocked provider', (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          // Override the provider with mock data
          // externalAdProvider.overrideWith((ref) => mockAd),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: BannerAdWidget(placement: 'home_inline'),
            ),
          ),
        ),
      );

      expect(find.byType(BannerAdWidget), findsOneWidget);
    });
  });
}
```

## Coverage Goals

### Target Coverage
- Services: > 80%
- Widgets: > 80%
- Integration: > 80%
- Overall: > 80%

### Generate Coverage Report

```bash
# Run tests with coverage
flutter test --coverage

# Generate HTML report (requires lcov)
genhtml coverage/lcov.info -o coverage/html

# View report
open coverage/html/index.html
```

### Coverage by Component

| Component | Target | Current |
|-----------|--------|---------|
| ExternalAdService | 80% | 0% |
| MobileAdService | 80% | 0% |
| WebAdService | 80% | 0% |
| BannerAdWidget | 80% | 0% |
| Integration Tests | 80% | 0% |

## Troubleshooting

### Issue: "flutter_test not found"
**Solution**: Run `flutter pub get`

### Issue: "MockTail not found"
**Solution**: Add `mocktail: ^1.4.0` to dev_dependencies and run `flutter pub get`

### Issue: "ProviderScope not found in test"
**Solution**: Wrap your test widget with `ProviderScope` or use `ProviderContainer`

### Issue: "Test hangs"
**Solution**: Add timeout to test:
```dart
test('should complete', () async {
  // test code
}, timeout: Timeout(Duration(seconds: 10)));
```

### Issue: "Widget not found in test"
**Solution**: Use `tester.pumpAndSettle()` to wait for animations:
```dart
await tester.pumpAndSettle();
expect(find.byType(MyWidget), findsOneWidget);
```

## Testing Checklist

### Before Running Tests
- [ ] All dependencies installed (`flutter pub get`)
- [ ] Test files created in correct locations
- [ ] Mock classes defined
- [ ] Test data prepared

### Running Tests
- [ ] Run all tests: `flutter test`
- [ ] Check for failures
- [ ] Fix failing tests
- [ ] Run with coverage: `flutter test --coverage`
- [ ] Check coverage report

### After Tests Pass
- [ ] Verify coverage > 80%
- [ ] Review test quality
- [ ] Document any issues
- [ ] Commit tests to version control

## Next Steps

1. **Implement Mock Setup** (30 minutes)
   - Create mock classes for Supabase
   - Create mock data for tests
   - Set up test utilities

2. **Implement Unit Tests** (1-2 hours)
   - Implement ExternalAdService tests
   - Implement MobileAdService tests
   - Implement WebAdService tests

3. **Implement Widget Tests** (1 hour)
   - Implement BannerAdWidget tests
   - Implement other widget tests

4. **Implement Integration Tests** (1-2 hours)
   - Implement ad flow tests
   - Implement error handling tests
   - Implement performance tests

5. **Generate Coverage Report** (30 minutes)
   - Run tests with coverage
   - Generate HTML report
   - Review coverage metrics

6. **Optimize and Fix** (1-2 hours)
   - Fix failing tests
   - Improve coverage
   - Optimize test performance

## Summary

**Total Estimated Time**: 4-8 hours

**Key Milestones**:
- ✅ Setup complete
- ⏳ Mock setup (30 min)
- ⏳ Unit tests (1-2 hrs)
- ⏳ Widget tests (1 hr)
- ⏳ Integration tests (1-2 hrs)
- ⏳ Coverage report (30 min)
- ⏳ Optimization (1-2 hrs)

Start with Step 1 (Setup) and follow the guide sequentially!
