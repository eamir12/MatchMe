/// Represents a queued subscription entry
class SubscriptionQueueEntry {
  final String id;
  final String userId;
  final String tier;
  final String status; // 'pending', 'active', 'completed', 'cancelled'
  final DateTime startsAt;
  final DateTime expiresAt;
  final String? paymentProvider; // 'revenuecat', 'stripe', 'manual'
  final String? transactionId;
  final Map<String, dynamic> purchaseMetadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? activatedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;

  SubscriptionQueueEntry({
    required this.id,
    required this.userId,
    required this.tier,
    required this.status,
    required this.startsAt,
    required this.expiresAt,
    this.paymentProvider,
    this.transactionId,
    this.purchaseMetadata = const {},
    required this.createdAt,
    required this.updatedAt,
    this.activatedAt,
    this.cancelledAt,
    this.cancellationReason,
  });

  factory SubscriptionQueueEntry.fromMap(Map<String, dynamic> map) {
    return SubscriptionQueueEntry(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      tier: map['tier'] as String,
      status: map['status'] as String,
      startsAt: DateTime.parse(map['starts_at'] as String),
      expiresAt: DateTime.parse(map['expires_at'] as String),
      paymentProvider: map['payment_provider'] as String?,
      transactionId: map['transaction_id'] as String?,
      purchaseMetadata: (map['purchase_metadata'] as Map<String, dynamic>?) ?? {},
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      activatedAt: map['activated_at'] != null 
          ? DateTime.parse(map['activated_at'] as String) 
          : null,
      cancelledAt: map['cancelled_at'] != null 
          ? DateTime.parse(map['cancelled_at'] as String) 
          : null,
      cancellationReason: map['cancellation_reason'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'tier': tier,
      'status': status,
      'starts_at': startsAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
      'payment_provider': paymentProvider,
      'transaction_id': transactionId,
      'purchase_metadata': purchaseMetadata,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'activated_at': activatedAt?.toIso8601String(),
      'cancelled_at': cancelledAt?.toIso8601String(),
      'cancellation_reason': cancellationReason,
    };
  }

  /// Check if this entry is currently active
  bool get isActive => status == 'active';

  /// Check if this entry is pending (waiting to start)
  bool get isPending => status == 'pending';

  /// Check if this entry has been cancelled
  bool get isCancelled => status == 'cancelled';

  /// Check if this entry has completed
  bool get isCompleted => status == 'completed';

  /// Get the duration of this subscription
  Duration get duration => expiresAt.difference(startsAt);

  /// Check if this subscription has started
  bool get hasStarted => DateTime.now().isAfter(startsAt) || DateTime.now().isAtSameMomentAs(startsAt);

  /// Check if this subscription has expired
  bool get hasExpired => DateTime.now().isAfter(expiresAt);

  /// Get remaining time until this subscription starts (null if already started)
  Duration? get timeUntilStart {
    if (hasStarted) return null;
    return startsAt.difference(DateTime.now());
  }

  /// Get remaining time until this subscription expires (null if not active or expired)
  Duration? get timeUntilExpiry {
    if (!isActive && !isPending) return null;
    if (hasExpired) return Duration.zero;
    return expiresAt.difference(DateTime.now());
  }

  SubscriptionQueueEntry copyWith({
    String? id,
    String? userId,
    String? tier,
    String? status,
    DateTime? startsAt,
    DateTime? expiresAt,
    String? paymentProvider,
    String? transactionId,
    Map<String, dynamic>? purchaseMetadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? activatedAt,
    DateTime? cancelledAt,
    String? cancellationReason,
  }) {
    return SubscriptionQueueEntry(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      tier: tier ?? this.tier,
      status: status ?? this.status,
      startsAt: startsAt ?? this.startsAt,
      expiresAt: expiresAt ?? this.expiresAt,
      paymentProvider: paymentProvider ?? this.paymentProvider,
      transactionId: transactionId ?? this.transactionId,
      purchaseMetadata: purchaseMetadata ?? this.purchaseMetadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      activatedAt: activatedAt ?? this.activatedAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      cancellationReason: cancellationReason ?? this.cancellationReason,
    );
  }

  @override
  String toString() {
    return 'SubscriptionQueueEntry(id: $id, tier: $tier, status: $status, startsAt: $startsAt, expiresAt: $expiresAt)';
  }
}

/// Result of a subscription normalization operation
class SubscriptionNormalizationResult {
  final String? previousTier;
  final String? newTier;
  final bool normalized;

  SubscriptionNormalizationResult({
    this.previousTier,
    this.newTier,
    required this.normalized,
  });

  /// Check if subscription was upgraded
  bool get wasUpgraded {
    if (previousTier == null || newTier == null) return false;
    final tierOrder = {'free': 0, 'plus': 1, 'gold': 2, 'platinum': 3};
    final prev = tierOrder[previousTier?.toLowerCase()] ?? 0;
    final next = tierOrder[newTier?.toLowerCase()] ?? 0;
    return next > prev;
  }

  /// Check if subscription was downgraded
  bool get wasDowngraded {
    if (previousTier == null || newTier == null) return false;
    final tierOrder = {'free': 0, 'plus': 1, 'gold': 2, 'platinum': 3};
    final prev = tierOrder[previousTier?.toLowerCase()] ?? 0;
    final next = tierOrder[newTier?.toLowerCase()] ?? 0;
    return next < prev;
  }

  /// Check if tier changed
  bool get tierChanged => previousTier != newTier;

  @override
  String toString() {
    return 'SubscriptionNormalizationResult(previousTier: $previousTier, newTier: $newTier, normalized: $normalized)';
  }
}

/// Represents the subscription timeline for a user
class SubscriptionTimeline {
  final SubscriptionQueueEntry? current;
  final List<SubscriptionQueueEntry> queued;

  SubscriptionTimeline({
    this.current,
    required this.queued,
  });

  /// Check if user has any active or pending subscription
  bool get hasAnySubscription => current != null || queued.isNotEmpty;

  /// Get the total number of queued subscriptions
  int get queuedCount => queued.length;

  /// Get the next subscription to start (first in queue)
  SubscriptionQueueEntry? get nextInQueue => queued.isNotEmpty ? queued.first : null;

  /// Get the last subscription expiry date (including current and all queued)
  DateTime? get lastExpiryDate {
    if (queued.isNotEmpty) {
      return queued.last.expiresAt;
    }
    return current?.expiresAt;
  }

  /// Get total subscription coverage period
  Duration? get totalCoverage {
    final start = current?.startsAt ?? queued.firstOrNull?.startsAt;
    final end = lastExpiryDate;
    if (start == null || end == null) return null;
    return end.difference(start);
  }
}
