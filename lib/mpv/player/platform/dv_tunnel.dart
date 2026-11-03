import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../utils/app_logger.dart';

/// A failed or refused request on the tunnel's IPC link, with mpv's error
/// string or the helper's refusal.
class DvTunnelException implements Exception {
  final String message;
  const DvTunnelException(this.message);

  @override
  String toString() => 'DvTunnelException: $message';
}

/// Dolby Vision on SteamOS through the TV's own Dolby Vision processing.
///
/// A patched amdgpu can send the Dolby Vision tunnel to the TV, but only from
/// a DRM master with nothing composited over the video, which gamescope never
/// is. So the root helper at [helperPath] (docs/dolby-vision/tunnel) switches
/// to tty2, runs mpv there with the tunnel on, and relays mpv's JSON IPC on
/// its stdin and stdout. The helper passes only the commands and properties
/// Plezy uses, because mpv runs as root. A sudoers rule lets deck run it
/// without a password.
class DvTunnel {
  static const helperPath = '/var/lib/dvtunnel/dv-tunnel';

  /// The refresh rates the helper accepts, as mpv's `--drm-mode` takes them.
  static const _rates = [
    (hz: 23.976, name: '23.98'),
    (hz: 24.0, name: '24'),
    (hz: 25.0, name: '25'),
    (hz: 29.97, name: '29.97'),
    (hz: 30.0, name: '30'),
    (hz: 50.0, name: '50'),
    (hz: 59.94, name: '59.94'),
    (hz: 60.0, name: '60'),
  ];

  static Future<bool>? _available;

  /// Whether the kernel offers the tunnel and the TV's Dolby block lists the
  /// Standard interface. Asked once per run; `PLEZY_DV_TUNNEL=0` turns it off.
  static Future<bool> available() => _available ??= _probe();

  static Future<bool> _probe() async {
    if (Platform.environment['PLEZY_DV_TUNNEL'] == '0') return false;
    if (!File(helperPath).existsSync()) return false;
    try {
      final result = await Process.run('sudo', ['-n', helperPath, 'probe']).timeout(const Duration(seconds: 10));
      appLogger.i('[DV tunnel] probe exit ${result.exitCode}: ${'${result.stdout}${result.stderr}'.trim()}');
      return result.exitCode == 0;
    } catch (e) {
      appLogger.w('[DV tunnel] probe failed', error: e);
      return false;
    }
  }

  /// The helper's name for the display rate that fits [fps], or null when
  /// none is within 0.05 Hz.
  static String? rateFor(double? fps) {
    if (fps == null || !fps.isFinite) return null;
    for (final (:hz, :name) in _rates) {
      if ((fps - hz).abs() < 0.05) return name;
    }
    return null;
  }

  DvTunnel._(this.rate, this._process, this._onEvent, this._onClosed) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_handleLine, onDone: _handleDone);
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => appLogger.w('[DV tunnel] $line'));
    // A write after the helper exits fails here rather than in the caller.
    _process.stdin.done.catchError((Object e) => appLogger.d('[DV tunnel] stdin closed: $e'));
  }

  /// Starts the helper at [rate] (see [rateFor]). [onEvent] gets each mpv
  /// event object, and [onClosed] runs once when the helper's output ends,
  /// whoever ended it.
  static Future<DvTunnel> start(
    String rate, {
    required void Function(Map<String, Object?> event) onEvent,
    required void Function() onClosed,
  }) async {
    final process = await Process.start('sudo', ['-n', helperPath, 'play', rate]);
    appLogger.i('[DV tunnel] helper started at $rate Hz');
    return DvTunnel._(rate, process, onEvent, onClosed);
  }

  final String rate;
  final Process _process;
  final void Function(Map<String, Object?> event) _onEvent;
  final void Function() _onClosed;
  final _pending = <int, Completer<Object?>>{};
  int _nextRequestId = 1;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Sends one mpv IPC command and completes with its `data`, or throws
  /// [DvTunnelException] with mpv's error or the helper's refusal.
  Future<Object?> request(List<Object> command) {
    if (_closed) return Future.error(const DvTunnelException('tunnel closed'));
    final id = _nextRequestId++;
    try {
      _process.stdin.writeln(jsonEncode({'command': command, 'request_id': id}));
    } on StateError {
      // The helper's stdin closed before _handleDone ran.
      return Future.error(const DvTunnelException('tunnel closed'));
    }
    final completer = Completer<Object?>();
    _pending[id] = completer;
    return completer.future;
  }

  void _handleLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      appLogger.w('[DV tunnel] unreadable line from the helper');
      return;
    }
    if (message is! Map<String, Object?>) return;
    if (message.containsKey('event')) {
      _onEvent(message);
      return;
    }
    final id = message['request_id'];
    final completer = id is int ? _pending.remove(id) : null;
    if (completer == null) return;
    final error = message['error'];
    if (error == 'success') {
      completer.complete(message['data']);
    } else {
      completer.completeError(DvTunnelException('$error'));
    }
  }

  void _handleDone() {
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(const DvTunnelException('tunnel closed'));
    }
    _pending.clear();
    unawaited(_process.exitCode.then((code) => appLogger.i('[DV tunnel] helper exit $code')));
    _onClosed();
  }

  /// Closes the IPC link. mpv quits when it closes, and the helper then clears
  /// the tunnel and switches back to the VT it started from.
  Future<void> close() async {
    try {
      await _process.stdin.close();
    } catch (_) {}
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // sudo passes the signal on, and the helper's handler still resets the tunnel.
        _process.kill();
        return -1;
      },
    );
  }
}
