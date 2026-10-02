String? _runtimeSupabaseUrl;
String? _runtimeSupabaseAnonKey;

void setRuntimeSupabaseConfig({String? url, String? anonKey}) {
  _runtimeSupabaseUrl = url?.trim();
  _runtimeSupabaseAnonKey = anonKey?.trim();
}

String? get runtimeSupabaseUrl => _runtimeSupabaseUrl;

String? get runtimeSupabaseAnonKey => _runtimeSupabaseAnonKey;
