import 'dart:convert';
import 'dart:io';

import '../../state/xs_settings.dart';
import '../ai/xs_ai_card.dart';
import '../config/xs_config.dart';

class ZenMessage {
  final String role; // 'system' | 'user' | 'assistant'
  final String content;
  const ZenMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

class ZenChatException implements Exception {
  final String message;
  final int? status;
  ZenChatException(this.message, {this.status});
  @override
  String toString() => 'ZenChatException($status): $message';
}

/// Minimal OpenAI-compatible client for OpenCode Zen, with optional
/// support for proxying through your own FastAPI backend.
class ZenChatClient {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);

  Future<String> complete(
    List<ZenMessage> messages, {
    bool robotMode = false,
  }) async {
    final backend = XSSettings.I.backendUrl;
    if (backend.isNotEmpty) {
      return _completeViaBackend(messages, backend, robotMode: robotMode);
    }
    if (XSConfig.zenApiKey.isNotEmpty) {
      return _completeViaZen(messages);
    }
    throw ZenChatException(
      'No AI configured. Set the server IP in Settings, or pass ZEN_API_KEY.',
    );
  }

  /// Sends a single image (base64) to the backend `/vision` endpoint and
  /// returns a short description.
  Future<String> describeImage(String imageB64, {String? prompt}) async {
    final backend = XSSettings.I.backendUrl;
    if (backend.isEmpty) {
      throw ZenChatException(
        'Vision requires a server IP. Open Settings to set it.',
      );
    }
    final uri = Uri.parse('$backend/vision');
    final body = jsonEncode({
      'image_b64': imageB64,
      'prompt': ?prompt,
    });

    final req = await _http.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();

    if (res.statusCode >= 400) {
      throw ZenChatException(_extractError(text), status: res.statusCode);
    }
    final data = jsonDecode(text) as Map<String, dynamic>;
    final desc = data['description'] as String?;
    if (desc == null || desc.isEmpty) {
      throw ZenChatException('Empty vision response.');
    }
    return desc.trim();
  }

  /// Sends a single image to `/vision/objects` and returns a short list
  /// of object/person/scene tags suitable for live overlay chips.
  Future<List<String>> detectObjects(String imageB64) async {
    final backend = XSSettings.I.backendUrl;
    if (backend.isEmpty) {
      throw ZenChatException(
        'Vision requires a server IP. Open Settings to set it.',
      );
    }
    final uri = Uri.parse('$backend/vision/objects');
    final body = jsonEncode({'image_b64': imageB64});

    final req = await _http.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();

    if (res.statusCode >= 400) {
      throw ZenChatException(_extractError(text), status: res.statusCode);
    }
    final data = jsonDecode(text) as Map<String, dynamic>;
    final objs = data['objects'];
    if (objs is List) {
      return objs
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  Future<String> _completeViaZen(List<ZenMessage> messages) async {
    final uri = Uri.parse('${XSConfig.zenBaseUrl}/chat/completions');
    final body = jsonEncode({
      'model': XSConfig.zenModel,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': 0.4,
      'max_tokens': 400,
      'stream': false,
    });

    final req = await _http.postUrl(uri);
    req.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${XSConfig.zenApiKey}');
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();

    if (res.statusCode >= 400) {
      throw ZenChatException(_extractError(text), status: res.statusCode);
    }

    final data = jsonDecode(text) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw ZenChatException('Empty response from Zen.');
    }
    final msg = (choices.first as Map<String, dynamic>)['message']
        as Map<String, dynamic>?;
    final content = msg?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw ZenChatException('Missing content in Zen response.');
    }
    return content.trim();
  }

  Future<String> _completeViaBackend(
    List<ZenMessage> messages,
    String backend, {
    bool robotMode = false,
  }) async {
    final uri = Uri.parse('$backend/chat');
    final body = jsonEncode({
      'messages': messages.map((m) => m.toJson()).toList(),
      'robot_mode': robotMode,
    });

    final req = await _http.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();

    if (res.statusCode >= 400) {
      throw ZenChatException(_extractError(text), status: res.statusCode);
    }

    final data = jsonDecode(text) as Map<String, dynamic>;
    final reply = data['reply'] as String?;
    if (reply == null || reply.isEmpty) {
      throw ZenChatException('Missing reply in backend response.');
    }
    return reply.trim();
  }

  String _extractError(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final err = data['error'] ?? data['detail'];
        if (err is String) return err;
        if (err is Map<String, dynamic>) {
          return err['message']?.toString() ?? body;
        }
      }
    } catch (_) {}
    return body.isEmpty ? 'Unknown error' : body;
  }

  void dispose() {
    _http.close(force: true);
  }

  /// Streams chat tokens from the backend. Yields the assistant text in
  /// chunks (each chunk is whatever the upstream sent in one SSE event).
  /// The final yielded chunk is the cleaned full text from the backend's
  /// post-processing.
  ///
  /// [patientContext] carries the session's measured readings. It must go in
  /// this dedicated field rather than a `system` message: the backend strips
  /// client system messages to block prompt injection, and appends this after
  /// the trusted persona instead.
  Stream<ChatStreamEvent> stream(
    List<ZenMessage> messages, {
    bool robotMode = false,
    bool kioskMode = false,
    String? patientContext,
  }) async* {
    final backend = XSSettings.I.backendUrl;
    if (backend.isEmpty) {
      throw ZenChatException(
        'Streaming requires a backend URL. Open Settings to set the server IP.',
      );
    }
    final uri = Uri.parse('$backend/chat/stream');
    final body = jsonEncode({
      'messages': messages.map((m) => m.toJson()).toList(),
      'robot_mode': robotMode,
      'kiosk_mode': kioskMode,
      if (patientContext != null && patientContext.isNotEmpty)
        'patient_context': patientContext,
    });

    final req = await _http.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set('Accept', 'text/event-stream');
    req.add(utf8.encode(body));
    final res = await req.close();

    if (res.statusCode >= 400) {
      final text = await res.transform(utf8.decoder).join();
      req.abort();
      throw ZenChatException(_extractError(text), status: res.statusCode);
    }

    String buffer = '';
    await for (final chunk in res.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final idx = buffer.indexOf('\n\n');
        if (idx < 0) break;
        final raw = buffer.substring(0, idx).trim();
        buffer = buffer.substring(idx + 2);
        if (!raw.startsWith('data:')) continue;
        final payload = raw.substring(5).trim();
        if (payload == '[DONE]') return;
        Map<String, dynamic>? obj;
        try {
          obj = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          // Ignore malformed chunks.
          continue;
        }
        // Surface backend-reported errors instead of silently ending.
        if (obj['error'] != null) {
          throw ZenChatException(obj['error'].toString());
        }
        if (obj['delta'] is String) {
          yield ChatStreamEvent.delta(obj['delta'] as String);
        } else if (obj['final'] is String) {
          yield ChatStreamEvent.finalText(
            obj['final'] as String,
            cards: XSAiCard.parseList(obj['cards']),
          );
        }
      }
    }
  }
}

class ChatStreamEvent {
  final String? delta;
  final String? finalText;

  /// Visual-answer cards, delivered with the final event. Empty for deltas.
  final List<XSAiCard> cards;

  const ChatStreamEvent._({
    this.delta,
    this.finalText,
    this.cards = const [],
  });

  factory ChatStreamEvent.delta(String d) => ChatStreamEvent._(delta: d);

  factory ChatStreamEvent.finalText(
    String t, {
    List<XSAiCard> cards = const [],
  }) =>
      ChatStreamEvent._(finalText: t, cards: cards);

  bool get isFinal => finalText != null;
}
