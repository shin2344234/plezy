import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../utils/app_logger.dart';
import '../../models.dart';
import '../player_native.dart';
import '../video_rect_support.dart';
import 'dv_tunnel.dart';
import 'dv_tunnel_overlay.dart';

/// Uses libmpv on Linux, through one of two outputs the native side picks.
///
/// Under Wayland, video goes to a `wl_subsurface` stacked below the Flutter
/// surface, the same shape Windows gets from a child HWND: geometry arrives via
/// [VideoRectSupport.setVideoRect] and Flutter never composites the frames.
///
/// Under X11, which includes gamescope's Game Mode, mpv opens its own
/// fullscreen Vulkan window instead. That window is the path gamescope gives
/// an HDR10 swapchain. It holds input focus while it is up, so mpv draws its
/// own controls and reads the gamepad itself, and the rect and visibility calls
/// have nothing to move. A back press there arrives as [windowExitRequests].
///
/// A Dolby Vision file can instead play through the TV's own Dolby Vision
/// processing, when [DvTunnel.available] says the kernel and the TV support
/// it. The player screen says what is about to open through [prepareOpen].
/// While the tunnel is up, calls go to the helper's mpv over its IPC link and
/// its events come back in the shapes the native core sends, so progress and
/// stop reporting run unchanged. The in-process core stays idle and still
/// gets every property write and observation, so it can take over again.
class PlayerLinux extends PlayerNative with VideoRectSupport {
  static final _windowExitRequests = StreamController<void>.broadcast();

  /// Back presses in mpv's own video window or in the tunnel. The press never
  /// reaches Flutter as a key event, because mpv has the input, so the player
  /// screen leaves through this stream instead.
  static Stream<void> get windowExitRequests => _windowExitRequests.stream;

  static final _tunnelOverlay = ValueNotifier<DvTunnelOverlay?>(null);

  /// Where the player screen draws its controls while a tunnel has the
  /// screen, or null when there is no tunnel. The TV shows tty2 then, not
  /// Plezy's window.
  static ValueListenable<DvTunnelOverlay?> get tunnelOverlay => _tunnelOverlay;

  /// What mpv's pad bindings send for back, as the window's and the tunnel's
  /// input.conf both write it.
  static const _windowExitMessage = 'plezy-window-exit';

  /// The properties the tunnel's mpv takes, the same list as SETTABLE in
  /// dv-tunnel, which refuses the rest. Writes to anything else, such as the
  /// HDR and vo settings, only matter to the in-process core.
  static const _tunnelProperties = {
    'pause', 'volume', 'volume-max', 'mute', 'speed', 'aid', 'sid', //
    'secondary-sid', 'sub-visibility', 'secondary-sub-visibility', //
    'sub-delay', 'audio-delay', 'sub-scale', 'sub-pos', 'sub-font', //
    'sub-font-size', 'sub-bold', 'sub-italic', 'sub-color', //
    'sub-border-color', 'sub-border-size', 'sub-border-style', //
    'sub-shadow-offset', 'sub-shadow-color', 'sub-back-color', //
    'sub-margin-x', 'sub-margin-y', 'sub-align-x', 'sub-align-y', 'sub-ass', //
    'sub-ass-override', 'sub-ass-force-margins', 'sub-use-margins', //
    'sub-spacing', 'sub-blur', 'sub-justify', 'start', 'network-timeout', //
    'demuxer-max-bytes', 'demuxer-max-back-bytes', 'demuxer-readahead-secs', //
    'demuxer-seekable-cache', 'cache', 'cache-secs', 'cache-pause', //
    'cache-pause-initial', 'cache-pause-wait', 'force-seekable', //
    'prefetch-playlist', 'audio-channels', 'audio-normalize-downmix', //
    'keepaspect', 'http-header-fields', 'user-agent', 'referrer', //
    'msg-level', 'hr-seek', 'loop-file', 'deinterlace', 'stream-buffer-size', //
    'stream-lavf-o', 'demuxer-lavf-o', //
  };

  ({bool dolbyVision, double? fps})? _nextOpen;
  DvTunnel? _tunnel;
  int? _tunnelSourceId;
  final _observations = <int, ({String name, String format})>{};
  final _propertyWrites = <String, String>{};
  String _logLevel = 'warn';
  bool _idleWindowHidden = false;

  /// Set while a property change from the tunnel's mpv is being handled.
  bool _deliveringTunnelEvent = false;

  /// Tells the next [open] whether the server reports Dolby Vision for it and
  /// at what frame rate. Only a direct-played network file qualifies, since
  /// a transcode drops the Dolby Vision layer and the helper opens only http
  /// and https URLs.
  void prepareOpen({required bool dolbyVision, double? fps}) {
    _nextOpen = (dolbyVision: dolbyVision, fps: fps);
  }

  @override
  void handlePlayerEvent(String name, Map? data) {
    if (name == 'window-exit') {
      // This mpv keeps reading the pad while the tunnel has the screen, and
      // its B binding would leave the player behind Plezy's own back handling.
      // The tunnel's mpv sends its own exit through _handleTunnelEvent.
      if (_tunnel == null) _windowExitRequests.add(null);
      return;
    }
    super.handlePlayerEvent(name, data);
  }

  @override
  void handlePropertyChange(String name, dynamic value, {int? sourceId}) {
    // The idle core keeps its observations, and its pad's A cycles its own
    // pause, which would undo the pause Plezy just set on the tunnel.
    final tunnel = _tunnel;
    if (tunnel != null && !tunnel.isClosed && !_deliveringTunnelEvent) return;
    super.handlePropertyChange(name, value, sourceId: sourceId);
  }

  @override
  Future<int?> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
    bool startLivePlaylistFromBeginning = false,
  }) async {
    final next = _nextOpen;
    _nextOpen = null;
    final rate = next != null && next.dolbyVision ? DvTunnel.rateFor(next.fps) : null;
    if (rate != null && await DvTunnel.available()) {
      final tunnel = _tunnel;
      if (tunnel == null || tunnel.isClosed || tunnel.rate != rate) {
        await _closeTunnel();
        await _setIdleWindow(false);
        await _startTunnel(rate);
      }
    } else {
      if (next != null && next.dolbyVision) {
        appLogger.i('[DV tunnel] not used: ${rate == null ? 'no display rate for ${next.fps} fps' : 'probe said no'}');
      }
      await _closeTunnel();
      await _setIdleWindow(true);
    }
    return super.open(
      media,
      play: play,
      isLive: isLive,
      externalSubtitles: externalSubtitles,
      timelineDuration: timelineDuration,
      timelineOffset: timelineOffset,
      startLivePlaylistFromBeginning: startLivePlaylistFromBeginning,
    );
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await _closeTunnel();
    return super.dispose(preserveDisplayMode: preserveDisplayMode);
  }

  @override
  Future<T?> invoke<T>(String method, [dynamic args]) async {
    if (args is Map) {
      if (method == 'observeProperty') {
        final (id, name, format) = (args['id'], args['name'], args['format']);
        if (id is int && name is String && format is String) _observations[id] = (name: name, format: format);
      } else if (method == 'setProperty') {
        final (name, value) = (args['name'], args['value']);
        if (name is String && value is String) _propertyWrites[name] = value;
      } else if (method == 'setLogLevel') {
        final level = args['level'];
        if (level is String) _logLevel = level;
      }
    }
    final tunnel = _tunnel;
    if (tunnel == null || tunnel.isClosed) return super.invoke<T>(method, args);
    return _invokeOnTunnel<T>(tunnel, method, args);
  }

  Future<T?> _invokeOnTunnel<T>(DvTunnel tunnel, String method, dynamic args) async {
    switch (method) {
      case 'command':
        final command = List<Object>.from((args as Map)['args'] as List);
        final data = await _request(tunnel, command, 'COMMAND_FAILED');
        // Same reply as the native core's: loadfile names the entry it made.
        if (command.firstOrNull == 'loadfile' && data is Map && data['playlist_entry_id'] is int) {
          return {'playlistEntryId': data['playlist_entry_id']} as T;
        }
        return null;
      case 'setProperty':
        await _invokeOnIdleCore(method, args);
        final (name, value) = ((args as Map)['name'] as String, args['value'] as String);
        if (_tunnelProperties.contains(name)) await _request(tunnel, ['set', name, value], 'SET_PROPERTY_FAILED');
        if (name == 'aid' || name == 'sid') await _refreshTracks(tunnel);
        return null;
      case 'observeProperty':
        await _invokeOnIdleCore(method, args);
        final map = args as Map;
        await _observe(tunnel, map['id'] as int, map['name'] as String, map['format'] as String);
        return null;
      case 'getProperty':
        try {
          return await tunnel.request(['get_property_string', (args as Map)['name'] as String]) as T?;
        } on DvTunnelException {
          return null;
        }
      case 'setLogLevel':
        await _invokeOnIdleCore(method, args);
        await _request(tunnel, ['request_log_messages', _logLevel], 'COMMAND_FAILED');
        return null;
      case 'setVisible' || 'setVideoRect' || 'updateFrame' || 'setVideoZoom':
        // Nothing of the native output is on screen while the tunnel has tty2.
        return null;
      default:
        return super.invoke<T>(method, args);
    }
  }

  /// Keeps the idle in-process core in step, so it has the same settings and
  /// observations if it takes over again. Its refusals don't concern the
  /// tunnel.
  Future<void> _invokeOnIdleCore(String method, dynamic args) async {
    try {
      await super.invoke<void>(method, args);
    } on PlatformException catch (e) {
      appLogger.d('[DV tunnel] idle core refused $method: ${e.code}');
    }
  }

  static Future<Object?> _request(DvTunnel tunnel, List<Object> command, String code) async {
    try {
      return await tunnel.request(command);
    } on DvTunnelException catch (e) {
      throw PlatformException(code: code, message: '${command.first}: ${e.message}');
    }
  }

  /// With a profile 7 file's split-off enhancement layer selected, mpv can't
  /// re-read a newly picked track from the current position ("can't issue
  /// refresh seek"), and the track starts where the cache has read ahead to.
  /// An exact seek to the same position fetches it again. Before a file is
  /// loaded the seek fails, and there is nothing to fetch.
  Future<void> _refreshTracks(DvTunnel tunnel) async {
    if (_tunnelSourceId == null) return;
    try {
      await tunnel.request(const ['seek', 0, 'relative+exact']);
    } on DvTunnelException catch (e) {
      appLogger.d('[DV tunnel] track refresh seek: ${e.message}');
    }
  }

  static Future<void> _observe(DvTunnel tunnel, int id, String name, String format) {
    final command = format == 'string' ? 'observe_property_string' : 'observe_property';
    return _request(tunnel, [command, id, name], 'COMMAND_FAILED');
  }

  /// The in-process core's window stays up while the core is idle, because
  /// the window output sets force-window. Over a tunnel it would cover
  /// Plezy's own screen in Game Mode while the helper starts and after it
  /// exits, so it closes for the tunnel and comes back for the next file the
  /// core plays itself.
  Future<void> _setIdleWindow(bool shown) async {
    if (_idleWindowHidden != shown) return;
    try {
      await setProperty('force-window', shown ? 'yes' : 'no');
      _idleWindowHidden = !shown;
    } on PlatformException catch (e) {
      appLogger.w('[DV tunnel] force-window not changed: ${e.code}');
    }
  }

  Future<void> _startTunnel(String rate) async {
    // The in-process core may still be playing the previous item.
    if (initialized) await _invokeOnIdleCore('command', {'args': const ['stop']});
    late final DvTunnel tunnel;
    try {
      tunnel = await DvTunnel.start(
        rate,
        onEvent: (event) => _handleTunnelEvent(tunnel, event),
        onClosed: () => _handleTunnelClosed(tunnel),
      );
    } catch (e) {
      appLogger.w('[DV tunnel] helper did not start, playing without it', error: e);
      return;
    }
    _tunnel = tunnel;
    _tunnelSourceId = null;
    try {
      await tunnel.request(['request_log_messages', _logLevel]);
      for (final MapEntry(key: id, value: observation) in _observations.entries) {
        await _observe(tunnel, id, observation.name, observation.format);
      }
      for (final MapEntry(key: name, value: value) in _propertyWrites.entries) {
        if (name == 'start' || !_tunnelProperties.contains(name)) continue;
        try {
          await tunnel.request(['set', name, value]);
        } on DvTunnelException catch (e) {
          appLogger.w('[DV tunnel] $name not applied: ${e.message}');
        }
      }
      // mpv answering means the helper has made the overlay file.
      _tunnelOverlay.value = DvTunnelOverlay(tunnel);
    } on Object catch (e) {
      appLogger.w('[DV tunnel] setup failed, playing without it', error: e);
      await _closeTunnel();
    }
  }

  Future<void> _closeTunnel() async {
    final tunnel = _tunnel;
    if (tunnel == null) return;
    _tunnel = null;
    _tunnelSourceId = null;
    _dropOverlay();
    await tunnel.close();
  }

  static void _dropOverlay() {
    final overlay = _tunnelOverlay.value;
    _tunnelOverlay.value = null;
    unawaited(overlay?.close());
  }

  void _handleTunnelClosed(DvTunnel tunnel) {
    // A close this player asked for has already cleared _tunnel.
    if (!identical(_tunnel, tunnel)) return;
    _tunnel = null;
    _dropOverlay();
    if (disposed) return;
    // mpv or the helper ended on its own, and Game Mode is back on screen
    // with a player that shows nothing, so leave it as a back press would.
    appLogger.w('[DV tunnel] closed during playback');
    _windowExitRequests.add(null);
  }

  void _handleTunnelEvent(DvTunnel tunnel, Map<String, Object?> event) {
    if (disposed || !identical(_tunnel, tunnel)) return;
    switch (event['event']) {
      case 'property-change':
        final id = event['id'];
        final observation = id is int ? _observations[id] : null;
        if (observation == null) return;
        _deliveringTunnelEvent = true;
        try {
          handlePropertyChange(
            observation.name,
            _convert(event['data'], observation.format),
            sourceId: _tunnelSourceId,
          );
        } finally {
          _deliveringTunnelEvent = false;
        }
      case 'start-file':
        final id = event['playlist_entry_id'];
        _tunnelSourceId = id is int ? id : null;
        handlePlayerEvent('start-file', {'sourceId': _tunnelSourceId});
      case 'file-loaded':
        handlePlayerEvent('file-loaded', {'sourceId': _tunnelSourceId});
      case 'playback-restart':
        unawaited(_reportPlaybackRestart(tunnel, _tunnelSourceId));
      case 'end-file':
        handlePlayerEvent('end-file', {
          'sourceId': event['playlist_entry_id'] ?? _tunnelSourceId,
          'reason': event['reason'],
          if (event['file_error'] case final String message) 'message': message,
        });
      case 'log-message':
        handlePlayerEvent('log-message', {'prefix': event['prefix'], 'level': event['level'], 'text': event['text']});
      case 'client-message':
        if (event['args'] case [_windowExitMessage, ...]) _windowExitRequests.add(null);
    }
  }

  /// The native core sends playback-restart with the position it landed on,
  /// which IPC's event leaves out, so it is asked for first.
  Future<void> _reportPlaybackRestart(DvTunnel tunnel, int? sourceId) async {
    double? seconds;
    try {
      final position = await tunnel.request(const ['get_property', 'time-pos']);
      if (position is num) seconds = position.toDouble();
    } on DvTunnelException {
      // Delivered without a position, as the native core does on a failed read.
    }
    if (disposed || !identical(_tunnel, tunnel)) return;
    handlePlayerEvent('playback-restart', {'sourceId': sourceId, 'positionSeconds': ?seconds});
  }

  /// IPC sends JSON values. The native core sends what each observation's
  /// format asked for.
  static Object? _convert(Object? data, String format) => switch (format) {
    'double' => data is num ? data.toDouble() : null,
    'flag' => data is bool ? data : null,
    'string' => data?.toString(),
    _ => data,
  };
}
