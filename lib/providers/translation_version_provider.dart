// lib/providers/translation_version_provider.dart
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'translation_version_provider.g.dart';

/// Simple integer version provider used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).state++;
@riverpod
class TranslationVersion extends _$TranslationVersion {
  @override
  int build() => 0;

  void increment() {
    state++;
  }
}
