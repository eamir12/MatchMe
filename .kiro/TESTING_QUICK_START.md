# Testing Quick Start - 5 Minute Setup

## Step 1: Update pubspec.yaml (2 minutes)

Add these to your `dev_dependencies` section:

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  mockito: ^4.4.0
  mocktail: ^1.4.0
  coverage: ^7.2.0
```

Then run:
```bash
flutter pub get
```

## Step 2: Run Existing Tests (1 minute)

```bash
# Run all tests
flutter test

# You should see:
# - test/services/external_ad_service_test.dart
# - test/services/mobile_ad_service_test.dart
# - test/services/web_ad_service_test.dart
# - test/widgets/banner_ad_widget_test.dart
# - test/integration/ad_flow_integration_test.dart
```

## Step 3: Check Test Status (1 minute)

```bash
# Run with verbose output to see what's happening
flutter test --verbose

# Expected output:
# ✓ All tests should pass (they're mostly placeholder tests)
```

## Step 4: Generate Coverage Report (1 minute)

```bash
# Run tests with coverage
flutter test --coverage

# View coverage summary
cat coverage/lcov.info | grep -E "^(SF|end_of_record)" | head -20
```

## What's Next?

### Option A: Implement Tests Properly (Recommended)
1. Follow the full guide: `.kiro/TESTING_GUIDE.md`
2. Implement mock setup
3. Implement real test logic
4. Achieve > 80% coverage

### Option B: Run Tests As-Is
1. Tests are structured but use placeholder logic
2. Good for CI/CD pipeline setup
3. Implement real tests later

## Common Commands

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/services/external_ad_service_test.dart

# Run tests matching pattern
flutter test --name "should create"

# Run with coverage
flutter test --coverage

# Run in watch mode (re-run on file changes)
flutter test --watch

# Run with verbose output
flutter test --verbose

# Run with specific number of threads
flutter test -j 4
```

## Troubleshooting

### Tests won't run
```bash
flutter clean
flutter pub get
flutter test
```

### Coverage command not found
```bash
# Install lcov (macOS)
brew install lcov

# Install lcov (Ubuntu)
sudo apt-get install lcov

# Install lcov (Windows)
# Download from: https://github.com/linux-test-project/lcov/releases
```

### Tests hang
- Add timeout: `flutter test --timeout=30s`
- Check for infinite loops in test code
- Verify mock setup is correct

## Next: Implement Real Tests

Once tests are running, follow these steps:

1. **Create Mock Setup** (30 min)
   ```bash
   # Create test/mocks/ directory
   mkdir test/mocks
   
   # Create mock classes
   # test/mocks/mock_supabase.dart
   # test/mocks/mock_ad_service.dart
   ```

2. **Implement Unit Tests** (1-2 hours)
   - Replace TODO comments with real test logic
   - Use mock classes
   - Test all service methods

3. **Implement Widget Tests** (1 hour)
   - Test widget rendering
   - Test callbacks
   - Test state changes

4. **Implement Integration Tests** (1-2 hours)
   - Test complete flows
   - Test error scenarios
   - Test performance

5. **Achieve Coverage** (30 min)
   - Run coverage report
   - Identify gaps
   - Add missing tests

## Success Criteria

✅ All tests run without errors  
✅ Coverage > 80%  
✅ No flaky tests  
✅ Tests complete in < 2 minutes  

---

**Estimated Time to Full Testing**: 4-8 hours  
**Current Status**: Tests structured and ready for implementation
