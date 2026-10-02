import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/services/mobile_ad_service.dart';
import 'package:matchme/services/web_ad_service.dart';

// ============================================================================
// MOCK CLASSES
// ============================================================================

/// Mock Supabase Client
class MockSupabaseClient extends Mock implements SupabaseClient {}

/// Mock Postgrest Query Builder - simplified to avoid type conflicts
class MockPostgrestQueryBuilder extends Mock {
  MockPostgrestQueryBuilder select([String columns = '*']) => this;
  MockPostgrestQueryBuilder eq(String column, dynamic value) => this;
  MockPostgrestQueryBuilder order(String column, {bool ascending = true}) =>
      this;
  MockPostgrestQueryBuilder limit(int count) => this;
  MockPostgrestQueryBuilder insert(dynamic values, {bool returning = true}) =>
      this;
  MockPostgrestQueryBuilder update(dynamic values) => this;
  MockPostgrestQueryBuilder delete() => this;
  Future<List> execute() async => [];
}

/// Mock Postgrest Filter Builder
class MockPostgrestFilterBuilder extends Mock {
  MockPostgrestFilterBuilder eq(String column, dynamic value) => this;
  MockPostgrestFilterBuilder order(String column, {bool ascending = true}) =>
      this;
  MockPostgrestFilterBuilder limit(int count) => this;
  Future<List> execute() async => [];
}

/// Mock Postgrest Transform Builder
class MockPostgrestTransformBuilder extends Mock {
  MockPostgrestTransformBuilder order(String column, {bool ascending = true}) =>
      this;
  MockPostgrestTransformBuilder limit(int count) => this;
  Future<List> execute() async => [];
}

// ============================================================================
// MOCK DATA
// ============================================================================

/// Sample ad network for testing
final mockAdNetwork = ExternalAdNetwork(
  id: 'test-network-1',
  provider: 'admob',
  displayName: 'Test AdMob Network',
  isEnabled: true,
  priority: 100,
  config: {
    'app_id': 'ca-app-pub-test',
    'test_device_ids': ['test-device-1'],
  },
);

/// Sample ad unit for testing
final mockAdUnit = AdUnit(
  id: 'test-unit-1',
  networkId: 'test-network-1',
  placement: 'home_inline',
  platform: 'android',
  adUnitId: 'ca-pub-test/test-unit',
  adFormat: 'banner',
  isActive: true,
  priority: 100,
);

/// Sample ad consent for testing
final mockAdConsent = AdConsent(
  userId: 'test-user-1',
  personalizedAds: true,
  nonPersonalizedAds: true,
  consentGivenAt: DateTime.now(),
  consentVersion: '1.0',
);

// ============================================================================
// MOCK SETUP HELPERS
// ============================================================================

/// Setup mock Supabase client with default responses
MockSupabaseClient setupMockSupabase() {
  final mockSupabase = MockSupabaseClient();

  // Mock the from() method to return a query builder
  // Cast to SupabaseQueryBuilder to satisfy type requirements
  when(
    () => mockSupabase.from('ad_networks'),
  ).thenReturn(MockPostgrestQueryBuilder() as SupabaseQueryBuilder);

  when(
    () => mockSupabase.from('ad_units'),
  ).thenReturn(MockPostgrestQueryBuilder() as SupabaseQueryBuilder);

  when(
    () => mockSupabase.from('ad_revenue_events'),
  ).thenReturn(MockPostgrestQueryBuilder() as SupabaseQueryBuilder);

  when(
    () => mockSupabase.from('ad_consent'),
  ).thenReturn(MockPostgrestQueryBuilder() as SupabaseQueryBuilder);

  return mockSupabase;
}

/// Setup mock query builder with select response
MockPostgrestQueryBuilder setupMockQueryBuilderWithSelect(
  List<Map<String, dynamic>> data,
) {
  final mockBuilder = MockPostgrestQueryBuilder();

  // Mock the select() method
  when(() => mockBuilder.select()).thenReturn(mockBuilder);

  // Mock the eq() method for filtering
  when(() => mockBuilder.eq(any(), any())).thenReturn(mockBuilder);

  // Mock the order() method
  when(() => mockBuilder.order(any())).thenReturn(mockBuilder);

  // Mock the limit() method
  when(() => mockBuilder.limit(any())).thenReturn(mockBuilder);

  // Mock the insert() method
  when(() => mockBuilder.insert(any())).thenReturn(mockBuilder);

  // Mock the update() method
  when(() => mockBuilder.update(any())).thenReturn(mockBuilder);

  // Mock the delete() method
  when(() => mockBuilder.delete()).thenReturn(mockBuilder);

  // Mock the execute() method to return data
  when(() => mockBuilder.execute()).thenAnswer((_) async => data);

  return mockBuilder;
}

// ============================================================================
// SERVICE SETUP HELPERS
// ============================================================================

/// Create a test instance of MobileAdService
MobileAdService createTestMobileAdService() {
  return MobileAdService(admobAppId: 'ca-app-pub-test');
}

/// Create a test instance of WebAdService
WebAdService createTestWebAdService() {
  return WebAdService(publisherId: 'ca-pub-test');
}

// ============================================================================
// ASSERTION HELPERS
// ============================================================================

/// Verify that a method was called with specific arguments
void verifyMethodCalled(dynamic mock, String methodName, List<dynamic> args) {
  // TODO: Implement verification logic
  // This is a placeholder for custom verification
}

/// Verify that a method was NOT called
void verifyMethodNotCalled(dynamic mock, String methodName) {
  // TODO: Implement verification logic
  // This is a placeholder for custom verification
}

// ============================================================================
// TEST DATA BUILDERS
// ============================================================================

/// Builder for creating test ad networks
class AdNetworkBuilder {
  String id = 'test-network-1';
  String provider = 'admob';
  String displayName = 'Test Network';
  bool isEnabled = true;
  int priority = 100;
  Map<String, dynamic> config = {};

  AdNetworkBuilder withId(String id) {
    this.id = id;
    return this;
  }

  AdNetworkBuilder withProvider(String provider) {
    this.provider = provider;
    return this;
  }

  AdNetworkBuilder withDisplayName(String displayName) {
    this.displayName = displayName;
    return this;
  }

  AdNetworkBuilder withEnabled(bool isEnabled) {
    this.isEnabled = isEnabled;
    return this;
  }

  AdNetworkBuilder withPriority(int priority) {
    this.priority = priority;
    return this;
  }

  AdNetworkBuilder withConfig(Map<String, dynamic> config) {
    this.config = config;
    return this;
  }

  ExternalAdNetwork build() {
    return ExternalAdNetwork(
      id: id,
      provider: provider,
      displayName: displayName,
      isEnabled: isEnabled,
      priority: priority,
      config: config,
    );
  }
}

/// Builder for creating test ad units
class AdUnitBuilder {
  String id = 'test-unit-1';
  String networkId = 'test-network-1';
  String placement = 'home_inline';
  String platform = 'android';
  String adUnitId = 'ca-pub-test/test-unit';
  String adFormat = 'banner';
  bool isActive = true;
  int priority = 100;

  AdUnitBuilder withId(String id) {
    this.id = id;
    return this;
  }

  AdUnitBuilder withNetworkId(String networkId) {
    this.networkId = networkId;
    return this;
  }

  AdUnitBuilder withPlacement(String placement) {
    this.placement = placement;
    return this;
  }

  AdUnitBuilder withPlatform(String platform) {
    this.platform = platform;
    return this;
  }

  AdUnitBuilder withAdUnitId(String adUnitId) {
    this.adUnitId = adUnitId;
    return this;
  }

  AdUnitBuilder withAdFormat(String adFormat) {
    this.adFormat = adFormat;
    return this;
  }

  AdUnitBuilder withActive(bool isActive) {
    this.isActive = isActive;
    return this;
  }

  AdUnitBuilder withPriority(int priority) {
    this.priority = priority;
    return this;
  }

  AdUnit build() {
    return AdUnit(
      id: id,
      networkId: networkId,
      placement: placement,
      platform: platform,
      adUnitId: adUnitId,
      adFormat: adFormat,
      isActive: isActive,
      priority: priority,
    );
  }
}

// ============================================================================
// USAGE EXAMPLES
// ============================================================================

/*
// Example 1: Using mock setup in a test
void main() {
  group('ExternalAdService', () {
    late MockSupabaseClient mockSupabase;
    late ExternalAdService service;

    setUp(() {
      mockSupabase = setupMockSupabase();
      // service = ExternalAdService(supabaseClient: mockSupabase);
    });

    test('should create an ad network', () async {
      // Arrange
      final network = AdNetworkBuilder()
          .withProvider('admob')
          .withDisplayName('Test Network')
          .build();

      // Act
      // final result = await service.createAdNetwork(network);

      // Assert
      // expect(result.id, isNotEmpty);
    });
  });
}

// Example 2: Using test data builders
void main() {
  test('should handle multiple networks', () async {
    final networks = [
      AdNetworkBuilder().withProvider('admob').build(),
      AdNetworkBuilder().withProvider('facebook').build(),
      AdNetworkBuilder().withProvider('applovin').build(),
    ];

    expect(networks.length, equals(3));
  });
}

// Example 3: Using service setup helpers
void main() {
  test('should initialize mobile ad service', () async {
    final service = createTestMobileAdService();
    await service.initialize();
    expect(service.isInitialized, isTrue);
  });
}
*/
