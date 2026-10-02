// The connection to the Mac: WSS to the relay (certificate pinned), a Noise IK
// session inside it, and a small RPC + terminal stream protocol on top.
// Wire format: see cmd/uniai/session.go.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/widgets.dart';

import '../crypto/noise.dart';
import 'store.dart';

enum LinkState { connecting, online, offline, refused }

class RpcError implements Exception {
  final String code, message;
  const RpcError(this.code, this.message);
  @override
  String toString() => message;
}

const _chunkMax = 60000;
const _maxMsg = 16 << 20;

class Link extends ChangeNotifier with WidgetsBindingObserver {
  Link(this.pairing, this.key, {this.deviceName = 'Android phone'});

  MacPairing pairing;
  final KeyPair key;
  final String deviceName;

  LinkState state = LinkState.connecting;
  String? error;
  Map<String, dynamic> info = const {};
  int epoch = 0; // bumps on every successful (re)connect

  /// Terminal output by terminal id: (offset, bytes).
  final termOut = <int, void Function(int off, Uint8List data)>{};
  final _events = StreamController<(String, dynamic)>.broadcast();
  Stream<(String, dynamic)> get events => _events.stream;

  /// Called once the Mac has accepted a new pairing.
  void Function(MacPairing)? onPaired;

  WebSocket? _ws;
  CipherState? _send, _recv;
  final _acc = BytesBuilder(copy: false);
  final _pending = <int, Completer<dynamic>>{};
  int _nextId = 1, _gen = 0, _backoff = 1;
  Timer? _retry;
  bool _disposed = false;
  DateTime _pausedAt = DateTime.now();

  String get home => (info['home'] as String?) ?? '~';
  /// The Mac's name on screen: the user's nickname, else its hostname.
  String get host => pairing.nick ?? hostname;
  String get hostname => (info['host'] as String?) ?? pairing.host;

  /// Gives this Mac a nickname (null: back to its hostname).
  void rename(String? nick) {
    pairing = pairing.withNick(nick);
    notifyListeners();
  }
  bool get online => state == LinkState.online;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _pausedAt = DateTime.now();
    if (state != AppLifecycleState.resumed) return;
    if (online) {
      // After a long background the socket may be half dead: probe it.
      if (DateTime.now().difference(_pausedAt).inSeconds > 10) _probe();
    } else {
      reconnectNow();
    }
  }

  Future<void> _probe() async {
    final ws = _ws;
    try {
      await call('sys.status', null, const Duration(seconds: 4));
    } catch (_) {
      if (_ws == ws && ws != null) _lost(ws, 'connection went stale');
    }
  }

  void reconnectNow() {
    if (_disposed || state == LinkState.online) return;
    _retry?.cancel();
    _backoff = 1;
    _connect();
  }

  void _set(LinkState s, [String? err]) {
    if (s != state) debugPrint('uniai: link ${s.name}${err == null ? '' : ': $err'}');
    state = s;
    error = err;
    if (!_disposed) notifyListeners();
  }

  HttpClient _client() {
    final pin = pairing.pin;
    return HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, _, _) =>
          c.sha256.convert(cert.der).toString() == pin;
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = ++_gen;
    _set(LinkState.connecting, error);
    WebSocket ws;
    try {
      ws = await WebSocket.connect(
        'wss://${pairing.relay}/v1/phone?room=${pairing.room}',
        customClient: _client(),
      ).timeout(const Duration(seconds: 15));
    } on HandshakeException {
      return _fail(gen, 'The relay\'s certificate does not match the pin. '
          'Someone may be intercepting the connection.');
    } catch (e) {
      return _fail(gen, _netErr(e));
    }
    if (_disposed || gen != _gen) {
      ws.close();
      return;
    }
    ws.pingInterval = const Duration(seconds: 15);

    final noise = NoiseIK(s: key, remoteStatic: unhex(pairing.macPub));
    final hello = {
      'v': 1,
      'name': deviceName,
      if (pairing.token != null) 'pair': pairing.token,
    };
    var shaken = false;
    final handshakeTimer = Timer(const Duration(seconds: 15), () {
      if (!shaken) {
        ws.close(4000);
        _fail(gen, 'Your Mac did not answer.');
      }
    });
    ws.listen(
      (m) {
        if (m is! List<int>) return;
        if (shaken) return _frame(ws, m);
        shaken = true;
        handshakeTimer.cancel();
        try {
          final reply = jsonDecode(utf8.decode(noise.readMessage2(m)))
              as Map<String, dynamic>;
          if (reply['err'] != null) {
            ws.close();
            _gen++; // ignore the close
            _set(LinkState.refused, reply['err'] as String);
            return;
          }
          _onOnline(ws, noise, reply);
        } catch (e) {
          ws.close();
          _fail(gen, 'Handshake failed: this is not your Mac, or its key changed.');
        }
      },
      onDone: () {
        handshakeTimer.cancel();
        if (!shaken) {
          _fail(gen, _closeReason(ws.closeCode));
        } else {
          _lost(ws, _closeReason(ws.closeCode));
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    ws.add(noise.writeMessage1(utf8.encode(jsonEncode(hello))));
  }

  void _onOnline(WebSocket ws, NoiseIK n, Map<String, dynamic> reply) {
    _ws = ws;
    _send = n.send;
    _recv = n.recv;
    _acc.clear();
    info = reply;
    _backoff = 1;
    epoch++;
    final host = reply['host'] as String?;
    if (pairing.token != null || (host != null && host != pairing.host)) {
      final wasPairing = pairing.token != null;
      pairing = pairing.paired(host: host);
      if (wasPairing && onPaired != null) {
        onPaired!(pairing); // saves it (keeping the Mac's nickname, if any)
      } else {
        Store.savePairing(pairing);
      }
    }
    _set(LinkState.online);
  }

  void _fail(int gen, String why) {
    if (_disposed || gen != _gen) return;
    _gen++;
    _set(LinkState.offline, why);
    _schedule();
  }

  void _lost(WebSocket ws, String why) {
    if (_ws != ws) return;
    _ws = null;
    _send = _recv = null;
    for (final p in _pending.values) {
      p.completeError(const RpcError('offline', 'Connection lost'));
    }
    _pending.clear();
    try {
      ws.close();
    } catch (_) {}
    if (_disposed) return;
    _set(LinkState.offline, why);
    _backoff = 1;
    _schedule();
  }

  void _schedule() {
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(1, 15);
  }

  static String _closeReason(int? code) => switch (code) {
        4404 => 'Your Mac is offline (asleep, or the agent is not running).',
        4408 => 'Your Mac did not pick up.',
        4429 => 'Too many connections — try again in a minute.',
        _ => 'Disconnected.',
      };

  static String _netErr(Object e) {
    if (e is TimeoutException) return 'The relay did not answer.';
    if (e is SocketException) return 'No connection to the relay.';
    if (e is WebSocketException) return 'The relay refused the connection.';
    return 'Connection failed: $e';
  }

  void _frame(WebSocket ws, List<int> ct) {
    final Uint8List pt;
    try {
      pt = _recv!.decrypt(ct);
    } catch (_) {
      return _lost(ws, 'A message failed authentication; reconnecting.');
    }
    if (pt.isEmpty) return;
    _acc.add(Uint8List.sublistView(pt, 1));
    if (_acc.length > _maxMsg) return _lost(ws, 'Message too large.');
    if (pt[0] == 1) return;
    _dispatch(_acc.takeBytes());
  }

  void _dispatch(Uint8List m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case 0x4f: // 'O'
        if (m.length < 13) return;
        final bd = ByteData.sublistView(m);
        termOut[bd.getUint32(1)]
            ?.call(bd.getUint64(5), Uint8List.sublistView(m, 13));
      case 0x4a: // 'J'
        final j = jsonDecode(utf8.decode(Uint8List.sublistView(m, 1)));
        if (j is! Map) return;
        if (j['id'] != null) {
          final p = _pending.remove(j['id']);
          if (p == null) return;
          if (j['e'] != null) {
            p.completeError(RpcError(j['code'] ?? 'error', j['e']));
          } else {
            p.complete(j['r']);
          }
        } else if (j['ev'] != null) {
          _events.add((j['ev'] as String, j['p']));
        }
    }
  }

  bool _sendApp(Uint8List m) {
    final ws = _ws, cs = _send;
    if (ws == null || cs == null) return false;
    var i = 0;
    do {
      final n = (m.length - i).clamp(0, _chunkMax);
      final more = i + n < m.length;
      final pt = Uint8List(n + 1)
        ..[0] = more ? 1 : 0
        ..setRange(1, n + 1, m, i);
      ws.add(cs.encrypt(pt));
      i += n;
    } while (i < m.length);
    return true;
  }

  Future<dynamic> call(String method,
      [Map<String, dynamic>? params,
      Duration timeout = const Duration(seconds: 45)]) {
    if (!online) {
      return Future.error(const RpcError('offline', 'Not connected to your Mac'));
    }
    final id = _nextId++;
    final done = Completer<dynamic>();
    _pending[id] = done;
    final body = utf8.encode(jsonEncode({'id': id, 'm': method, 'p': ?params}));
    _sendApp(Uint8List(body.length + 1)
      ..[0] = 0x4a
      ..setRange(1, body.length + 1, body));
    return done.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw const RpcError('timeout', 'Your Mac did not answer in time');
    });
  }

  bool sendInput(int id, List<int> bytes) {
    if (!online) return false;
    final m = Uint8List(5 + bytes.length)..[0] = 0x49;
    ByteData.sublistView(m).setUint32(1, id);
    m.setRange(5, m.length, bytes);
    return _sendApp(m);
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _ws?.close();
    _events.close();
    super.dispose();
  }
}
