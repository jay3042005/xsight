import 'package:flutter/foundation.dart';

import '../core/api/zen_chat_client.dart';
import '../core/config/xs_config.dart';
import 'xs_settings.dart';

class ChatMessage {
  final String role;
  final String content;
  final DateTime ts;
  ChatMessage({required this.role, required this.content, DateTime? ts})
      : ts = ts ?? DateTime.now();

  bool get isUser => role == 'user';
}

/// Holds chat history and talks to Zen (or a mock if no key configured).
class ChatController extends ChangeNotifier {
  final ZenChatClient _client = ZenChatClient();

  final List<ChatMessage> _messages = [
    ChatMessage(
      role: 'assistant',
      content:
          'Hello, I am the XSIGHT assistant. How can I help you today? '
          'You can describe symptoms or ask about your readings.',
    ),
  ];

  bool _busy = false;
  String? _error;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get busy => _busy;
  String? get error => _error;
  bool get aiConfigured =>
      XSConfig.hasAi || XSSettings.I.hasBackend;

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy) return;

    _messages.add(ChatMessage(role: 'user', content: trimmed));
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final reply = aiConfigured
          ? await _callAi()
          : await _mockReply(trimmed);
      _messages.add(ChatMessage(role: 'assistant', content: reply));
    } on ZenChatException catch (e) {
      _error = _friendlyError(e);
      _messages.add(ChatMessage(
        role: 'assistant',
        content:
            'Sorry, I could not reach the AI service right now. Please try again.',
      ));
    } catch (e) {
      _error = 'Unexpected error: $e';
      _messages.add(ChatMessage(
        role: 'assistant',
        content: 'Something went wrong. Please retry in a moment.',
      ));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<String> _callAi() async {
    final history = <ZenMessage>[
      const ZenMessage(role: 'system', content: XSConfig.systemPrompt),
      for (final m in _messages.where((m) => m.role != 'system'))
        ZenMessage(role: m.role, content: m.content),
    ];
    return _client.complete(history);
  }

  /// Local rule-based fallback so the demo works without a key.
  Future<String> _mockReply(String userText) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final t = userText.toLowerCase();
    if (t.contains('chest pain') ||
        t.contains('cant breathe') ||
        t.contains("can't breathe")) {
      return 'That sounds serious. Please seek emergency care immediately. '
          'I am an AI-assisted screening tool and cannot provide a diagnosis.';
    }
    if (t.contains('cough')) {
      return 'Got it. How long have you had the cough, and is it dry or '
          'producing phlegm? Any fever or chest tightness?';
    }
    if (t.contains('fever')) {
      return 'Thanks. What is your temperature, and how long has the fever '
          'lasted? Any cough or breathing difficulty?';
    }
    return 'Noted. Could you share more detail — when symptoms started, how '
        'severe they feel, and any breathing changes?';
  }

  String _friendlyError(ZenChatException e) {
    switch (e.status) {
      case 401:
        return 'AI not configured (invalid key).';
      case 429:
        return 'Too many requests. Try again shortly.';
      case 500:
      case 502:
      case 503:
        return 'AI service is temporarily unavailable.';
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }
}
