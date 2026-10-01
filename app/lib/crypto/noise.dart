// Noise_IK_25519_ChaChaPoly_SHA256, initiator side only (the phone). The Mac
// agent runs flynn/noise; test/noise_test.dart checks this against vectors
// generated from it (cmd/noisevec).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

const _protocol = 'Noise_IK_25519_ChaChaPoly_SHA256';
const prologue = 'macremote/1';

const _x = DartX25519();
final _aead = DartChacha20.poly1305Aead();

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List dh(List<int> priv, List<int> pub) {
  final kp = SimpleKeyPairData(priv,
      publicKey: SimplePublicKey(const [], type: KeyPairType.x25519),
      type: KeyPairType.x25519);
  final s = _x.sharedSecretSync(
      keyPairData: kp,
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519));
  return Uint8List.fromList((s as SecretKeyData).bytes);
}

final _base = Uint8List(32)..[0] = 9;
Uint8List publicKey(List<int> priv) => dh(priv, _base);

class KeyPair {
  final Uint8List priv, pub;
  KeyPair(this.priv) : pub = publicKey(priv);
  factory KeyPair.generate() => KeyPair(randomBytes(32));
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

Uint8List _sha(List<int> data) =>
    Uint8List.fromList(c.sha256.convert(data).bytes);

Uint8List _cat(List<int> a, List<int> b) =>
    Uint8List(a.length + b.length)
      ..setAll(0, a)
      ..setAll(a.length, b);

List<Uint8List> _hkdf2(List<int> ck, List<int> ikm) {
  final t = _hmac(ck, ikm);
  final o1 = _hmac(t, [1]);
  final o2 = _hmac(t, _cat(o1, [2]));
  return [o1, o2];
}

/// One direction of an established channel.
class CipherState {
  final SecretKeyData _k;
  int _n = 0;
  CipherState(List<int> key) : _k = SecretKeyData(key);

  static List<int> _nonce(int n) {
    final b = ByteData(12);
    b.setUint32(4, n & 0xffffffff, Endian.little);
    b.setUint32(8, n ~/ 0x100000000, Endian.little);
    return b.buffer.asUint8List();
  }

  Uint8List encrypt(List<int> pt, [List<int> ad = const []]) {
    final box =
        _aead.encryptSync(pt, secretKey: _k, nonce: _nonce(_n++), aad: ad);
    return _cat(box.cipherText, box.mac.bytes);
  }

  Uint8List decrypt(List<int> ct, [List<int> ad = const []]) {
    if (ct.length < 16) throw const NoiseError('short message');
    final box = SecretBox(ct.sublist(0, ct.length - 16),
        nonce: _nonce(_n), mac: Mac(ct.sublist(ct.length - 16)));
    try {
      final pt = _aead.decryptSync(box, secretKey: _k, aad: ad);
      _n++;
      return Uint8List.fromList(pt);
    } on SecretBoxAuthenticationError {
      throw const NoiseError('authentication failed');
    }
  }
}

class NoiseError implements Exception {
  final String message;
  const NoiseError(this.message);
  @override
  String toString() => message;
}

/// The IK handshake from the initiator: write message 1, read message 2,
/// then [send]/[recv] carry the session.
class NoiseIK {
  final KeyPair s, e;
  final Uint8List rs;
  late Uint8List _h, _ck;
  CipherState? _cs;
  late CipherState send, recv;

  NoiseIK({required this.s, required List<int> remoteStatic, KeyPair? ephemeral})
      : rs = Uint8List.fromList(remoteStatic),
        e = ephemeral ?? KeyPair.generate() {
    _h = Uint8List.fromList(utf8.encode(_protocol)); // exactly 32 bytes
    _ck = _h;
    _mixHash(utf8.encode(prologue));
    _mixHash(rs);
  }

  void _mixHash(List<int> d) => _h = _sha(_cat(_h, d));

  void _mixKey(List<int> ikm) {
    final o = _hkdf2(_ck, ikm);
    _ck = o[0];
    _cs = CipherState(o[1]);
  }

  Uint8List _encryptAndHash(List<int> pt) {
    final out = _cs == null ? Uint8List.fromList(pt) : _cs!.encrypt(pt, _h);
    _mixHash(out);
    return out;
  }

  Uint8List _decryptAndHash(List<int> ct) {
    final out = _cs == null ? Uint8List.fromList(ct) : _cs!.decrypt(ct, _h);
    _mixHash(ct);
    return out;
  }

  /// -> e, es, s, ss
  Uint8List writeMessage1(List<int> payload) {
    final b = BytesBuilder(copy: false);
    _mixHash(e.pub);
    b.add(e.pub);
    _mixKey(dh(e.priv, rs));
    b.add(_encryptAndHash(s.pub));
    _mixKey(dh(s.priv, rs));
    b.add(_encryptAndHash(payload));
    return b.takeBytes();
  }

  /// <- e, ee, se
  Uint8List readMessage2(List<int> msg) {
    if (msg.length < 32 + 16) throw const NoiseError('short handshake reply');
    final re = msg.sublist(0, 32);
    _mixHash(re);
    _mixKey(dh(e.priv, re));
    _mixKey(dh(s.priv, re));
    final payload = _decryptAndHash(msg.sublist(32));
    final o = _hkdf2(_ck, const []);
    send = CipherState(o[0]);
    recv = CipherState(o[1]);
    return payload;
  }
}

String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList(List.generate(
    s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
