#!/bin/bash
# Builds FFmpeg n8.0.1 with Plezy's common patch series, as the libmpv window
# prefix has it, plus the dovi_split bitstream filter that mpv master needs to
# pull a profile 7 EL out of a single HEVC track. dovi_split is only in
# FFmpeg master (31 May 2026), so its source comes from the commit pinned
# below, dovi_split-n8.0.1.patch takes out its use of the HEVC configuration
# side data that n8.0.1 lacks, and the three registration lines are added
# here. The patch must sit next to this script. Installs static
# libraries to their own prefix, leaving Plezy's FFmpeg as it is. The
# configure flags are mpv-build's Linux ones with dovi_split in the BSF list.
# Run inside plezy-build.
set -euo pipefail

SPLIT_COMMIT=8828574c98
P=/home/deck/dev/plezy/build/libmpv-window/prefix
B=/home/deck/dev/plezy/build/libmpv-window/mpv-build/patches/ffmpeg
D=/home/deck/dev/dvmpv
FF="$D/ff-prefix"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$P/lib/x86_64-linux-gnu/pkgconfig"

cd "$D"
if [ ! -d ffmpeg/.git ]; then
  git init -q ffmpeg
  git -C ffmpeg fetch -q --depth 1 https://github.com/FFmpeg/FFmpeg.git \
    894da5ca7d742e4429ffb2af534fcda0103ef593
  git -C ffmpeg checkout -q FETCH_HEAD
  cd ffmpeg
  for f in $(grep -v '^#' "$B/series.common" | grep .); do
    git apply "$B/pool/$f"
  done
  curl -fsSL -o libavcodec/bsf/dovi_split.c \
    "https://raw.githubusercontent.com/FFmpeg/FFmpeg/$SPLIT_COMMIT/libavcodec/bsf/dovi_split.c"
  git apply "$D/dovi_split-n8.0.1.patch"
  sed -i '/^dovi_rpu_bsf_select=/a dovi_split_bsf_select="hevcparse"' configure
  sed -i '/ff_dovi_rpu_bsf;/a extern const FFBitStreamFilter ff_dovi_split_bsf;' \
    libavcodec/bitstream_filters.c
  sed -i '/CONFIG_DOVI_RPU_BSF)/a OBJS-$(CONFIG_DOVI_SPLIT_BSF)             += bsf/dovi_split.o' \
    libavcodec/bsf/Makefile
  [ "$(grep -c dovi_split configure libavcodec/bitstream_filters.c libavcodec/bsf/Makefile |
       awk -F: '{s += $2} END {print s}')" -eq 3 ] || { echo "dovi_split not registered" >&2; exit 1; }
  cd ..
fi
cd ffmpeg

./configure \
  --prefix="$FF" \
  --enable-gpl \
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --disable-programs \
  --disable-doc \
  --disable-encoders \
  --disable-muxers \
  --enable-muxer=spdif \
  --disable-devices \
  --disable-bsfs \
  --enable-bsf=aac_adtstoasc,av1_metadata,dovi_split,extract_extradata,h264_metadata,h264_mp4toannexb,hevc_metadata,hevc_mp4toannexb,vp9_metadata \
  --disable-filters \
  --enable-filter=aformat,aresample,bwdif,decimate,fieldmatch,format,loudnorm,null,scale \
  --enable-gnutls \
  --enable-vaapi \
  --enable-ffnvcodec \
  --enable-nvdec \
  --enable-libdav1d \
  --disable-vdpau \
  --enable-debug=1 \
  --disable-stripping
grep -q 'CONFIG_DOVI_SPLIT_BSF 1' config_components.h
make -j"$(nproc)"
make install
