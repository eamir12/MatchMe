// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'translation_version_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Simple integer version provider used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).state++;

@ProviderFor(TranslationVersion)
final translationVersionProvider = TranslationVersionProvider._();

/// Simple integer version provider used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).state++;
final class TranslationVersionProvider
    extends $NotifierProvider<TranslationVersion, int> {
  /// Simple integer version provider used to force re-evaluation of
  /// translation providers when the app language / translation target changes.
  ///
  /// Increment the value when the app language is changed:
  ///   ref.read(translationVersionProvider.notifier).state++;
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
    r'14a8fefe3a3f7350fb5877584e63a20d8cbf8ce1';

/// Simple integer version provider used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).state++;

abstract class _$TranslationVersion extends $Notifier<int> {
  int build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<int, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<int, int>,
              int,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
