// What the phone remembers: the paired Macs, each with its own phone-side
// Noise key. They live in the Android Keystore-backed secure storage, never in
// plain prefs.
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
  final String? phoneKey; // this phone's private key for this Mac (hex)
  final String? nick; // the user's name for this Mac; null: its hostname

  const MacPairing({
    required this.relay,
    required this.pin,
    required this.room,
    required this.macPub,
    required this.host,
    this.token,
    this.phoneKey,
    this.nick,
  });

  KeyPair get key => KeyPair(unhex(phoneKey!));

  /// What to call this Mac on screen.
  String get name => nick ?? host;

  MacPairing withKey(String key) => MacPairing(
      relay: relay, pin: pin, room: room, macPub: macPub, host: host, token: token, phoneKey: key, nick: nick);

  MacPairing withNick(String? nick) => MacPairing(
      relay: relay, pin: pin, room: room, macPub: macPub, host: host, token: token, phoneKey: phoneKey, nick: nick);

  /// Parses `mr1.<base64url json>` (from the QR, a paste, or the deep link).
  static MacPairing parse(String code) {
    var s = code.trim();
    final i = s.indexOf('mr1.');
    if (i < 0) throw const FormatException('not a bz-uniai pairing code');
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
      relay: relay, pin: pin, room: room, macPub: macPub, host: host ?? this.host, phoneKey: phoneKey, nick: nick);

  Map<String, dynamic> toJson() => {
        'relay': relay,
        'pin': pin,
        'room': room,
        'macPub': macPub,
        'host': host,
        if (token != null) 'token': token,
        if (phoneKey != null) 'phoneKey': phoneKey,
        if (nick != null) 'nick': nick,
      };

  factory MacPairing.fromJson(Map<String, dynamic> m) => MacPairing(
        relay: m['relay'],
        pin: m['pin'],
        room: m['room'],
        macPub: m['macPub'],
        host: m['host'] ?? 'Mac',
        token: m['token'],
        phoneKey: m['phoneKey'],
        nick: m['nick'],
      );
}

class Store {
  static const _s = FlutterSecureStorage(
      aOptions: AndroidOptions(),
      iOptions: IOSOptions(),
      // The login keychain: the data-protection one needs a team-signed app
      // with a keychain group, and the Mac app is signed to run locally.
      mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  /// A fresh phone key for a new pairing (hex).
  static String newKey() => hexOf(KeyPair.generate().priv);

  /// Every paired Mac (completed pairings only), oldest first.
  static Future<List<MacPairing>> pairings() async {
    await _migrate();
    final s = await _s.read(key: 'pairings');
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((m) => MacPairing.fromJson((m as Map).cast<String, dynamic>()))
          .where((p) => p.phoneKey != null && p.token == null)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(List<MacPairing> l) =>
      _s.write(key: 'pairings', value: jsonEncode([for (final p in l) p.toJson()]));

  /// Adds or updates the pairing for [p]'s Mac (by room).
  static Future<void> savePairing(MacPairing p) async {
    if (p.phoneKey == null || p.token != null) return;
    final l = await pairings();
    final i = l.indexWhere((x) => x.room == p.room);
    if (i >= 0) {
      l[i] = p;
    } else {
      l.add(p);
    }
    await _write(l);
  }

  /// Forgets one Mac along with this phone's key for it.
  static Future<void> forget(MacPairing p) async {
    final l = await pairings();
    l.removeWhere((x) => x.room == p.room);
    await _write(l);
    if ((await active()) == p.room) await _s.delete(key: 'active');
  }

  static Future<String?> active() => _s.read(key: 'active');
  static Future<void> setActive(String room) => _s.write(key: 'active', value: room);

  // Version 1 kept one Mac and one global phone key.
  static Future<void> _migrate() async {
    final old = await _s.read(key: 'pairing');
    if (old == null) return;
    final key = await _s.read(key: 'phone_key');
    try {
      final p = MacPairing.fromJson(jsonDecode(old));
      if (key != null && key.length == 64) {
        await _write([p.withKey(key)]);
        await setActive(p.room);
      }
    } catch (_) {}
    await _s.delete(key: 'pairing');
    await _s.delete(key: 'phone_key');
  }
}
