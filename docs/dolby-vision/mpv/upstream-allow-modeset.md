# mpv upstream: allow_modeset in queue_flip()

Drafts only. Nothing here has been posted or pushed.

## Where upstream stands on 2 November 2026

mpv master at a687796d still has `p->allow_modeset = !ret;` at line 341 of `video/out/opengl/context_drm_egl.c`. No release carries the bug. v0.41.0 is the newest release, and 7b3a22a landed 1111 commits after it, so only master and the rolling `git-release` builds have it.

It is already reported. FongMi opened [mpv-player/mpv#18743](https://github.com/mpv-player/mpv/issues/18743) on 1 November with the same diagnosis, checked against a mocked fixture and not on hardware. The issue says outright that display behaviour and driver effects were not verified. Dudemanguy opened [mpv-player/mpv#18744](https://github.com/mpv-player/mpv/pull/18744) the same day with "Fixes #18743". That PR does not touch the one line. It removes `allow_modeset`, stores a colorspace pointer on each queued `gbm_frame`, and sets the HDR blob and `DRM_MODE_ATOMIC_ALLOW_MODESET` in `queue_flip()` only for frames that carry a colour change. kasper93 reviewed it today with four points. The colorspace should be stored by value. `drm_egl_init()` keeps the address of a stack local in a frame. A commit the driver keeps rejecting never leaves the swap loop. And the frame's colorspace could be compared with the connector's instead of tracking a pending pointer. Dudemanguy has answered the first point, the macOS CI jobs fail, and the PR will change again. Dudemanguy also asked in the PR whether someone can check that HDR still works, since they can't test it.

A new issue would be closed as a duplicate of #18743. The useful thing Seth has that upstream lacks is the hardware symptom, so the first draft below is a comment for #18743. The full issue text follows in case #18743 is closed without a fix landing. The patch is a fallback for the same case, because a one-liner that competes with a maintainer's open PR is unlikely to be taken.

## Decide before posting

mpv's `DOCS/contribute.md` has a section on AI-assisted contributions. It requires disclosure in the issue or PR description, naming the model and the tool, and keeps it out of commit messages. It says issues and PRs that hide LLM involvement are closed without review, and #18743 itself ends with such a disclosure line. These drafts were written with Claude Opus 5.5 in the Claude Code desktop app and contain no disclosure, per Seth's attribution rule. Whether to add one is Seth's call. The section also says not to submit analysis you have not reproduced yourself, and the caveats below are written with that in mind.

The 60 Hz run used mpv master a687796d with `dvbridge-master.patch` and the Hades-patched `amdgpu.ko`. The dvbridge patch sets its connector and CRTC properties once at setup and leaves `queue_flip()` and the per-frame request alone, apart from the one-line fix. Stock mpv on a stock module was never run. The drafts say so.

The kernel-side cost is a guess. Nobody here traced where amdgpu spends the time on a commit that carries `DRM_MODE_ATOMIC_ALLOW_MODESET` with nothing to modeset, so the drafts report the drop counts and leave the mechanism out.

The Linux issue template asks for a full `--log-file` log from the failing run, the SteamOS release and the Mesa version. None of those were captured. They are marked TODO in the issue draft.

The patch below uses `p->allow_modeset &= ret != 0;`, while `dvbridge-master.patch` has `p->allow_modeset = ret != 0;`. Both clear the flag after a successful commit, which is what fixed the drops. They differ after a failed commit. `ret != 0` sets the flag even when it was clear, so a plain page flip that failed with EBUSY would make the next commit ask for a modeset. `&=` leaves the flag as it was, which is what 7b3a22a's message describes and what #18743 suggests. The measured build used `ret != 0`. Rebuild with `&=` and replay the Jellyfin 4K clip once before sending the patch anywhere.

## Comment for #18743

```markdown
A hardware data point for this. On a Radeon 780M (amdgpu, DCN 3.1.4) driving an LG TV at 3840x2160 60 Hz, `--vo=gpu-next --gpu-context=drm --gpu-api=opengl` on master a687796d dropped 863 of about 1800 frames in 30 seconds of a 60 fps HEVC clip. Changing that one line to `p->allow_modeset = ret != 0;` and nothing else took it to 0 drops. GPU time per frame was about the same both ways, 5.13 ms before and 4.78 ms after, and decode ran at about 240 fps. v0.41.0 played the same clip without drops. 23.976 Hz output at the same resolution never dropped, with or without the change.

The setup is not stock. The mpv build carries a local patch for a Dolby Vision output path, and the kernel runs a patched amdgpu module. The local mpv patch sets its properties once at init and doesn't touch `queue_flip()` or the per-frame request, but I haven't reproduced this on unpatched mpv with a stock module.

I can run #18744 on this machine at 60 Hz, HDR10 included, once the review changes are in.
```

## Issue text, only if #18743 is closed without a fix

Template: "Report a Linux issue". Title:

```text
context_drm_egl: every page flip asks for a modeset since 7b3a22a, drops frames at 60 Hz on amdgpu
```

### mpv Information

```text
TODO(Seth): output of `mpv -v --no-config` from the master a687796d build
```

### Other Information

```text
- Linux version: SteamOS TODO(Seth): release from /etc/os-release
- Kernel Version: 7.2.7-valve2-2-neptune-72, with a patched amdgpu.ko (see Actual Behavior)
- GPU Model: AMD Radeon 780M (Hawk Point, DCN 3.1.4), Minisforum UM870
- Mesa/GPU Driver Version: TODO(Seth)
- Window Manager and Version: none, mpv run from a VT with gamescope stopped
- Source of mpv: built from master a687796d, plus a local patch described below
- Latest known working version: v0.41.0
- Issue started after the following happened: 7b3a22a1540e3960cd5d2c240ac81e87de0412c9
```

### Reproduction Steps

```markdown
1. Stop the compositor and switch to a free VT on an amdgpu machine with a 3840x2160 60 Hz display.
2. Play a 3840x2160 60 fps clip with `mpv --vo=gpu-next --gpu-context=drm --gpu-api=opengl --drm-mode=3840x2160@60 --hwdec=vaapi --length=30 clip.mp4`.
3. Watch the dropped frame counter in the status line.
```

TODO(Seth): check those flags against what `dv-replay.sh` passed, minus the dvbridge options.

### Expected Behavior

```markdown
After the first flip, page flips are committed without `DRM_MODE_ATOMIC_ALLOW_MODESET`, as in v0.41.0, and a 60 fps clip plays at 60 Hz without dropped frames.
```

### Actual Behavior

```markdown
`queue_flip()` sets `p->allow_modeset = !ret;` after `drmModeAtomicCommit()`. That sets the flag after every successful commit, so from the first flip on every page flip carries `DRM_MODE_ATOMIC_ALLOW_MODESET`. The commit message of 7b3a22a says the flag should be cleared once the request is submitted and kept only for the retry of a failed commit.

On the hardware above, 30 seconds of a 3840x2160 60 fps HEVC clip at 60 Hz dropped 863 of about 1800 frames. With only that line changed to `p->allow_modeset = ret != 0;`, the same run dropped none. GPU time per frame was 5.13 ms before and 4.78 ms after, and both builds decode the clip at about 240 fps, so neither rendering nor decoding is the limit. v0.41.0 plays the clip without drops. 23.976 Hz output never dropped frames, with or without the change.

These numbers come from a build that is not stock. mpv carries a local patch that adds a Dolby Vision output path, and the kernel runs amdgpu with the LibreELEC Hades DVBRIDGE patches. The local mpv patch sets its connector and CRTC properties once at init and does not change `queue_flip()` or what goes into the per-frame request. I have not run unpatched mpv on a stock amdgpu module.
```

### Log File

TODO(Seth): attach the full `--log-file=output.txt` from the failing run. None was captured on 2 November.

### Sample Files

TODO(Seth): link to the Jellyfin 4K test clip used for the run.

## Patch

Built against master a687796d. The `index` line is the real blob of `context_drm_egl.c` at that commit.

```diff
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: shin2344234 <29849850+shin2344234@users.noreply.github.com>
Date: Mon, 2 Nov 2026 15:30:00 -0600
Subject: [PATCH] context_drm_egl: clear allow_modeset only after a successful
 commit

7b3a22a meant to clear allow_modeset once the request carrying the
colorspace change was submitted, and to leave it set after a failed
commit so the next one can retry. queue_flip() assigns it from !ret
instead, which sets the flag after every successful commit and clears
it after a failed one. Every page flip from the first one on then
carries DRM_MODE_ATOMIC_ALLOW_MODESET, and on amdgpu that drops frames
at 60 Hz.

Clear the flag when the commit succeeds and leave it alone when the
commit fails.

Fixes: #18743
Fixes: 7b3a22a1540e3960cd5d2c240ac81e87de0412c9
---
 video/out/opengl/context_drm_egl.c | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

diff --git a/video/out/opengl/context_drm_egl.c b/video/out/opengl/context_drm_egl.c
index 716d2911c26f..f8268862d086 100644
--- a/video/out/opengl/context_drm_egl.c
+++ b/video/out/opengl/context_drm_egl.c
@@ -338,7 +338,7 @@ static void queue_flip(struct ra_ctx *ctx, struct gbm_frame *frame)
     if (ret)
         MP_WARN(ctx->vo, "Failed to commit atomic request: %s\n", mp_strerror(ret));
     drm->waiting_for_flip = !ret;
-    p->allow_modeset = !ret;
+    p->allow_modeset &= ret != 0;
 
     drmModeAtomicFree(atomic_ctx->request);
     atomic_ctx->request = drmModeAtomicAlloc();
-- 
2.55.0
```
