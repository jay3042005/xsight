/// Build-time configuration for XSIGHT.
///
/// Pass values via `--dart-define`:
///   flutter run --dart-define=ZEN_API_KEY=sk-... \
///               --dart-define=ZEN_MODEL=deepseek-v4-flash-free
class XSConfig {
  XSConfig._();

  /// OpenCode Zen API key. Empty means "use mock replies".
  static const String zenApiKey =
      String.fromEnvironment('ZEN_API_KEY', defaultValue: '');

  /// Default model id. Free options:
  ///  - big-pickle
  ///  - deepseek-v4-flash-free
  ///  - nemotron-3-super-free
  static const String zenModel = String.fromEnvironment(
    'ZEN_MODEL',
    defaultValue: 'deepseek-v4-flash-free',
  );

  /// Base URL for OpenAI-compatible chat completions.
  static const String zenBaseUrl = String.fromEnvironment(
    'ZEN_BASE_URL',
    defaultValue: 'https://opencode.ai/zen/v1',
  );

  /// Optional override to call your own backend instead of Zen directly.
  /// If set, the app will POST to `$backendBaseUrl/chat`.
  static const String backendBaseUrl =
      String.fromEnvironment('BACKEND_BASE_URL', defaultValue: '');

  /// True when AI is configured (live or proxied through backend).
  static bool get hasAi =>
      zenApiKey.isNotEmpty || backendBaseUrl.isNotEmpty;

  /// System prompt for the XSIGHT clinical chatbot.
  static const String systemPrompt = '''
You are the XSIGHT clinical support assistant.

Role:
- Help users describe respiratory symptoms in simple language.
- Ask short, focused triage-style follow-up questions.
- Explain vital signs and lung sound results in plain terms.

Rules:
- You are NOT a doctor and you NEVER provide a diagnosis.
- Always recommend consulting a licensed clinician for any concern.
- Keep replies short (under 80 words), calm, and professional.
- If the user describes severe symptoms (chest pain, severe breathlessness,
  blue lips, confusion, fainting), tell them to seek emergency care immediately.
- Never claim certainty about a medical condition.
''';
}
