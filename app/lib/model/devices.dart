// The devices paired with this Mac's core: list, rename, remove, and a new
// pairing code. Only the local link may ask (cmd/uniai/devices.go); the
// core says {"ev":"devices"} whenever the list or who is online changes.
import '../net/link.dart';

class PairedDevice {
  PairedDevice.from(Map m)
      : name = m['name'] as String? ?? '',
        pub = m['pub'] as String? ?? '',
        added = DateTime.tryParse(m['added'] as String? ?? ''),
        online = m['online'] == true;
  final String name, pub;
  final DateTime? added;
  final bool online;
}

class PairCode {
  PairCode.from(Map m)
      : code = m['code'] as String,
        host = m['host'] as String? ?? '',
        expires = DateTime.tryParse(m['expires'] as String? ?? '') ??
            DateTime.now().add(const Duration(minutes: 10));
  final String code, host;
  final DateTime expires;
}

class Devices {
  Devices(this.link);
  final Link link;

  /// The core's `devices` event: refresh the list.
  Stream<void> get changes => link.events.where((e) => e.$1 == 'devices').map((_) {});

  static List<PairedDevice> _list(dynamic r) =>
      [for (final m in (r as List? ?? const []).cast<Map>()) PairedDevice.from(m)];

  Future<List<PairedDevice>> list() async => _list(await link.call('devices.list'));
  Future<List<PairedDevice>> rename(String pub, String name) async =>
      _list(await link.call('devices.rename', {'pub': pub, 'name': name}));
  Future<List<PairedDevice>> remove(String pub) async => _list(await link.call('devices.remove', {'pub': pub}));
  Future<PairCode> pair() async => PairCode.from(await link.call('devices.pair') as Map);
}
