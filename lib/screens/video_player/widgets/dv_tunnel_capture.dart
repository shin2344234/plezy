import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../mpv/player/platform/dv_tunnel_overlay.dart';
import '../../../mpv/player/platform/player_linux.dart';
import '../../../utils/app_logger.dart';

/// Puts [child] on the TV while a Dolby Vision tunnel has the screen.
///
/// The TV shows tty2 then, not Plezy's window, but Flutter keeps drawing the
/// window. So after each new frame [child] is read back from a repaint
/// boundary and handed to the tunnel's mpv through [PlayerLinux.tunnelOverlay].
/// A frame drawn while a capture runs is picked up when it ends. Only the rows
/// with something on them go. A picture with nothing on it takes the overlay
/// away, and one that matches the last is not sent again.
class DvTunnelCapture extends StatefulWidget {
  final Widget child;

  const DvTunnelCapture({super.key, required this.child});

  @override
  State<DvTunnelCapture> createState() => _DvTunnelCaptureState();
}

class _DvTunnelCaptureState extends State<DvTunnelCapture> {
  /// The capture's width in pixels. mpv scales it up to the 4K picture, and
  /// a 4K capture would be four times the bytes to read back and compare.
  static const _captureWidth = 1920.0;

  /// How fast animations run while the tunnel shows. Flutter draws only 15 to
  /// 20 frames a second then, so a 200 ms focus or fade animation crawls over
  /// several captures. At this speed each one lands within a frame and the
  /// focus just moves.
  static const _tunnelTimeDilation = 0.02;

  final _boundaryKey = GlobalKey();
  DvTunnelOverlay? _overlay;
  bool _busy = false;
  bool _failed = false;

  /// Whether Flutter drew a frame since the last capture. With nothing drawn,
  /// the picture can't have changed.
  bool _painted = true;

  /// The last picture sent, in BGRA, or null while the overlay is off.
  Uint32List? _last;

  /// The indexes of the first and last pixels that show in [_last].
  var _lastBand = (first: -1, last: -1);

  @override
  void initState() {
    super.initState();
    PlayerLinux.tunnelOverlay.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    PlayerLinux.tunnelOverlay.removeListener(_sync);
    if (_overlay != null) timeDilation = 1.0;
    super.dispose();
  }

  void _sync() {
    final overlay = PlayerLinux.tunnelOverlay.value;
    if (identical(overlay, _overlay)) return;
    _overlay = overlay;
    timeDilation = overlay != null ? _tunnelTimeDilation : 1.0;
    _last = null;
    _failed = false;
    _painted = true;
    if (overlay != null) {
      _watchFrames(overlay);
      unawaited(_capture(overlay));
    }
  }

  /// Captures after each frame while [overlay] is current. A post-frame
  /// callback doesn't ask for a frame, so this costs nothing idle.
  void _watchFrames(DvTunnelOverlay overlay) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(overlay, _overlay)) return;
      _painted = true;
      unawaited(_capture(overlay));
      _watchFrames(overlay);
    });
  }

  Future<void> _capture(DvTunnelOverlay overlay) async {
    if (_busy || !mounted || !_painted || !identical(overlay, _overlay)) return;
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize || boundary.size.isEmpty) return;
    _busy = true;
    _painted = false;
    try {
      final image = await boundary.toImage(pixelRatio: _captureWidth / boundary.size.width);
      final (width, height) = (image.width, image.height);
      final ByteData? data;
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
      if (data == null || !identical(overlay, _overlay)) return;
      final pixels = data.buffer.asUint32List(data.offsetInBytes, width * height);
      final (:first, :last, :same) = _toBgra(pixels, _last, _lastBand);
      final visible = first >= 0;
      final top = visible ? first ~/ width : 0;
      final rows = visible ? last ~/ width - top + 1 : 0;
      if (!visible) {
        if (_last == null) return;
        _last = null;
        await overlay.hide();
      } else if (!same) {
        final bytes = data.buffer.asUint8List(data.offsetInBytes, width * height * 4);
        await overlay.show(bytes, width, height, top: top, rows: rows);
        _last = pixels;
        _lastBand = (first: first, last: last);
      }
    } catch (e) {
      // The tunnel may be closing. Say so once per tunnel and keep trying.
      if (!_failed) appLogger.w('[DV tunnel] overlay not sent', error: e);
      _failed = true;
    } finally {
      _busy = false;
    }
    // A frame drawn during the capture has had its callback turned away.
    if (_painted) unawaited(_capture(overlay));
  }

  /// Turns Flutter's RGBA into the BGRA mpv takes, in place, between the
  /// first and last pixels that show. Returns their indexes, -1 when none do,
  /// and whether the result matches [last], whose own pixels that show span
  /// [band]. Both are premultiplied, so a pixel that shows nothing is 0 in
  /// either order.
  static ({int first, int last, bool same}) _toBgra(
    Uint32List pixels,
    Uint32List? last,
    ({int first, int last}) band,
  ) {
    var first = 0;
    while (first < pixels.length && pixels[first] == 0) {
      first++;
    }
    if (first == pixels.length) return (first: -1, last: -1, same: last == null);
    var end = pixels.length - 1;
    while (pixels[end] == 0) {
      end--;
    }
    final previous = last ?? Uint32List(0);
    var same = previous.length == pixels.length && band.first == first && band.last == end;
    for (var i = first; i <= end; i++) {
      final p = pixels[i];
      final bgra = (p & 0xFF00FF00) | ((p & 0xFF) << 16) | ((p >> 16) & 0xFF);
      pixels[i] = bgra;
      if (same && previous[i] != bgra) same = false;
    }
    return (first: first, last: end, same: same);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(key: _boundaryKey, child: widget.child);
}
