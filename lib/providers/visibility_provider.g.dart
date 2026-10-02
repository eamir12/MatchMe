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

String _$isVisibleHash() => r'f5bb3447f0f3c384d5e2aa3e7609386a9a95dc24';

abstract class _$IsVisible extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
