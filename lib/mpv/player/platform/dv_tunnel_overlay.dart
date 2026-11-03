import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../utils/app_logger.dart';
import 'dv_tunnel.dart';

/// Shows a picture of Plezy's player screen over the tunnel's video.
///
/// The helper makes [path] for the user it runs for and hands the tunnel's
/// mpv a descriptor for it. Plezy writes premultiplied BGRA there and asks
/// mpv to read it with `overlay-add`. mpv reads the pixels before it answers,
/// so the next picture can go into the same place once the request is done.
/// mpv draws the overlay before the Dolby Vision packing, so the TV stays in
/// Dolby Vision under it.
class DvTunnelOverlay {
  static const path = '/run/dvtunnel/overlay';

  /// The tunnel's output size, which the overlay is scaled to fit.
  static const _outputWidth = 3840;
  static const _outputHeight = 2160;

  /// cd/m2 for the overlay's white. 203 is the reference white for HDR
  /// graphics, and was easier to read on the TV than 100.
  static const _maxLuma = 203;

  DvTunnelOverlay(this._tunnel);

  final DvTunnel _tunnel;
  RandomAccessFile? _file;
  bool _shown = false;

  /// Shows [bgra], [width] by [height] pixels, scaled to fit the picture.
  /// Only the [rows] rows from [top] are sent; the rest show the video.
  Future<void> show(Uint8List bgra, int width, int height, {int top = 0, int? rows}) async {
    final count = rows ?? height - top;
    final file = _file ??= await File(path).open(mode: FileMode.write);
    await file.setPosition(0);
    await file.writeFrom(bgra, top * width * 4, (top + count) * width * 4);
    final scale = min(_outputWidth / width, _outputHeight / height);
    final dw = min((width * scale).round(), _outputWidth);
    final y = (_outputHeight - (height * scale).round()) ~/ 2 + (top * scale).round();
    final dh = max(1, min((count * scale).round(), _outputHeight - y));
    await _tunnel.request([
      'overlay-add', 0, (_outputWidth - dw) ~/ 2, y, 'overlay', 0, 'bgra', //
      width, count, width * 4, dw, dh, 'no', _maxLuma,
    ]);
    _shown = true;
  }

  /// Takes the overlay off the picture.
  Future<void> hide() async {
    if (!_shown) return;
    _shown = false;
    await _tunnel.request(const ['overlay-remove', 0]);
  }

  Future<void> close() async {
    final file = _file;
    _file = null;
    try {
      await file?.close();
    } on FileSystemException catch (e) {
      appLogger.d('[DV tunnel] overlay file not closed: ${e.message}');
    }
  }
}
