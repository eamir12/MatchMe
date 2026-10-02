// services/keyboard_service.dart - Conditional export for keyboard service

export 'keyboard_service_stub.dart'
    if (dart.library.html) 'keyboard_service_web.dart';
