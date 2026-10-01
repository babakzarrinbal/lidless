// What the phone remembers: its own Noise key and the paired Mac. Both live in
// the Android Keystore-backed secure storage, never in plain prefs.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/noise.dart';

class MacPairing {
  final String relay; // host:port
  final String pin; // sha256 of the relay certificate (hex)
  final String room;
  final String macPub; // hex
  final String host;
  final String? token; // one-time pairing token, dropped after first success

  const MacPairing({
    required this.relay,
    required this.pin,
    required this.room,
    required this.macPub,
    required this.host,
    this.token,
  });

  /// Parses `mr1.<base64url json>` (from the QR, a paste, or the deep link).
  static MacPairing parse(String code) {
    var s = code.trim();
    final i = s.indexOf('mr1.');
    if (i < 0) throw const FormatException('not a Mac Remote pairing code');
    s = s.substring(i + 4).split(RegExp(r'[\s/?#]')).first;
    final m = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(s))))
        as Map<String, dynamic>;
    final p = MacPairing(
      relay: m['r'] as String,
      pin: m['p'] as String,
      room: m['m'] as String,
      macPub: m['k'] as String,
      host: (m['n'] as String?) ?? 'Mac',
      token: m['t'] as String?,
    );
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(p.pin) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.macPub) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.room) ||
        !RegExp(r'^[A-Za-z0-9.\-]+:\d+$').hasMatch(p.relay)) {
      throw const FormatException('pairing code is damaged');
    }
    return p;
  }

  MacPairing paired({String? host}) => MacPairing(
      relay: relay, pin: pin, room: room, macPub: macPub, host: host ?? this.host);

  Map<String, dynamic> toJson() => {
        'relay': relay,
        'pin': pin,
        'room': room,
        'macPub': macPub,
        'host': host,
        if (token != null) 'token': token,
      };

  factory MacPairing.fromJson(Map<String, dynamic> m) => MacPairing(
        relay: m['relay'],
        pin: m['pin'],
        room: m['room'],
        macPub: m['macPub'],
        host: m['host'] ?? 'Mac',
        token: m['token'],
      );
}

class Store {
  static const _s = FlutterSecureStorage(
      aOptions: AndroidOptions(), iOptions: IOSOptions());

  static Future<KeyPair> phoneKey() async {
    final hex = await _s.read(key: 'phone_key');
    if (hex != null && hex.length == 64) return KeyPair(unhex(hex));
    final k = KeyPair.generate();
    await _s.write(key: 'phone_key', value: hexOf(k.priv));
    return k;
  }

  static Future<MacPairing?> pairing() async {
    final s = await _s.read(key: 'pairing');
    if (s == null) return null;
    try {
      return MacPairing.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }

  static Future<void> savePairing(MacPairing p) =>
      _s.write(key: 'pairing', value: jsonEncode(p.toJson()));

  /// Forgets the Mac and rotates the phone key, so the old identity is useless.
  static Future<void> forget() async {
    await _s.delete(key: 'pairing');
    await _s.delete(key: 'phone_key');
  }
}
