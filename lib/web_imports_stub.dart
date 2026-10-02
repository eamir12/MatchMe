// web_imports_stub.dart - Non-web implementation of the browser bridge.
//
// The entire contract lives in web_imports_contract.dart with inert defaults,
// so there is nothing to mirror here and nothing that can drift. This file
// only adds the two document-level singletons, which must be per-platform
// because the web ones hold a listener registry.
//
// If you need a new browser capability, add it to web_imports_contract.dart
// first, then override it in web_imports_web.dart. Do not declare it only in
// the web file: a consumer reaching it would compile for web and fail on
// mobile, and the analyzer cannot catch that across a conditional export.

export 'web_imports_contract.dart';

import 'web_imports_contract.dart';

final HtmlDocument document = HtmlDocument();
final Window window = Window();
