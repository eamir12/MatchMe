// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'event_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(EventManager)
final eventManagerProvider = EventManagerProvider._();

final class EventManagerProvider
    extends $NotifierProvider<EventManager, AsyncValue<List<EventModel>>> {
  EventManagerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'eventManagerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$eventManagerHash();

  @$internal
  @override
  EventManager create() => EventManager();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AsyncValue<List<EventModel>> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AsyncValue<List<EventModel>>>(value),
    );
  }
}

String _$eventManagerHash() => r'60b4d94d5884ed5fd96dbde8e3f80b8b30fdf643';

abstract class _$EventManager extends $Notifier<AsyncValue<List<EventModel>>> {
  AsyncValue<List<EventModel>> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<AsyncValue<List<EventModel>>, AsyncValue<List<EventModel>>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<List<EventModel>>,
                AsyncValue<List<EventModel>>
              >,
              AsyncValue<List<EventModel>>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
