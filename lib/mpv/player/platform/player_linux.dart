import 'dart:async';

import '../player_native.dart';
import '../video_rect_support.dart';

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
class PlayerLinux extends PlayerNative with VideoRectSupport {
  static final _windowExitRequests = StreamController<void>.broadcast();

  /// Back presses in mpv's own video window. The press never reaches Flutter
  /// as a key event, because the window has focus, so the player screen
  /// leaves through this stream instead.
  static Stream<void> get windowExitRequests => _windowExitRequests.stream;

  @override
  void handlePlayerEvent(String name, Map? data) {
    if (name == 'window-exit') {
      _windowExitRequests.add(null);
      return;
    }
    super.handlePlayerEvent(name, data);
  }
}
