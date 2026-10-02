// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'translation_version_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Integer version provider with debounce used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Multiple rapid calls to increment() are coalesced into a single
/// state change via a 100ms debounce timer.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).increment();

@ProviderFor(TranslationVersion)
final translationVersionProvider = TranslationVersionProvider._();

/// Integer version provider with debounce used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Multiple rapid calls to increment() are coalesced into a single
/// state change via a 100ms debounce timer.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).increment();
final class TranslationVersionProvider
    extends $NotifierProvider<TranslationVersion, int> {
  /// Integer version provider with debounce used to force re-evaluation of
  /// translation providers when the app language / translation target changes.
  ///
  /// Multiple rapid calls to increment() are coalesced into a single
  /// state change via a 100ms debounce timer.
  ///
  /// Increment the value when the app language is changed:
  ///   ref.read(translationVersionProvider.notifier).increment();
  TranslationVersionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'translationVersionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$translationVersionHash();

  @$internal
  @override
  TranslationVersion create() => TranslationVersion();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$translationVersionHash() =>
    r'4076d63188f76c4d846101b6dd9801556275d327';

/// Integer version provider with debounce used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Multiple rapid calls to increment() are coalesced into a single
/// state change via a 100ms debounce timer.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).increment();

abstract class _$TranslationVersion extends $Notifier<int> {
  int build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<int, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<int, int>,
              int,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
