import 'package:supabase_flutter/supabase_flutter.dart';

/// Model for ad revenue analytics
class AdRevenueAnalytics {
  const AdRevenueAnalytics({
    required this.date,
    required this.placement,
    required this.platform,
    required this.impressions,
    required this.clicks,
    required this.conversions,
    required this.revenueUsd,
  });

  final DateTime date;
  final String placement;
  final String platform;
  final int impressions;
  final int clicks;
  final int conversions;
  final double revenueUsd;

  double get cpm => impressions > 0 ? (revenueUsd / impressions) * 1000 : 0;
  double get cpc => clicks > 0 ? revenueUsd / clicks : 0;
  double get ctr => impressions > 0 ? (clicks / impressions) * 100 : 0;

  factory AdRevenueAnalytics.fromMap(Map<String, dynamic> data) {
    return AdRevenueAnalytics(
      date: data['date'] != null
          ? DateTime.parse(data['date'].toString())
          : DateTime.now(),
      placement: (data['placement'] ?? '').toString(),
      platform: (data['platform'] ?? '').toString(),
      impressions: (data['impressions'] ?? 0) as int,
      clicks: (data['clicks'] ?? 0) as int,
      conversions: (data['conversions'] ?? 0) as int,
      revenueUsd: double.tryParse(data['revenue_usd']?.toString() ?? '0') ?? 0,
    );
  }
}

/// Service for tracking and analyzing ad revenue
class AdRevenueService {
  AdRevenueService({SupabaseClient? supabaseClient})
    : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  /// Get revenue analytics for a network over a date range
  Future<List<AdRevenueAnalytics>> getNetworkAnalytics({
    required String networkId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase.rpc(
        'get_ad_network_analytics',
        params: {
          'p_network_id': networkId,
          'p_start_date': startDate.toIso8601String().split('T')[0],
          'p_end_date': endDate.toIso8601String().split('T')[0],
        },
      );

      {
        return response
            .map(
              (item) => AdRevenueAnalytics.fromMap(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      }
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get analytics: $e');
      return [];
    }
  }

  /// Get total revenue for a date range
  Future<double> getTotalRevenue({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('revenue_usd')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      {
        double total = 0;
        for (final item in response) {
          final revenue = double.tryParse(
            (item as Map)['revenue_usd']?.toString() ?? '0',
          );
          if (revenue != null) {
            total += revenue;
          }
        }
        return total;
      }
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get total revenue: $e');
      return 0;
    }
  }

  /// Get revenue by placement
  Future<Map<String, double>> getRevenueByPlacement({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('placement, revenue_usd')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      final revenueByPlacement = <String, double>{};

      for (final item in response) {
        final map = item as Map;
        final placement = (map['placement'] ?? '').toString();
        final revenue =
            double.tryParse(map['revenue_usd']?.toString() ?? '0') ?? 0;

        revenueByPlacement[placement] =
            (revenueByPlacement[placement] ?? 0) + revenue;
      }

      return revenueByPlacement;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get revenue by placement: $e');
      return {};
    }
  }

  /// Get revenue by platform
  Future<Map<String, double>> getRevenueByPlatform({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('platform, revenue_usd')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      final revenueByPlatform = <String, double>{};

      for (final item in response) {
        final map = item as Map;
        final platform = (map['platform'] ?? '').toString();
        final revenue =
            double.tryParse(map['revenue_usd']?.toString() ?? '0') ?? 0;

        revenueByPlatform[platform] =
            (revenueByPlatform[platform] ?? 0) + revenue;
      }

      return revenueByPlatform;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get revenue by platform: $e');
      return {};
    }
  }

  /// Get revenue by network
  Future<Map<String, double>> getRevenueByNetwork({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('network_id, revenue_usd')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      final revenueByNetwork = <String, double>{};

      for (final item in response) {
        final map = item as Map;
        final networkId = (map['network_id'] ?? '').toString();
        final revenue =
            double.tryParse(map['revenue_usd']?.toString() ?? '0') ?? 0;

        revenueByNetwork[networkId] =
            (revenueByNetwork[networkId] ?? 0) + revenue;
      }

      return revenueByNetwork;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get revenue by network: $e');
      return {};
    }
  }

  /// Get impression count for a date range
  Future<int> getImpressionCount({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('id')
          .eq('event_type', 'impression')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      return response.length;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get impression count: $e');
      return 0;
    }
  }

  /// Get click count for a date range
  Future<int> getClickCount({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final response = await _supabase
          .from('ad_revenue_events')
          .select('id')
          .eq('event_type', 'click')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      return response.length;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get click count: $e');
      return 0;
    }
  }

  /// Get average CPM (cost per thousand impressions)
  Future<double> getAverageCpm({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final totalRevenue = await getTotalRevenue(
        startDate: startDate,
        endDate: endDate,
      );
      final impressions = await getImpressionCount(
        startDate: startDate,
        endDate: endDate,
      );

      if (impressions == 0) {
        return 0;
      }

      return (totalRevenue / impressions) * 1000;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get average CPM: $e');
      return 0;
    }
  }

  /// Get average CPC (cost per click)
  Future<double> getAverageCpc({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final totalRevenue = await getTotalRevenue(
        startDate: startDate,
        endDate: endDate,
      );
      final clicks = await getClickCount(
        startDate: startDate,
        endDate: endDate,
      );

      if (clicks == 0) {
        return 0;
      }

      return totalRevenue / clicks;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get average CPC: $e');
      return 0;
    }
  }

  /// Get click-through rate (CTR)
  Future<double> getClickThroughRate({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final impressions = await getImpressionCount(
        startDate: startDate,
        endDate: endDate,
      );
      final clicks = await getClickCount(
        startDate: startDate,
        endDate: endDate,
      );

      if (impressions == 0) {
        return 0;
      }

      return (clicks / impressions) * 100;
    } catch (e) {
      print('⚠️ [AdRevenueService] Failed to get CTR: $e');
      return 0;
    }
  }
}
