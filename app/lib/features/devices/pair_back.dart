// Pairing back between desktops: when this Mac's app pairs with another Mac
// it sends its own core's pairing code along (Link.back). That Mac's core
// keeps the code (cmd/uniai/offers.go) and its app, watching here, pairs back,
// so each Mac lists the other. Phones have no core: they pair one way.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:uniai/features/devices/devices_model.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/net/store.dart';

class PairBack {
  PairBack(this.local, {required this.name, required this.onPaired, this.connect = _connect, this.known = _known});

  /// This Mac's own core.
  final Link local;

  /// The name this device goes by on other Macs.
  final String Function() name;

  /// A Mac that accepted the pairing back; already saved.
  final void Function(MacPairing) onPaired;

  /// A link for a new pairing, not started yet (tests swap it).
  final Link Function(MacPairing, String name) connect;

  /// The rooms already paired (tests swap it).
  final Future<Set<String>> Function() known;

  static Link _connect(MacPairing p, String name) => Link(p, p.key, deviceName: name);
  static Future<Set<String>> _known() async => {for (final m in await Store.pairings()) m.room};

  StreamSubscription? _sub;
  int _epoch = -1;
  bool _busy = false;

  void start() {
    _sub = local.events.where((e) => e.$1 == 'devices').listen((_) => check());
    local.addListener(_onState);
    _onState();
  }

  void _onState() {
    if (local.online && local.epoch != _epoch) {
      _epoch = local.epoch;
      check();
    }
  }

  /// This Mac's own pairing code, for the Mac it is pairing with; null when
  /// the core is not reachable.
  Future<String?> code() async {
    if (!local.online) return null;
    try {
      return (await Devices(local).pair()).code;
    } catch (e) {
      debugPrint('pair: no code to pair back with: $e');
      return null;
    }
  }

  /// Takes the codes other Macs left with this Mac's core and pairs with
  /// each Mac not paired yet.
  Future<void> check() async {
    if (_busy || !local.online) return;
    _busy = true;
    try {
      final codes = await local.call('devices.offers');
      final rooms = await known();
      for (final c in (codes as List? ?? const []).cast<String>()) {
        final MacPairing p;
        try {
          p = MacPairing.parse(c);
        } catch (_) {
          continue;
        }
        if (rooms.add(p.room)) await _pair(p);
      }
    } on RpcError catch (e) {
      if (e.code != 'unknown') debugPrint('pair: can\'t read codes to pair back: $e'); // unknown: an older core
    } catch (e) {
      debugPrint('pair: can\'t read codes to pair back: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _pair(MacPairing p) {
    final done = Completer<void>();
    final link = connect(p.withKey(Store.newKey()), name());
    late final Timer timer;
    void finish() {
      if (done.isCompleted) return;
      timer.cancel();
      // Let the handshake callback return before the link goes.
      scheduleMicrotask(link.dispose);
      done.complete();
    }

    link.onPaired = (paired) {
      Store.savePairing(paired);
      debugPrint('pair: paired back with ${paired.host}');
      onPaired(paired);
      finish();
    };
    link.addListener(() {
      if (link.state != LinkState.refused) return;
      debugPrint('pair: ${p.host} refused to pair back: ${link.error}'); // the code expired: pair by hand
      finish();
    });
    timer = Timer(const Duration(seconds: 30), finish);
    link.start();
    return done.future;
  }

  void dispose() {
    _sub?.cancel();
    local.removeListener(_onState);
  }
}
