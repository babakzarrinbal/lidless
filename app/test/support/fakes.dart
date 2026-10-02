// Shared test fakes.
import 'dart:async';

import 'package:uniai/crypto/noise.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/net/store.dart';

/// A Mac that answers from a table, already connected.
class FakeLink extends Link {
  FakeLink(this.answers)
      : super(const MacPairing(relay: 'r:1', pin: '', room: '0123456789abcdef0123', macPub: '', host: 'Mac'),
            KeyPair.generate()) {
    state = LinkState.online;
    epoch = 1;
    info = {'host': 'Mac', 'home': '/Users/me', 'roots': ['/Users/me']};
  }
  final Map<String, dynamic> answers;
  final calls = <String>[];
  final sent = <(String, Map?)>[];
  final macEvents = StreamController<(String, dynamic)>.broadcast();

  @override
  Stream<(String, dynamic)> get events => macEvents.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params, Duration timeout = const Duration(seconds: 45)]) async {
    calls.add(method);
    sent.add((method, params));
    if (answers.containsKey(method)) return answers[method];
    throw RpcError('unknown', 'unknown method $method');
  }
}
