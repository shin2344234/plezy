// Decodes the first frames of a file and runs them through dvbridge.h, the
// same checks and serializer vo_gpu_next uses for the tunnel, so a file the
// tunnel would refuse shows up without the TV.
// Usage: dvtest file [frames] [start seconds]
#include <stdio.h>
#include <stdlib.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>

#include "dvbridge.h"

static void report(struct dvbridge_dv *dv, const AVFrame *f, int n)
{
    const AVFrameSideData *sd = av_frame_get_side_data(f, AV_FRAME_DATA_DOVI_METADATA);
    if (!sd) {
        printf("  frame %d: no DOVI metadata\n", n);
        return;
    }
    const AVDOVIMetadata *m = (const AVDOVIMetadata *)sd->data;
    if (!dvbridge_dv_bounds(m, sd->size)) {
        printf("  frame %d: bounds check failed\n", n);
        return;
    }
    const AVDOVIRpuDataHeader *h = av_dovi_get_header(m);
    const AVDOVIColorMetadata *c = av_dovi_get_color(m);
    char levels[256] = "";
    for (int i = 0; i < m->num_ext_blocks; i++)
        snprintf(levels + strlen(levels), sizeof(levels) - strlen(levels), "%s%d",
                 i ? "," : "", av_dovi_get_ext(m, i)->level);
    // Fit the picture into 3840x2160 the way mpv letterboxes it.
    int w = f->width, hh = f->height, dw = DVBRIDGE_W, dh = DVBRIDGE_H;
    if ((long)w * DVBRIDGE_H > (long)hh * DVBRIDGE_W)
        dh = (int)lround((double)hh * DVBRIDGE_W / w);
    else
        dw = (int)lround((double)w * DVBRIDGE_H / hh);
    int x = (DVBRIDGE_W - dw) / 2, y = (DVBRIDGE_H - dh) / 2;
    bool geo = dvbridge_dv_geometry(dv, w, hh, x, y, dw, dh);
    bool meta = geo && dvbridge_dv_metadata(dv, m, n / 24.0);
    printf("  frame %d: residual off %d, mel %d, colour space %d, eotf %d, pq %d-%d,"
           " levels [%s]: %s, %u bytes in %u packets, margins %u %u %u %u, %u CM v4.0 left out\n",
           n, h->disable_residual_flag, !h->disable_residual_flag && dvbridge_dovi_is_mel(m),
           c->signal_color_space, c->signal_eotf, c->source_min_pq, c->source_max_pq, levels,
           !geo ? "geometry refused" : meta ? "accepted" : "metadata refused",
           dv->size, dv->count, dv->margins[0], dv->margins[1], dv->margins[2],
           dv->margins[3], dv->cm4_omitted);
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    int want = argc > 2 ? atoi(argv[2]) : 3;
    AVFormatContext *fmt = NULL;
    // HTTP headers for a Plex URL, e.g. the X-Plex-Token line.
    AVDictionary *opts = NULL;
    if (getenv("DVTEST_HEADERS"))
        av_dict_set(&opts, "headers", getenv("DVTEST_HEADERS"), 0);
    if (avformat_open_input(&fmt, argv[1], NULL, &opts) < 0 ||
        avformat_find_stream_info(fmt, NULL) < 0)
        return 1;
    const AVCodec *codec = NULL;
    int idx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (idx < 0)
        return 1;
    if (argc > 3)
        avformat_seek_file(fmt, -1, INT64_MIN, (int64_t)(atof(argv[3]) * AV_TIME_BASE),
                           INT64_MAX, 0);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(ctx, fmt->streams[idx]->codecpar);
    if (avcodec_open2(ctx, codec, NULL) < 0)
        return 1;
    struct dvbridge_dv dv = {0};
    AVPacket *pkt = av_packet_alloc();
    AVFrame *f = av_frame_alloc();
    int n = 0;
    while (n < want && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == idx && avcodec_send_packet(ctx, pkt) >= 0) {
            while (n < want && avcodec_receive_frame(ctx, f) >= 0) {
                report(&dv, f, n++);
                av_frame_unref(f);
            }
        }
        av_packet_unref(pkt);
    }
    return 0;
}
