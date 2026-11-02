"""Ports the hunks that the cumulative Hades diff could not apply to the Valve 7.2 tree.

Each hunk is taken from port2/all.rej as it is. Context lines that 7.2 does not have are
trimmed (head, tail) and 7.3 names are renamed to their 7.2 ones (ren), then the old side
of the hunk must occur exactly once in the 7.2 file and is replaced by the new side.
Usage: python3 -I fix2.py
"""
import shutil
import sys
from pathlib import Path

DV = Path("/home/deck/dev/dv")
SRC = DV / "src"
DM = "drivers/gpu/drm/amd/display/amdgpu_dm/"


def parse(rej):
    hunks, path, cur = {}, None, None
    for line in rej.read_text().split("\n"):
        if line.startswith("--- "):
            path = line[4:]
        elif line.startswith("+++ "):
            continue
        elif line.startswith("@@"):
            cur = []
            hunks[(path, line.split(" ")[1])] = cur
        elif cur is not None and line[:1] in (" ", "+", "-") or line == "":
            if cur is not None:
                cur.append(line)
    return hunks


HUNKS = parse(DV / "port2/all.rej")
used = set()


def sub(path, old, new):
    p = SRC / path
    data = p.read_text()
    if data.count(old) != 1:
        sys.exit(f"{path}: expected one match, found {data.count(old)}:\n{old}")
    p.write_text(data.replace(old, new))


def port(path, start, head=0, tail=0, ren=()):
    lines = HUNKS[(path, start)]
    used.add((path, start))
    while lines and lines[-1] == "":
        lines = lines[:-1]
    lines = lines[head:len(lines) - tail]
    old = "".join(line[1:] + "\n" for line in lines if line[:1] in (" ", "-") or line == "")
    new = "".join(line[1:] + "\n" for line in lines if line[:1] in (" ", "+") or line == "")
    for a, b in ren:
        old, new = old.replace(a, b), new.replace(a, b)
    sub(path, old, new)
    print(f"{path} {start}: ported")


def skip(path, start, why):
    used.add((path, start))
    print(f"{path} {start}: left out, {why}")


def added(path, start):
    used.add((path, start))
    return "".join(line[1:] + "\n" for line in HUNKS[(path, start)] if line[:1] == "+")


D = DM + "amdgpu_dm.c"

port("drivers/gpu/drm/amd/amdgpu/amdgpu_display.c", "-41,6", tail=2)
sub(DM + "Makefile", "\tamdgpu_dm_ism.o\n",
    "\tamdgpu_dm_ism.o \\\n\tamdgpu_dm_dvbridge_refused.o \\\n\tamdgpu_dm_hdmi_dolby.o\n")
used.add((DM + "Makefile", "-47,7"))
port(D, "-5370,6", head=3)
port(DM + "amdgpu_dm.h", "-902,6", tail=1,
     ren=[("\t/* HDMI compliance automation */\n\tbool hdmi_comp_auto;\n",
           "\t/* HDMI ALLM */\n\tbool hdmi_allm_capable;\n")])
port(D, "-32,6", head=2, tail=3)
sub(D, "#include <drm/drm_blend.h>\n",
    "#include <drm/drm_blend.h>\n" + "".join(
        line for line in added(D, "-58,6").splitlines(True) if "drm_blend" not in line))
skip(D, "-66,6", "7.2 already includes amdgpu_dm_dvbridge.h from the amdgpu_dm.c part")
skip(D, "-735,18", "7.2 has no Automatic-to-limited RGB rule (rgb_output_is_limited_range)")
port(D, "-871,6", head=2, ren=[("STATIC_IFN_KUNIT void fill_stream", "static void fill_stream")])
port(D, "-907,6", head=2,
     ren=[("amdgpu_dm_convert_color_depth_from_display_info", "convert_color_depth_from_display_info")])
port(D, "-945,7", ren=[("amdgpu_dm_is_freesync_video_mode", "is_freesync_video_mode")])
port(D, "-1457,6", head=2, tail=1,
     ren=[("STATIC_IFN_KUNIT struct dc_stream_state *", "static struct dc_stream_state *")])
port(D, "-1553,7", ren=[("amdgpu_dm_is_freesync_video_mode", "is_freesync_video_mode"),
                        ("amdgpu_dm_get_highest_refresh_rate_mode", "get_highest_refresh_rate_mode")])
port(D, "-1614,8", ren=[("mod_build_hf_vsif_infopacket(stream, &stream->vsp_infopacket, false, false);",
                         "mod_build_hf_vsif_infopacket(stream, &stream->hfvsif_infopacket);")])
for start in ("-2330,6", "-2361,6", "-2511,6"):
    skip(D, start, "HDR YCbCr 4:2:0/4:2:2 stream rule, needs the 7.3 encoding enumeration")
port(D, "-2672,10", ren=[("\tstruct drm_crtc *crtc;\n", "\tstruct drm_crtc *crtc = new_con_state->crtc;\n")])
port(D, "-2686,8", head=3)
sub(DM + "amdgpu_dm_crc.c", "#include \"amdgpu_dm_replay.h\"\n",
    "#include \"amdgpu_dm_replay.h\"\n" + added(DM + "amdgpu_dm_crc.c", "-34,6"))
sub("drivers/gpu/drm/amd/display/dc/dc_hw_types.h", "};\n#endif /* DC_HW_TYPES_H */",
    "};\n" + added("drivers/gpu/drm/amd/display/dc/dc_hw_types.h", "-1300,5") +
    "#endif /* DC_HW_TYPES_H */")
port("drivers/gpu/drm/amd/display/dc/hwss/dce110/dce110_hwseq.c", "-3223,10",
     ren=[("update_bits.", "update_flags.bits."),
          ("hwss_set_output_transfer_func(dc, pipe_ctx);",
           "hws->funcs.set_output_transfer_func(dc, pipe_ctx, pipe_ctx->stream);")])

# The Dolby InfoFrames that Hades adds to the built-in drivers/video/hdmi.c, module-local.
shutil.copy(DV / "extra/hdmi_dolby.h", SRC / "include/linux/hdmi_dolby.h")
shutil.copy(DV / "extra/amdgpu_dm_hdmi_dolby.c", SRC / DM / "amdgpu_dm_hdmi_dolby.c")
sub("include/drm/drm_dvbridge.h", "#include <linux/hdmi.h>\n",
    "#include <linux/hdmi.h>\n#include <linux/hdmi_dolby.h>\n")

# 7.2 has no "color format" connector property: user space cannot ask for another encoding
# than the driver picks. A YCbCr encoding forced in debugfs still ends in the scanout check.
sub(D, "\t/*\n"
    "\t * Hades: the \"color format\" property of Linux 7.3 chooses the pixel encoding of the stream\n"
    "\t * (amdgpu_dm_create_validate_stream_for_sink()): the tunnel is RGB, with it at AUTO or RGB.\n"
    "\t * Another value would end in the scanout check, named as a link limit (4:2:2 as TMDS, 4:2:0\n"
    "\t * as a mode taken in 4:2:0 only): it is refused here, for what it is.\n"
    "\t */\n"
    "\tif (con_state->color_format != DRM_CONNECTOR_COLOR_FORMAT_AUTO &&\n"
    "\t    con_state->color_format != DRM_CONNECTOR_COLOR_FORMAT_RGB444)\n"
    "\t\treturn -EINVAL;\n", "")
R = DM + "amdgpu_dm_dvbridge_refused.c"
p = SRC / R
data = p.read_text()
a = data.index("\t/* Hades: the \"color format\" property asks for another encoding than RGB */\n")
b = data.index("\tif (dm_state->scaling != RMX_OFF ||\n", a)
p.write_text(data[:a] + data[b:])
print(f"{R}: color format refusal left out")

# 7.3 groups the plane's shaper, 3D LUT and blend TF in dc_plane_state.cm; 7.2 keeps them
# on the plane, and its 3D LUT has no flags beside state.bits.initialized.
sub(D, "\t    dc_plane->cm.shaper_func.type != TF_TYPE_BYPASS ||\n"
    "\t    dc_plane->cm.blend_func.type != TF_TYPE_BYPASS ||\n"
    "\t    dc_plane->cm.flags.all || dc_plane->cm.lut3d_func.state.bits.initialized ||\n",
    "\t    dc_plane->in_shaper_func.type != TF_TYPE_BYPASS ||\n"
    "\t    dc_plane->blend_tf.type != TF_TYPE_BYPASS ||\n"
    "\t    dc_plane->lut3d_func.state.bits.initialized ||\n")
sub(D, "\t/* What DC will program for the plane (its shaper, 3D LUT and blend TF are in cm). */\n",
    "\t/* What DC will program for the plane, its shaper, 3D LUT and blend TF included. */\n")

# 7.3 builds the HDMI vendor packet into vsp_infopacket, where the Dolby VSIF replaces it.
# 7.2 builds it (HDMI VIC, 3D, ALLM) into hfvsif_infopacket, which DC sends from a slot of
# its own, so the tunnel has to empty that slot and keep it empty when ALLM changes.
sub(D, "\tstream->timing.vic = vic;\n"
    "\tstream->timing.hdmi_vic = 0;\n",
    "\tstream->timing.vic = vic;\n"
    "\tstream->timing.hdmi_vic = 0;\n"
    "\t/*\n"
    "\t * Linux 7.2 sends the HDMI vendor packet (HDMI VIC, 3D, ALLM) from a slot of its own,\n"
    "\t * hfvsif_infopacket, that create_stream_for_sink() has filled: empty it, so that the\n"
    "\t * Dolby VSIF goes out alone, as on 7.3, where the two share the vendor slot.\n"
    "\t */\n"
    "\tstream->hdmi_allm_active = false;\n"
    "\tmemset(&stream->hfvsif_infopacket, 0, sizeof(stream->hfvsif_infopacket));\n")
sub(D, "\t\t\tupdate_allm_state_on_crtc_stream(dm_new_crtc_state, new_con_state);\n"
    "\t\t\tmod_build_hf_vsif_infopacket(dm_new_crtc_state->stream,\n"
    "\t\t\t\t&dm_new_crtc_state->stream->hfvsif_infopacket);\n",
    "\t\t\tupdate_allm_state_on_crtc_stream(dm_new_crtc_state, new_con_state);\n"
    "\t\t\t/* A Dolby Vision tunnel sends no HDMI vendor packet beside its VSIF. */\n"
    "\t\t\tif (amdgpu_dm_dvbridge_stream_active(dm_new_crtc_state->stream))\n"
    "\t\t\t\tdm_new_crtc_state->stream->hdmi_allm_active = false;\n"
    "\t\t\telse\n"
    "\t\t\t\tmod_build_hf_vsif_infopacket(dm_new_crtc_state->stream,\n"
    "\t\t\t\t\t&dm_new_crtc_state->stream->hfvsif_infopacket);\n")

missing = set(HUNKS) - used
if missing:
    sys.exit(f"hunks not handled: {sorted(missing)}")
print("all rejects handled")
