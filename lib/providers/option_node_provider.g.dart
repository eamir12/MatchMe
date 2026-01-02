// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'option_node_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(fetchChildren)
const fetchChildrenProvider = FetchChildrenFamily._();

final class FetchChildrenProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Map<String, dynamic>>>,
          List<Map<String, dynamic>>,
          FutureOr<List<Map<String, dynamic>>>
        >
    with
        $FutureModifier<List<Map<String, dynamic>>>,
        $FutureProvider<List<Map<String, dynamic>>> {
  const FetchChildrenProvider._({
    required FetchChildrenFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'fetchChildrenProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$fetchChildrenHash();

  @override
  String toString() {
    return r'fetchChildrenProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<Map<String, dynamic>>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<Map<String, dynamic>>> create(Ref ref) {
    final argument = this.argument as String;
    return fetchChildren(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is FetchChildrenProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$fetchChildrenHash() => r'12c33f59664a523a86d33c2daa366b90951172a2';

final class FetchChildrenFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<Map<String, dynamic>>>,
          String
        > {
  const FetchChildrenFamily._()
    : super(
        retry: null,
        name: r'fetchChildrenProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  FetchChildrenProvider call(String parentKey) =>
      FetchChildrenProvider._(argument: parentKey, from: this);

  @override
  String toString() => r'fetchChildrenProvider';
}
