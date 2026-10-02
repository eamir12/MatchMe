// web_imports.dart - Conditional export for web-specific functionality

export 'web_imports_stub.dart' if (dart.library.html) 'web_imports_web.dart';
