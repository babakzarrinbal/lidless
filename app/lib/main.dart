// App entry: loads the pairings, builds the Uniai root (lock, link to the Mac on screen) and routes between pairing and Home.
import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/alerts/alerts.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/net/store.dart';
import 'package:uniai/app/home.dart';
import 'package:uniai/features/devices/pair.dart';
import 'package:uniai/app/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: C.bg,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const Uniai());
}

class Uniai extends StatefulWidget {
  const Uniai({super.key});
  @override
  State<Uniai> createState() => _UniaiState();
}

class _UniaiState extends State<Uniai> with WidgetsBindingObserver {
  final _nav = GlobalKey<NavigatorState>();
  final _auth = LocalAuthentication();
  bool _ready = false, _locked = true, _authing = false, _canLock = true;
  DateTime? _pausedAt;
  List<MacPairing> _macs = [];
  Link? _link; // the Mac on screen, connected (or reconnecting)
  Link? _attempt; // a pairing in progress
  bool _adding = false; // pairing another Mac
  Terms? _terms;
  Alerts? _alerts;
  String _name = Platform.isAndroid ? 'Android phone' : Platform.localHostname.split('.').first;
  StreamSubscription? _links;

  static const _relockAfter = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString('deviceName') ?? _name;
    // A desktop is first of all its own Mac; pairings add the others.
    _macs = [if (MacPairing.hasLocal) MacPairing.local(), ...await Store.pairings()];
    final active = await Store.active();
    final p = _macs.where((m) => m.room == active).firstOrNull ?? _macs.firstOrNull;
    try {
      _canLock = await _auth.isDeviceSupported();
    } catch (_) {
      _canLock = false;
    }
    if (!_canLock) _locked = false;
    if (p != null) _use(p);
    setState(() => _ready = true);
    _unlock();

    final al = AppLinks();
    _links = al.uriLinkStream.listen((u) => _onCode(u.toString()));
  }

  void _use(MacPairing p) {
    final link = Link(p, p.isLocal ? null : p.key, deviceName: _name);
    _link = link;
    final terms = _terms = Terms(link);
    _alerts = Alerts(link, terms);
    link.start();
    Store.setActive(p.room);
  }

  void _drop() {
    _alerts?.dispose();
    _alerts = null;
    _terms?.dispose();
    _link?.dispose();
    _terms = null;
    _link = null;
  }

  /// Shows another paired Mac. Its terminals keep running on the Mac we leave.
  void _switch(MacPairing p) {
    if (_link?.pairing.room == p.room) return;
    _drop();
    _use(p);
    setState(() {});
  }

  // ---- lock ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (_canLock && !_authing && away > _relockAfter) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (!_locked || _authing) return;
    _authing = true;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock bz-uniai',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (ok && mounted) setState(() => _locked = false);
    } on LocalAuthException catch (e) {
      // No screen lock set up at all: let the user in rather than lock them out.
      if (e.code == LocalAuthExceptionCode.noCredentialsSet && mounted) {
        setState(() => _locked = false);
      }
    } catch (_) {
    } finally {
      _authing = false;
      _pausedAt = null;
    }
  }

  void _lockNow() {
    if (!_canLock) return;
    setState(() => _locked = true);
    _unlock();
  }

  // ---- pairing ----

  Future<void> _onCode(String code) async {
    final MacPairing p;
    try {
      p = MacPairing.parse(code);
    } catch (e) {
      final ctx = _nav.currentContext;
      if (ctx != null) toast(ctx, 'Not a valid pairing code', error: true);
      return;
    }
    // Wait for the lock screen to go away before asking.
    while (_locked && mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final ctx = _nav.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final name = await confirmPairing(ctx, p, _name, replacing: _macs.any((m) => m.room == p.room));
    if (name == null) return;
    _name = name;
    (await SharedPreferences.getInstance()).setString('deviceName', name);
    _attempt?.dispose();
    final withKey = p.withKey(Store.newKey()); // every Mac gets its own phone key
    final a = Link(withKey, withKey.key, deviceName: name);
    a.onPaired = (paired) {
      // Pairing a Mac again keeps the name the user gave it.
      final nick = _macs.where((m) => m.room == paired.room).firstOrNull?.nick;
      if (nick != null) paired = paired.withNick(nick);
      Store.savePairing(paired);
      if (_attempt != a) return;
      // Let the handshake callback finish before tearing this link down.
      scheduleMicrotask(() {
        a.dispose();
        _attempt = null;
        _adding = false;
        _macs = [..._macs.where((m) => m.room != paired.room), paired];
        _drop();
        _use(paired);
        if (mounted) setState(() {});
        HapticFeedback.mediumImpact();
      });
    };
    setState(() => _attempt = a);
    a.start();
  }

  void _cancelAttempt() {
    _attempt?.dispose();
    setState(() => _attempt = null);
  }

  /// Forgets the Mac on screen (and this phone's key for it), then shows
  /// the next paired Mac, if any.
  Future<void> _unpair() async {
    final p = _link?.pairing;
    if (p != null && p.isLocal) return;
    _drop();
    if (p != null) {
      await Store.forget(p);
      _macs = _macs.where((m) => m.room != p.room).toList();
    }
    if (_macs.isNotEmpty) _use(_macs.first);
    if (mounted) setState(() {});
  }

  Future<void> _rename(MacPairing p, String? nick) async {
    if (p.isLocal) return;
    final link = _link;
    if (link != null && link.pairing.room == p.room) {
      link.rename(nick);
      p = link.pairing;
    } else {
      p = p.withNick(nick);
    }
    await Store.savePairing(p);
    _macs = [for (final m in _macs) m.room == p.room ? p : m];
    if (mounted) setState(() {});
  }

  /// Forgets any paired Mac; the one on screen goes as [_unpair] does.
  Future<void> _forget(MacPairing p) async {
    if (p.isLocal) return;
    if (_link?.pairing.room == p.room) return _unpair();
    await Store.forget(p);
    _macs = _macs.where((m) => m.room != p.room).toList();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    _attempt?.dispose();
    _drop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_ready) {
      body = const Scaffold();
    } else if (_attempt != null || _link == null || _adding) {
      body = PairScreen(
        onCode: _onCode,
        attempt: _attempt,
        onCancel: _cancelAttempt,
        onBack: _link != null && _attempt == null ? () => setState(() => _adding = false) : null,
      );
    } else {
      body = Home(
        key: ObjectKey(_link),
        link: _link!,
        terms: _terms!,
        macs: _macs,
        onSwitch: _switch,
        onAddMac: () => setState(() => _adding = true),
        onLock: _lockNow,
        onUnpair: _unpair,
        onRename: _rename,
        onForget: _forget,
      );
    }
    return MaterialApp(
      title: 'bz-uniai',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      navigatorKey: _nav,
      home: body,
      builder: (context, child) => Stack(children: [
        child!,
        if (_locked && _ready) _LockScreen(onUnlock: _unlock),
      ]),
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: C.bg,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_rounded, size: 44, color: C.accent),
            const SizedBox(height: 16),
            const Text('bz-uniai is locked',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('Unlock'),
            ),
          ]),
        ),
      ),
    );
  }
}
