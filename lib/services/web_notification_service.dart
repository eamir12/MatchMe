// lib/services/web_notification_service.dart

// Conditional export based on platform
export 'web_notification_service_stub.dart'
    if (dart.library.html) 'web_notification_service_web.dart';

// iOS notification service
export 'mobile_local_notification_service.dart';
