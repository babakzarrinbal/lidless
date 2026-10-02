// Android notifications, through MainActivity (no plugin): a session that
// needs the user, and while agents work with the app away, a quiet
// foreground service that keeps the link (and so those notifications) alive.
import 'dart:async';

import 'package:flutter/services.dart';

class Notify {
  static const _ch = MethodChannel('babzi/notify');
  static final _taps = StreamController<String>.broadcast();
  static bool _init = false;

  /// Payloads of tapped notifications ("room|session").
  static Stream<String> get taps {
    if (!_init) {
      _init = true;
      _ch.setMethodCallHandler((c) async {
        if (c.method == 'open' && c.arguments is String) _taps.add(c.arguments as String);
      });
      // The notification that started the app, if one did.
      _call('initial').then((p) {
        if (p is String && p.isNotEmpty) _taps.add(p);
      });
    }
    return _taps.stream;
  }

  /// Asks for the notification permission (Android 13+), once.
  static Future<void> ask() => _call('ask');

  static Future<void> show(int id, String title, String text, String payload) =>
      _call('show', {'id': id, 'title': title, 'text': text, 'payload': payload});

  static Future<void> cancel(int id) => _call('cancel', {'id': id});

  /// What the foreground service says while the app is away; null: none needed.
  static Future<void> watch(String? text) => _call('watch', {'text': text});

  static Future<dynamic> _call(String m, [Map<String, dynamic>? a]) async {
    try {
      return await _ch.invokeMethod(m, a);
    } catch (_) {
      return null; // tests, or an old platform: no notifications
    }
  }
}
