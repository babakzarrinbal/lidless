import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/crypto/noise.dart';

void main() {
  final v = (jsonDecode(File('test/noise_vectors.json').readAsStringSync())
          as Map)
      .cast<String, String>();

  test('public keys match Go', () {
    expect(hexOf(publicKey(unhex(v['is_priv']!))), v['is_pub']);
    expect(hexOf(publicKey(unhex(v['rs_priv']!))), v['rs_pub']);
  });

  test('IK handshake and transport match flynn/noise', () {
    final n = NoiseIK(
      s: KeyPair(unhex(v['is_priv']!)),
      ephemeral: KeyPair(unhex(v['ie_priv']!)),
      remoteStatic: unhex(v['rs_pub']!),
    );
    expect(hexOf(n.writeMessage1(utf8.encode(v['p1']!))), v['m1']);
    expect(utf8.decode(n.readMessage2(unhex(v['m2']!))), v['p2']);
    expect(hexOf(n.send.encrypt(utf8.encode('phone to mac 1'))), v['t1']);
    expect(hexOf(n.send.encrypt(utf8.encode('phone to mac 2'))), v['t2']);
    expect(utf8.decode(n.recv.decrypt(unhex(v['t3']!))), 'mac to phone 1');
  });

  test('tampered reply is rejected', () {
    final n = NoiseIK(
      s: KeyPair(unhex(v['is_priv']!)),
      ephemeral: KeyPair(unhex(v['ie_priv']!)),
      remoteStatic: unhex(v['rs_pub']!),
    );
    n.writeMessage1(utf8.encode(v['p1']!));
    final m2 = unhex(v['m2']!)..[40] ^= 1;
    expect(() => n.readMessage2(m2), throwsA(isA<NoiseError>()));
  });
}
