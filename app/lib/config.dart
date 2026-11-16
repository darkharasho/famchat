/// Server origin; the API lives under `$apiBase/api`. Override with `--dart-define=API_BASE=...`.
const String apiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://famchat.dev');
