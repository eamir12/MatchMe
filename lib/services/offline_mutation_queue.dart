import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Represents a pending mutation to be synced when online
class OfflineMutation {
  final String id;
  // 'insert', 'update', 'delete', or 'rpc' (table = function name,
  // payload = RPC params).
  final String type;
  final String table;
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? where; // For update/delete
  final DateTime createdAt;
  final int retryCount;
  final String? errorMessage;

  OfflineMutation({
    String? id,
    required this.type,
    required this.table,
    required this.payload,
    this.where,
    DateTime? createdAt,
    this.retryCount = 0,
    this.errorMessage,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'table': table,
    'payload': payload,
    'where': where,
    'created_at': createdAt.toIso8601String(),
    'retry_count': retryCount,
    'error_message': errorMessage,
  };

  factory OfflineMutation.fromJson(Map<String, dynamic> json) {
    return OfflineMutation(
      id: json['id'] as String,
      type: json['type'] as String,
      table: json['table'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      where: json['where'] != null
          ? Map<String, dynamic>.from(json['where'] as Map)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      retryCount: json['retry_count'] as int? ?? 0,
      errorMessage: json['error_message'] as String?,
    );
  }

  OfflineMutation copyWith({
    String? id,
    String? type,
    String? table,
    Map<String, dynamic>? payload,
    Map<String, dynamic>? where,
    DateTime? createdAt,
    int? retryCount,
    String? errorMessage,
  }) {
    return OfflineMutation(
      id: id ?? this.id,
      type: type ?? this.type,
      table: table ?? this.table,
      payload: payload ?? this.payload,
      where: where ?? this.where,
      createdAt: createdAt ?? this.createdAt,
      retryCount: retryCount ?? this.retryCount,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Manages offline mutations and syncs them when online
class OfflineMutationQueue {
  static const String _boxName = 'offline_mutations';
  static final OfflineMutationQueue _instance = OfflineMutationQueue._();

  late Box<Map<dynamic, dynamic>> _box;
  Future<void>? _initFuture;
  final _queueChangedController =
      StreamController<List<OfflineMutation>>.broadcast();

  factory OfflineMutationQueue() {
    return _instance;
  }

  static OfflineMutationQueue get instance => _instance;

  OfflineMutationQueue._();

  Future<void> initialize() async {
    _initFuture ??= _doInit();
    await _initFuture!;
  }

  /// Lazily completes initialization so public methods called before
  /// bootstrap's unawaited initialize() (e.g. a chat toggle queued in the
  /// first seconds of app life) cannot hit an uninitialized box.
  Future<void> _ensureInitialized() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    // Encrypted: queued payloads can contain profile text, visibility rules, etc.
    _box = await HiveEncryptionService.instance
        .openEncryptedBox<Map<dynamic, dynamic>>(_boxName);
    print(
      '[OfflineMutationQueue] Initialized with ${_box.length} pending mutations',
    );
  }

  /// Add a mutation to the queue
  Future<void> queueMutation({
    required String type,
    required String table,
    required Map<String, dynamic> payload,
    Map<String, dynamic>? where,
  }) async {
    await _ensureInitialized();
    final mutation = OfflineMutation(
      type: type,
      table: table,
      payload: payload,
      where: where,
    );

    await _box.put(mutation.id, mutation.toJson());
    print(
      '[OfflineMutationQueue] Queued ${mutation.type} on $table: ${mutation.id}',
    );
    _notifyListeners();
  }

  /// Get all pending mutations
  Future<List<OfflineMutation>> getPendingMutations() async {
    await _ensureInitialized();
    final mutations = <OfflineMutation>[];
    for (final key in _box.keys) {
      final data = _box.get(key) as Map<dynamic, dynamic>;
      mutations.add(OfflineMutation.fromJson(Map<String, dynamic>.from(data)));
    }
    // Sort by creation time to maintain order
    mutations.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return mutations;
  }

  /// Sync all pending mutations to Supabase
  Future<SyncResult> syncPendingMutations({
    required SupabaseClient supabase,
  }) async {
    if (shouldSkipSupabaseCalls()) {
      return SyncResult(successful: 0, failed: 0, errors: []);
    }

    final mutations = await getPendingMutations();
    if (mutations.isEmpty) {
      return SyncResult(successful: 0, failed: 0, errors: []);
    }

    int successful = 0;
    int failed = 0;
    final errors = <String>[];

    print(
      '[OfflineMutationQueue] Starting sync of ${mutations.length} mutations',
    );

    for (final mutation in mutations) {
      try {
        await _executeMutation(mutation, supabase: supabase);
        await _box.delete(mutation.id);
        successful++;
        print(
          '[OfflineMutationQueue] ✅ Synced: ${mutation.type} on ${mutation.table}',
        );
      } on PostgrestException catch (e) {
        final isPermanent =
            e.code == '42501' || // RLS violation
            e.code == '23503' || // Foreign key violation
            e.code == '42P01'; // Table not found

        if (isPermanent) {
          print(
            '[OfflineMutationQueue] 🛑 Permanent failure for ${mutation.table}: ${e.message}. Removing from queue.',
          );
          await _box.delete(mutation.id);
          failed++;
          errors.add('${mutation.table} (PERMANENT): ${e.message}');
        } else {
          failed++;
          final errorMsg = e.message;
          errors.add('${mutation.table}: $errorMsg');

          // Update retry count and error
          final updated = mutation.copyWith(
            retryCount: mutation.retryCount + 1,
            errorMessage: errorMsg,
          );
          await _box.put(mutation.id, updated.toJson());

          print(
            '[OfflineMutationQueue] ❌ Failed: ${mutation.table} - $errorMsg',
          );
        }
      } catch (e) {
        failed++;
        final errorMsg = e.toString();
        errors.add('${mutation.table}: $errorMsg');

        final updated = mutation.copyWith(
          retryCount: mutation.retryCount + 1,
          errorMessage: errorMsg,
        );
        await _box.put(mutation.id, updated.toJson());

        print('[OfflineMutationQueue] ❌ Failed: ${mutation.table} - $e');
      }
    }

    _notifyListeners();
    print(
      '[OfflineMutationQueue] Sync complete: $successful successful, $failed failed',
    );

    return SyncResult(successful: successful, failed: failed, errors: errors);
  }

  /// Execute a single mutation
  Future<void> _executeMutation(
    OfflineMutation mutation, {
    required SupabaseClient supabase,
  }) async {
    final query = supabase.from(mutation.table);

    switch (mutation.type) {
      case 'insert':
        await query.insert(mutation.payload);
        break;
      case 'rpc':
        await supabase.rpc(mutation.table, params: mutation.payload);
        break;
      case 'update':
        if (mutation.where == null) {
          throw Exception('Update mutation requires where clause');
        }
        var updateQuery = query.update(mutation.payload);
        mutation.where!.forEach((key, value) {
          updateQuery = updateQuery.eq(key, value);
        });
        await updateQuery;
        break;
      case 'delete':
        if (mutation.where == null) {
          throw Exception('Delete mutation requires where clause');
        }
        var deleteQuery = query.delete();
        mutation.where!.forEach((key, value) {
          deleteQuery = deleteQuery.eq(key, value);
        });
        await deleteQuery;
        break;
      default:
        throw Exception('Unknown mutation type: ${mutation.type}');
    }
  }

  /// Clear failed mutations after max retries
  Future<void> clearFailedMutations({int maxRetries = 5}) async {
    final mutations = await getPendingMutations();
    int cleared = 0;

    for (final mutation in mutations) {
      if (mutation.retryCount >= maxRetries) {
        await _box.delete(mutation.id);
        cleared++;
        print('[OfflineMutationQueue] Cleared failed mutation: ${mutation.id}');
      }
    }

    if (cleared > 0) {
      _notifyListeners();
      print('[OfflineMutationQueue] Cleared $cleared failed mutations');
    }
  }

  /// Get count of pending mutations
  Future<int> getPendingCount() async {
    await _ensureInitialized();
    return _box.length;
  }

  /// Clear all mutations (use with caution!)
  Future<void> clearAll() async {
    await _box.clear();
    _notifyListeners();
    print('[OfflineMutationQueue] Cleared all mutations');
  }

  /// Listen to queue changes
  Stream<List<OfflineMutation>> get queueChanged =>
      _queueChangedController.stream;

  void _notifyListeners() {
    Future.microtask(() async {
      final mutations = await getPendingMutations();
      _queueChangedController.add(mutations);
    });
  }

  void dispose() {
    _queueChangedController.close();
  }
}

/// Result of syncing mutations
class SyncResult {
  final int successful;
  final int failed;
  final List<String> errors;

  SyncResult({
    required this.successful,
    required this.failed,
    required this.errors,
  });

  bool get isSuccess => failed == 0;
  int get total => successful + failed;
}
