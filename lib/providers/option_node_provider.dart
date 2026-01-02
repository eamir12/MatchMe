// lib/providers/option_node_provider.dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/services/local_db_service.dart';

part 'option_node_provider.g.dart';

// Provider to fetch children for option nodes from local cache
@riverpod
Future<List<Map<String, dynamic>>> fetchChildren(Ref ref, String parentKey) async {
  final localDb = ref.watch(localDbProvider);
  return localDb.getOptionChildren(parentKey);
}
