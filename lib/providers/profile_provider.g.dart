// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'profile_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------

@ProviderFor(ProfileEditNotifier)
final profileEditProvider = ProfileEditNotifierFamily._();

/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------
final class ProfileEditNotifierProvider
    extends $NotifierProvider<ProfileEditNotifier, AsyncValue<UserProfile?>> {
  /// ---------------------------------------------------------------------------
  /// profileEditProvider + ProfileEditNotifier
  /// ---------------------------------------------------------------------------
  ProfileEditNotifierProvider._({
    required ProfileEditNotifierFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'profileEditProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$profileEditNotifierHash();

  @override
  String toString() {
    return r'profileEditProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  ProfileEditNotifier create() => ProfileEditNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AsyncValue<UserProfile?> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AsyncValue<UserProfile?>>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProfileEditNotifierProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$profileEditNotifierHash() =>
    r'b9dc35a0b250cb047ea27def34e8a0a0cb1dd05e';

/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------

final class ProfileEditNotifierFamily extends $Family
    with
        $ClassFamilyOverride<
          ProfileEditNotifier,
          AsyncValue<UserProfile?>,
          AsyncValue<UserProfile?>,
          AsyncValue<UserProfile?>,
          String
        > {
  ProfileEditNotifierFamily._()
    : super(
        retry: null,
        name: r'profileEditProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// ---------------------------------------------------------------------------
  /// profileEditProvider + ProfileEditNotifier
  /// ---------------------------------------------------------------------------

  ProfileEditNotifierProvider call(String userId) =>
      ProfileEditNotifierProvider._(argument: userId, from: this);

  @override
  String toString() => r'profileEditProvider';
}

/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------

abstract class _$ProfileEditNotifier
    extends $Notifier<AsyncValue<UserProfile?>> {
  late final _$args = ref.$arg as String;
  String get userId => _$args;

  AsyncValue<UserProfile?> build(String userId);
  @$mustCallSuper
  @override
  void runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<UserProfile?>, AsyncValue<UserProfile?>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<UserProfile?>, AsyncValue<UserProfile?>>,
              AsyncValue<UserProfile?>,
              Object?,
              Object?
            >;
    element.handleCreate(ref, () => build(_$args));
  }
}
