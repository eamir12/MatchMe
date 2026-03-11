// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'visibility_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(IsVisible)
final isVisibleProvider = IsVisibleProvider._();

final class IsVisibleProvider extends $NotifierProvider<IsVisible, bool> {
  IsVisibleProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isVisibleProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isVisibleHash();

  @$internal
  @override
  IsVisible create() => IsVisible();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isVisibleHash() => r'c46e8fe29b01830eb4ee37f2d203b7c2da73a012';

abstract class _$IsVisible extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
