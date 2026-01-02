// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'unit_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Provider for determining if imperial units should be used based on location

@ProviderFor(UnitSystem)
const unitSystemProvider = UnitSystemProvider._();

/// Provider for determining if imperial units should be used based on location
final class UnitSystemProvider
    extends $AsyncNotifierProvider<UnitSystem, bool> {
  /// Provider for determining if imperial units should be used based on location
  const UnitSystemProvider._()
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

String _$unitSystemHash() => r'a0ff2f26b2d10eb676cf72f5615d75a471aa4110';

/// Provider for determining if imperial units should be used based on location

abstract class _$UnitSystem extends $AsyncNotifier<bool> {
  FutureOr<bool> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<AsyncValue<bool>, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<bool>, bool>,
              AsyncValue<bool>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
