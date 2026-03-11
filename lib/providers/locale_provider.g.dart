// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'locale_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(Localization)
final localizationProvider = LocalizationProvider._();

final class LocalizationProvider
    extends $NotifierProvider<Localization, LocalizationState> {
  LocalizationProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localizationProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localizationHash();

  @$internal
  @override
  Localization create() => Localization();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalizationState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalizationState>(value),
    );
  }
}

String _$localizationHash() => r'b5bf83f237c1dd194bdf7a55e2a136aa17ebab24';

abstract class _$Localization extends $Notifier<LocalizationState> {
  LocalizationState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<LocalizationState, LocalizationState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LocalizationState, LocalizationState>,
              LocalizationState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
