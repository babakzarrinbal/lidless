import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniai/features/devices/pair_back.dart';
import 'package:uniai/net/store.dart';

import '../../support/fakes.dart';

String code(String room) => 'mr1.${base64Url.encode(utf8.encode(jsonEncode({
      'r': 'relay.test:8460',
      'p': 'a' * 64,
      'm': room,
      'k': 'b' * 64,
      't': 'token',
      'n': 'other-mac',
    }))).replaceAll('=', '')}';

/// The other Mac: accepts the pairing as soon as it starts.
class AcceptingMac extends FakeLink {
  AcceptingMac(MacPairing p) : super(const {}) {
    pairing = p;
  }
  @override
  void start() => onPaired?.call(pairing.paired());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('pairs back with each Mac that left a code, once, skipping known ones', () async {
    final local = FakeLink({
      'devices.offers': [code('1' * 64), code('2' * 64), code('1' * 64), 'junk'],
    });
    final dialed = <String>[];
    final paired = <String>[];
    final back = PairBack(
      local,
      name: () => 'this-mac',
      onPaired: (p) => paired.add(p.room),
      known: () async => {'2' * 64},
      connect: (p, name) {
        expect(name, 'this-mac');
        expect(p.token, 'token');
        dialed.add(p.room);
        return AcceptingMac(p);
      },
    );
    await back.check();
    expect(dialed, ['1' * 64]);
    expect(paired, ['1' * 64]);
    expect(local.calls, ['devices.offers']);
  });

  test('an older core without devices.offers is left alone', () async {
    final local = FakeLink(const {});
    final back = PairBack(local, name: () => 'm', onPaired: (_) => fail('no pairing'), connect: (_, _) => fail('no dial'));
    await back.check();
    expect(local.calls, ['devices.offers']);
  });

  test('the code sent along is this Mac\'s own pairing code', () async {
    final local = FakeLink({
      'devices.pair': {'code': 'mr1.mine', 'host': 'this-mac', 'expires': '2026-10-02T10:00:00Z'},
    });
    expect(await PairBack(local, name: () => 'm', onPaired: (_) {}).code(), 'mr1.mine');
    expect(await PairBack(FakeLink(const {}), name: () => 'm', onPaired: (_) {}).code(), isNull);
  });
}
