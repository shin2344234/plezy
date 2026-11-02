# Native Dolby Vision in Plezy on SteamOS

Goal: Plezy on the UM870 sends TV-led Dolby Vision to the LG over HDMI, so the TV runs its own Dolby Vision processing. The X11 window mode on `feat/x11-window-video` stays as the HDR10 path and the fallback.

## What the hardware offers

Checked on the UM870 on 2 November 2026.

| Item | Value | Needed |
| --- | --- | --- |
| GPU | Radeon 780M, HawkPoint1, display core DCN 3.1.4 | DCN 1.0 or newer for the Hades amdgpu patches |
| Kernel | 7.2.7-valve2-2-neptune-72 | Valve publishes `linux-neptune-72-7.2.7.valve2-2.src.tar.gz` |
| Secure Boot | disabled | A custom kernel boots without signing |
| TV Dolby block | VSVDB version 2, DM 4.x, interface "Standard + Low-Latency" | Standard on this input |
| TV TMDS limit | 600 MHz in the HDMI Forum block | 594 MHz for 2160p60 RGB 8-bit |

Hades lists the Ryzen 9 7950X3D (DCN 3.1.5), Ryzen 7 5800H and RX 7600 as seen working. Nobody has reported a 780M yet.

## How Hades does it

[LibreELEC Hades](https://github.com/hadesdevls/LibreELEC-Hades) 1.0 RC5 has three parts.

1. Kernel. 63 patches, about a dozen of them for amdgpu on DCN 3.x. They add a boolean connector property `DVBRIDGE_DV_STANDARD_LAB` (and `DVBRIDGE_REFUSED`, which says why a request failed). Setting it forces a modeset, sends the Dolby vendor InfoFrame and turns dithering off. The kernel refuses every commit that is not byte-exact: primary plane alone, no cursor or overlay, XRGB8888 full screen and unscaled, no CTM, degamma, gamma or plane colour properties, no VRR, RGB 8 bpc full range over TMDS, a CTA 1080p or 2160p mode at 24 to 60 Hz. The patches target Linux 7.3. The commit message notes where 7.3 split `amdgpu_dm.c`, so the 7.2 placement is the original one.
2. libplacebo. About 25 patches that compose the picture as ETSI GS CCM 001 clause 5.4 defines it, including the full enhancement layer of profile 7.
3. Kodi `dvbridge`, GPL-3.0-or-later. It decodes the enhancement layer with a second VAAPI decoder, pairs the layers, builds the per-frame display-management metadata with dovi_tool's library, packs each frame into the tunnel in GLES shaders (12-bit limited-range BT.2020 Y'CbCr 4:2:2 computed from PQ RGB, carried in 8-bit RGB, metadata in the chroma low bits), and presents it through GBM and DRM atomic commits. The core patch is 191 KB, and about 700 smaller Kodi patches follow it.

Plezy is GPL-3.0, so this code can be used here.

## Why the stock driver can't do it

TV-led Dolby Vision needs two things from the GPU that stock amdgpu won't give user space. The first is the Dolby vendor InfoFrame (OUI 00-D0-46), which tells the TV to look for the tunnel. amdgpu sends only the AVI, HDMI and HDR InfoFrames it builds itself, and its debugfs `infoframes` folder on the UM870 is empty and read-only. The second is dithering off at 8 bpc. amdgpu dithers 8 bpc output by default, which changes the tunnelled bytes, and neither a connector property, a module parameter (`dcdebugmask`, `dcfeaturemask`) nor debugfs turns it off. So the driver has to change. The kernel itself doesn't.

The only route with no driver change is player-led Dolby Vision (LLDV) through an HDFury box that injects the low-latency InfoFrame into the HDR10 signal Plezy already sends, with mpv mapping the picture to the TV's Dolby block (896 nits). That costs about $300 of hardware for a small gain over the current HDR10 path, and the TV's own Dolby Vision processing stays off.

## The gamescope problem

In Game Mode, gamescope owns the display through libseat on tty1. It composites, sets plane colour properties for HDR, draws the cursor and the Steam overlay, and can turn on VRR. The kernel refuses the tunnel under any of those. A Vulkan window like the HDR10 path can therefore never carry Dolby Vision.

Two ways around it:

- A. VT handoff (recommended). For a Dolby Vision title, Plezy starts a small root helper. It switches to tty2, where libseat makes gamescope drop DRM master, and runs mpv on KMS with the tunnel. When playback ends it switches back to tty1. This is the same display path Hades uses (GBM and DRM, no compositor). Steam keeps running behind it, and audio still goes to the user's PipeWire.
- B. Patched gamescope. Add a tunnel mode that scans out mpv's buffer directly with every colour stage in bypass, hides the cursor and overlay, and sets the property. SteamOS starts it with `exec gamescope` from `PATH`, so a build in `~/.local/bin` could replace it without touching the read-only root. It keeps the Steam UI in charge, but every gamescope or Steam update can break it, and gamescope composites for many reasons (notifications, the overlay, the volume indicator).

## Phases

Each phase ends with a check on the TV. A failed check stops the project before the next phase costs anything.

### Phase 0: prove the chain with Hades itself (Seth, about 30 minutes)

Skipped. The static frame test in phase 2 answered the same question on 2 November 2026: the 780M and this LG input carry the tunnel.

### Phase 1: patched amdgpu module

The stock kernel stays. Only `amdgpu.ko` changes. The UM870 allows that:

- amdgpu is a module (`CONFIG_DRM_AMDGPU=m`) and is not in the initramfs, so it loads from the root filesystem after boot.
- `sig_enforce` is N and lockdown is none, so an unsigned module loads. It only taints the kernel.
- The patches touch amdgpu and DRM headers, plus one function in `drivers/video/hdmi.c`, which is built in (`CONFIG_HDMI=y`). That function, `hdmi_dolby_vendor_infoframe_pack()`, moves into amdgpu.

Steps:

- Build `amdgpu.ko` from Valve's `linux-neptune-72` 7.2.7.valve2-2 source and the running kernel's `/proc/config.gz`, with the DCN 3.x patches backported: 9899, 9910, 9950, 9953, 9971, 9973, 9978, 9984, 9987, 9988, 9990, and the low-latency pair 9975 and 9976 if they apply cleanly. Build in the `plezy-build` distrobox. The vermagic must match `7.2.7-valve2-2-neptune-72-g31504582a073`.
- Install it to `/usr/lib/modules/<version>/updates/` with the root briefly writable (`steamos-readonly disable`), run `depmod`, reboot. SSH keeps working if the display doesn't come up.
- Undo: delete the file, `depmod`, reboot. A SteamOS update also undoes it, since it replaces the root partition and usually the kernel version. Each kernel update needs a rebuild.
- Check: the connector shows `DVBRIDGE_DV_STANDARD_LAB` in `drm_info`, Game Mode still works, and `DVBRIDGE_REFUSED` reports nothing unexpected.

Done on 2 November 2026. The scripts are in `docs/dolby-vision/module`. What the port turned into:

- One cumulative diff of the Hades series (Linux 7.3 base to the patched tree) applied to Valve's 7.2.7 tree at fuzz 0 by `port2.sh`. 55 hunks applied and 22 were rejected. `fix2.py` places each reject by an exact text anchor and fails if any is left unhandled. `audit2.py` checked that every applied hunk landed in the function its 7.3 header names.
- Left out: the i915 patches, the Automatic-to-limited RGB rule and the HDR YCbCr 4:2:0/4:2:2 stream rule (both need 7.3 code that 7.2 lacks), the "color format" connector refusal (7.2 has no such property) and 9986, the restore of a crashed client's state.
- The Dolby InfoFrame packer from `drivers/video/hdmi.c` moved into the module as `amdgpu_dm_hdmi_dolby.c` with its own `linux/hdmi_dolby.h`, so the built-in `hdmi.c` and its union stay as they are.
- 7.3 keeps the plane's shaper, 3D LUT and blend curve in `dc_plane_state.cm`, and 7.2 keeps them on the plane. The tunnel check was rewritten for the 7.2 fields.
- 7.2 sends the HDMI vendor InfoFrame (HDMI VIC, 3D, ALLM) from its own slot, `hfvsif_infopacket`. 7.3 shares one vendor slot, which the Dolby VSIF takes over. The 7.2 port empties `hfvsif_infopacket` while the tunnel is on and skips the ALLM rebuild for a tunnel stream.
- Built in the `kbuild` distrobox with GCC 16. `mksymvers.sh` builds `Module.symvers` from the running kernel's exports, so `depends` matches stock. The kernel has no MODVERSIONS, so the CRCs are 0. The vermagic matches. The module has no `.BTF`, which only costs BTF type information for amdgpu.
- Installed with `install-dv.sh`, undone with `undo-dv.sh`. The rootfs reboot after installing hung in shutdown, before the new module ran, and needed the power button. Two earlier reboots that morning also had gaps, so this box's reboot is unreliable on its own.

### Phase 2: VT handoff

- From Game Mode, switch to tty2 as root, confirm gamescope drops DRM master, take it with a test program, and switch back. Gamescope must recover with the Steam UI intact. Repeat 20 times.
- Light a static Dolby Vision tunnel frame from tty2 with the property set. Pass: the TV shows its badge. If gamescope can't survive the handoff, switch to option B.

Done on 2 November 2026. The tools are in `docs/dolby-vision/tunnel`.

- Gamescope uses libseat with the logind backend. logind holds the DRM master fd and drops master when the VT changes. `vt-test.sh` ran 21 rounds of tty1 to tty2, modetest on tty2, and back to tty1. Gamescope kept the same PID every round, got master back, and logged no errors.
- `dvframe` fills a 3840x2160 XRGB8888 dumb buffer on the CPU with a PQ grey ramp packed as Hades packs it, plus one metadata packet (L1 and a full-raster L5, 95 bytes). It commits the tunnel at 3840x2160 24 Hz. The LG showed its Dolby Vision badge and a smooth grey ramp.
- The first try was refused with `scanout` because gamescope leaves AMD's private colour properties set after it loses master: `AMD_CRTC_REGAMMA_TF`, and on the plane the degamma curve, shaper LUT, 3D LUT and blend curve. The tunnel commit has to put every writable `AMD_*` property on the CRTC and the primary plane back to Default, as `dvframe` now does. Gamescope sets them again when it gets master back.
- `dv-show.sh` runs `dvframe reset` and switches back to tty1 from an exit trap. A tunnel left on would make the kernel refuse gamescope's commits, and the 7.2 module has no crash restore (9986 was left out).

### Phase 3: the player

- mpv's `drm` GPU context gets the tunnel: set the property, max bpc 8, default colourspace, no HDR metadata, primary plane XRGB8888.
- Port the packer and the metadata step from `DVBridgeGLES.cpp` and the Kodi metadata patches (kodi-9260 and on) into mpv as a final render pass, with dovi_tool's library for the per-frame metadata. Start with profiles 8.1 and 5.
- Then profile 7: the enhancement-layer decoder and the libplacebo composer patches. Upstream mpv and libplacebo gained both in 2026, so this is now a rebase. The FEL plan below has the details.
- Pad controls and an on-screen seek bar have to come from mpv itself, since the Plezy UI is not visible on tty2.

Profile 8.1 played on 2 November 2026. The patch against mpv v0.41.0 and the build scripts are in `docs/dolby-vision/mpv`.

- `--drm-dvbridge` makes the `drm` context request the tunnel on the connector, put the `AMD_*` colour properties back to Default as `dvframe` does, and turn off the other planes on the CRTC. mpv clears the tunnel itself on exit. `dv-play.sh` still runs `dvframe reset` from its trap in case mpv dies.
- `vo_gpu_next` renders each frame into a 3840x2160 rgba32f texture in BT.2020 PQ with clip tone and gamut mapping. A custom shader then packs it into the tunnel's 12-bit 4:2:2 and writes the metadata bits into the chroma LSBs. Frame mixing, dither and peak detection are off in this mode.
- The metadata comes from FFmpeg's `AV_FRAME_DATA_DOVI_METADATA` side data, serialized in `dvbridge.h`, so dovi_tool isn't needed for profiles 5 and 8. The CM v4.0 levels (3, 4, 8 to 11 and 254) need the raw RPU bytes from a patched FFmpeg. Until then mpv leaves them out, sends CM v2.9 only, and warns once.
- The texture needs `blit_dst` because libplacebo clears the letterbox bars with `pl_tex_clear`. The first run lacked it and logged a validation error on every frame.
- Test: 60 seconds of The Amateur (2025), HEVC 3840x1608 profile 8.1 at 23.976 fps, streamed from the Plex server over the LAN and decoded with VAAPI, output at 3840x2160 23.98 Hz. The LG showed its Dolby Vision badge and the picture looked right. mpv dropped no frames.
- Profile 7 MEL plays as 8.1. `dvbridge_dovi_is_mel()` applies dovi_tool's `is_mel()` test: zero NLQ offset, vdr_in_max of exactly 1.0, zero deadzone slope and threshold. libplacebo's `pl_map_avdovi_metadata` skips any frame with a residual, so `mp_image.c` maps a MEL frame from a copy of the RPU with `disable_residual_flag` set. FEL frames stay unmapped and the packer refuses them.
- `dvtest` (`dvtest.c`, `build-dvtest.sh`) decodes a few frames of a file or Plex URL and runs them through `dvbridge.h`, which shows whether the tunnel would accept a file without the TV.
- The Plex library on WLK-LIVINGRM has 100 4K movies: 44 profile 8.1, 2 profile 8.6, and 28 profile 7, of which 11 are MEL and 17 FEL. None is profile 5.
- TV tests on 2 November 2026, all with the badge and a correct picture: Sinners (profile 7 MEL) and The Incredible Hulk (8.6) at 23.98 Hz, then Jellyfin's test clips (4K profile 5, 1080p profile 5, 4K profile 8.4, 1080p profile 8.1) and an iPhone 13 Pro clip (profile 8.4) at 60 Hz. The 1080p clips are scaled to 4K before packing. The 8.4 clips have an HLG base that the RPU reshapes to PQ. The iPhone clip keeps only L1 and L5, since 9 of its 10 blocks are CM v4.0.
- Profile 7 FEL plays on the TV with the mpv master build, as the FEL plan below records.
- Still to do in this phase: moving the remaining profiles onto the mpv master build, the CM v4.0 levels, and pad controls with a seek bar. L5 uses the full decoded size and doesn't follow mpv's crop yet. libplacebo may still pick fp16 for its own intermediate textures before the rgba32f target.

#### Profile 7 FEL plan

Upstream already does the decoding and the composition. mpv's master branch has carried FEL since 1 July 2026, with fixes up to 2 September, and no release has it yet. `demux/dovi_split` pulls an in-band EL out of a single HEVC track in both `demux_mkv` and `demux_lavf`. A second decoder runs the EL, and `f_enhancement_pair` pairs BL and EL frames whose PTS agree within a microsecond. `vo_gpu_next` then maps the EL from VAAPI the same way as the BL and hands it to libplacebo as `pl_frame.enhancement_layer`. libplacebo added that field and the NLQ merge in API 367, and mpv master needs 7.387.0. Our prefix has 7.360.1.

libplacebo 7.387 maps every DV frame. It sets `nlq_active` only when a frame has a residual with nontrivial NLQ, so a MEL frame composes like 8.1 without our `mp_image.c` copy.

Coraline (2009) shows the layout the Plex library uses. It has one HEVC track at 3840x2160 and 24 fps, with profile 7, BL, EL and RPU flags set. Each access unit carries the RPU as NAL 62 and the EL wrapped in NAL 63. Unwrapped, the EL is a 1920x1080 Main 10 HEVC stream with one picture per BL picture, 108 of each in 4.5 seconds. This is the case `dovi_split` handles.

Hades goes further. Its libplacebo carries about 25 patches that compose per ETSI GS CCM 001 clause 5.4 in integer arithmetic, with a per-plane choice of EL upscaler. Upstream composes in floats and assumes a left-sited EL. The Hades patches target libplacebo commit 275f7dea from 25 October 2026, which is newer than 7.387, so they could go on later if the upstream picture looks wrong next to Hades.

The work, in order:

1. Build libplacebo 7.387.0 in its own prefix, so Plezy keeps 7.360.1.
2. Move the dvbridge patch from v0.41.0 to a pinned mpv master commit. Drop the MEL copy in `mp_image.c`.
3. Let `dvbridge_dv_metadata` accept frames with a residual. When `nlq_active` is set and no EL is attached, libplacebo composes the BL alone, so mpv should count those frames and warn rather than leave the tunnel. Hades makes the same choice in kodi-9020.
4. Run Coraline headless with `-v` and check that the EL decoder starts on VAAPI and the pairing logs no BL-only frames after warm-up.
5. With Seth's approval, play Coraline on the TV at 24 Hz and compare it against the same scene played as MEL-style BL only.

The risks are mpv master moving under the patch, and the GPU time for the 780M to decode a second stream and to upscale and merge the EL at 4K. `dvtest` can't check FEL, since it decodes only the BL track through FFmpeg.

Steps 1 to 4 were done on 2 November 2026. The scripts and the patch are in `docs/dolby-vision/mpv`. Three things came up that the plan didn't expect.

- mpv's splitter needs FFmpeg's `dovi_split` bitstream filter, which is only in FFmpeg master and in no release, 8.1.3 included. `build-ffmpeg.sh` builds n8.0.1 with Plezy's common patches and backports the filter from commit 8828574c98. n8.0.1 has no `AV_PKT_DATA_HEVC_CONF`, so `dovi_split-n8.0.1.patch` removes the filter's use of it. The EL then keeps the BL's hvcC and takes its parameter sets from its own NAL units, which Coraline carries in band.
- mpv master asks for Vulkan headers 1.4.309 when Vulkan is on, and plezy-build has 1.3.275. `build-dvmpv-master.sh` turns Vulkan off, since the tunnel runs on the DRM EGL context. It builds against a copy of the libmpv-window prefix with the old libplacebo, FFmpeg and libmpv taken out, because that prefix's include directory otherwise puts the 7.360.1 headers first.
- libplacebo 7.387's `convert.cc` calls `std::to_chars` and `std::from_chars` on floats, and its static `.pc` doesn't list libstdc++. `build-libplacebo.sh` adds `-lstdc++` to the `Libs` line, or mpv fails to link.

The headless check on Coraline from 15:00 for 20 seconds with `vaapi-copy` opened the splitter as "BL stream 0, virtual EL stream 1", ran both decoders on VAAPI at 3840x2160 and 1920x1080, and logged no "emitting BL alone" or "dropping stale EL" line. Every BL frame in that span left `f_enhancement_pair` with its EL. `--vo=null` doesn't compose, so the picture and the FEL frame counters in `vo_gpu_next` wait for the TV run in step 5.

Step 5 ran the same day. Coraline played from 15:00 for 60 seconds at 3840x2160 and 24 Hz with `--hwdec=vaapi`, and the TV showed the DV badge and a correct picture. mpv's exit line was "Dolby Vision FEL: 1439 frames, 0 without the enhancement layer", A-V stayed at 0.000, and no frame dropped, so the 780M keeps up with both decodes and the merge. The comparison against BL only wasn't run, and the Hades composer patches stay parked since upstream's picture looked right.

The other profiles were replayed on the master build next, for 30 seconds each. All three showed the DV badge. Sinners (7 MEL) and The Amateur (8.1) at 23.98 Hz dropped nothing, so libplacebo 7.387 composes MEL without the old `mp_image.c` copy. The Jellyfin 4K profile 5 clip at 60 Hz dropped 863 of about 1800 frames, while the v0.41.0 build played it clean. GPU time was not the difference, at 5.13 ms a frame on master against 4.91 ms, and both builds decode the clip at about 240 fps. The cause is upstream commit 7b3a22a from 7 October 2026 in `context_drm_egl.c`. Its message says `allow_modeset` should survive only a failed commit, but the code sets it to `!ret`, so after the first successful flip every commit asks for `DRM_MODE_ATOMIC_ALLOW_MODESET`, and amdgpu's full validation on each one doesn't fit in a 60 Hz frame. Upstream master still had it on 2 November. With the flag set to `ret != 0` the clip played at 60 Hz without a drop and 4.78 ms of GPU time. `dvbridge-master.patch` now has `p->allow_modeset &= ret != 0`, which also keeps a failed plain flip from asking for a modeset that wasn't pending, and the clip played clean with it too at 5.00 ms. Upstream tracks the bug as mpv-player/mpv#18743, with a rework of the HDR commit path in PR #18744 under review. `upstream-allow-modeset.md` holds a draft comment with these numbers. `dv-passes.sh` reads the per-pass GPU timings over the IPC socket during a run. The fixed build then played the rest of the 60 Hz clips, the Jellyfin 1080p profile 5, 1080p 8.1 and 4K 8.4 and the iPhone 8.4, with the DV badge, no dropped frame and the same CM v4.0 warnings as v0.41.0. Every profile tested on v0.41.0 now plays on the master build.

### Phase 4: Plezy integration

- Plezy picks this path when the stream is Dolby Vision, the kernel offers the property, and the TV block says Standard. Otherwise it uses the HDR10 window.
- The helper runs mpv with its JSON IPC socket. Plezy drives it through that socket and keeps reporting progress, pause and stop to Plex, as it does now.
- A sudoers rule lets the `deck` user start only that helper.

## Risks

- DCN 3.1.4 and this LG carried profiles 5, 7 MEL, 8.1, 8.4 and 8.6 at 23.98 Hz and 60 Hz. Frame-rate switches during playback and profile 7 FEL are still untested.
- A player that dies with the tunnel on leaves the property set until something clears it. The helper has to run `dvframe reset` on every exit path, and `amdgpu.dvbridge=0` on the kernel command line is the switch that turns the feature off.
- A SteamOS update removes the patched module, and Valve may move to a newer kernel that the patches don't fit.
- Gamescope may not survive a VT switch cleanly. Option B is the fallback, and it's more fragile.
- Hades is a release candidate and the amdgpu patches are new. Expect to follow its fixes.
- Dolby Vision output without a Dolby licence is fine for personal use. This should not be published as a product.
- Size: phases 1 and 2 are a few sessions. Phase 3 is the bulk, likely weeks for profile 7 with the full enhancement layer.
