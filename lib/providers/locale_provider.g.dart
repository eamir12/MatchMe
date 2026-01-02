// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'locale_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(Localization)
const localizationProvider = LocalizationProvider._();

final class LocalizationProvider
    extends $NotifierProvider<Localization, LocalizationState> {
  const LocalizationProvider._()
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

String _$localizationHash() => r'e73e4c05a965e1b92b3375499f0395a8bc69cfe7';

abstract class _$Localization extends $Notifier<LocalizationState> {
  LocalizationState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<LocalizationState, LocalizationState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LocalizationState, LocalizationState>,
              LocalizationState,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
