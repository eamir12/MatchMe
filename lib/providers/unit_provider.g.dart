// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'unit_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Provider for determining if imperial units should be used based on location

@ProviderFor(UnitSystem)
final unitSystemProvider = UnitSystemProvider._();

/// Provider for determining if imperial units should be used based on location
final class UnitSystemProvider
    extends $AsyncNotifierProvider<UnitSystem, bool> {
  /// Provider for determining if imperial units should be used based on location
  UnitSystemProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'unitSystemProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$unitSystemHash();

  @$internal
  @override
  UnitSystem create() => UnitSystem();
}

String _$unitSystemHash() => r'cabe5564b2e32b82ba0e66f3fd6a71db6251da7a';

/// Provider for determining if imperial units should be used based on location

abstract class _$UnitSystem extends $AsyncNotifier<bool> {
  FutureOr<bool> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<AsyncValue<bool>, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<bool>, bool>,
              AsyncValue<bool>,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
