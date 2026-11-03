// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * dvframe: shows one static Dolby Vision tunnel frame through the patched amdgpu
 * (connector property DVBRIDGE_DV_STANDARD_LAB), then puts the connector back.
 *
 *   dvframe show [seconds] [hz]   PQ grey ramp at 3840x2160, held for seconds (default 20)
 *   dvframe reset                 clears a tunnel left on by a run that died
 *
 * Run as root on a VT where no one else holds DRM master. The packing and the metadata
 * follow LibreELEC Hades (kodi-9990-native-dv.patch: pack_gles300.frag and
 * dvbridge_dv_metadata()): 12-bit limited BT.2020 Y'CbCr 4:2:2 from PQ RGB, R = C[11:4],
 * G = Y[11:4], B = C[3:0] << 4 | Y[3:0], one metadata bit per pixel in the chroma LSB.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define W 3840
#define H 2160

static int fd = -1;
static volatile sig_atomic_t stop;

static void on_signal(int sig) { (void)sig; stop = 1; }

/* Finds a property of an object by name; *pr is set when wanted and must be freed. */
static int find_prop(uint32_t obj, uint32_t type, const char *name, uint32_t *id,
		     uint64_t *val, drmModePropertyPtr *out)
{
	drmModeObjectProperties *p = drmModeObjectGetProperties(fd, obj, type);
	int found = -1;

	if (!p)
		return -1;
	for (uint32_t i = 0; i < p->count_props && found < 0; i++) {
		drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[i]);

		if (!pr)
			continue;
		if (!strcmp(pr->name, name)) {
			found = 0;
			if (id)
				*id = pr->prop_id;
			if (val)
				*val = p->prop_values[i];
			if (out) {
				*out = pr;
				pr = NULL;
			}
		}
		drmModeFreeProperty(pr);
	}
	drmModeFreeObjectProperties(p);
	return found;
}

/* Adds obj.name = value to the request. A missing optional property is skipped. */
static int add(drmModeAtomicReq *req, uint32_t obj, uint32_t type, const char *name,
	       uint64_t value, int required)
{
	uint32_t id;

	if (find_prop(obj, type, name, &id, NULL, NULL)) {
		if (required)
			fprintf(stderr, "missing required property %s on object %u\n", name, obj);
		return required ? -1 : 0;
	}
	return drmModeAtomicAddProperty(req, obj, id, value) < 0 ? -1 : 0;
}

/* Adds an enum property by the name of its value. */
static int add_enum(drmModeAtomicReq *req, uint32_t obj, uint32_t type, const char *name,
		    const char *value)
{
	drmModePropertyPtr pr = NULL;
	int ret = 0;

	if (find_prop(obj, type, name, NULL, NULL, &pr))
		return 0;
	for (int i = 0; i < pr->count_enums; i++)
		if (!strcmp(pr->enums[i].name, value)) {
			ret = drmModeAtomicAddProperty(req, obj, pr->prop_id, pr->enums[i].value) < 0;
			drmModeFreeProperty(pr);
			return ret ? -1 : 0;
		}
	fprintf(stderr, "%s has no value %s, left as it is\n", name, value);
	drmModeFreeProperty(pr);
	return 0;
}

/*
 * Puts every writable AMD private colour property of an object back to its default: blobs to
 * none, transfer functions to Default, the HDR multiplier to 1.0. Gamescope sets these (plane
 * degamma, shaper and blend, CRTC regamma) and they outlive its DRM master.
 */
static int add_amd_defaults(drmModeAtomicReq *req, uint32_t obj, uint32_t type)
{
	drmModeObjectProperties *p = drmModeObjectGetProperties(fd, obj, type);
	int ret = 0;

	if (!p)
		return -1;
	for (uint32_t i = 0; i < p->count_props && !ret; i++) {
		drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[i]);
		uint64_t v, want;

		if (!pr)
			continue;
		if (strncmp(pr->name, "AMD_", 4) || (pr->flags & DRM_MODE_PROP_IMMUTABLE)) {
			drmModeFreeProperty(pr);
			continue;
		}
		v = want = p->prop_values[i];
		if (drm_property_type_is(pr, DRM_MODE_PROP_BLOB))
			want = 0;
		else if (drm_property_type_is(pr, DRM_MODE_PROP_ENUM))
			for (int e = 0; e < pr->count_enums; e++)
				if (!strcmp(pr->enums[e].name, "Default"))
					want = pr->enums[e].value;
		if (!strcmp(pr->name, "AMD_PLANE_HDR_MULT"))
			want = 1ULL << 32;
		if (want != v) {
			printf("object %u: %s %llu -> %llu\n", obj, pr->name,
			       (unsigned long long)v, (unsigned long long)want);
			ret = drmModeAtomicAddProperty(req, obj, pr->prop_id, want) < 0;
		}
		drmModeFreeProperty(pr);
	}
	drmModeFreeObjectProperties(p);
	return ret ? -1 : 0;
}

static uint64_t range_max(uint32_t obj, uint32_t type, const char *name, uint64_t fallback)
{
	drmModePropertyPtr pr = NULL;
	uint64_t v = fallback;

	if (find_prop(obj, type, name, NULL, NULL, &pr))
		return fallback;
	if ((pr->flags & DRM_MODE_PROP_RANGE) && pr->count_values == 2)
		v = pr->values[1];
	drmModeFreeProperty(pr);
	return v;
}

static void print_refused(uint32_t conn)
{
	drmModePropertyPtr pr = NULL;
	uint64_t v = 0;

	if (find_prop(conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_REFUSED", NULL, &v, &pr)) {
		fprintf(stderr, "no DVBRIDGE_REFUSED property\n");
		return;
	}
	fprintf(stderr, "DVBRIDGE_REFUSED = 0x%llx:", (unsigned long long)v);
	for (int i = 0; i < pr->count_enums; i++)
		if (v & (1ULL << pr->enums[i].value))
			fprintf(stderr, " %s", pr->enums[i].name);
	fprintf(stderr, "\n");
	drmModeFreeProperty(pr);
}

struct pipe {
	uint32_t conn, crtc, primary;
	uint32_t others[16];
	int nothers;
	drmModeModeInfo mode;
	int have_mode;
};

static int find_pipe(struct pipe *p, int hz)
{
	drmModeRes *res = drmModeGetResources(fd);
	drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
	uint64_t v;
	int crtc_index = -1;

	memset(p, 0, sizeof(*p));
	if (!res || !pres)
		return -1;
	for (int i = 0; i < res->count_connectors && !p->conn; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);

		if (!c)
			continue;
		if (c->connection == DRM_MODE_CONNECTED &&
		    c->connector_type == DRM_MODE_CONNECTOR_HDMIA) {
			p->conn = c->connector_id;
			for (int m = 0; m < c->count_modes && hz; m++) {
				drmModeModeInfo *mi = &c->modes[m];

				if (mi->hdisplay == W && mi->vdisplay == H && (int)mi->vrefresh == hz &&
				    !(mi->flags & (DRM_MODE_FLAG_INTERLACE | DRM_MODE_FLAG_DBLSCAN))) {
					p->mode = *mi;
					p->have_mode = 1;
					break;
				}
			}
		}
		drmModeFreeConnector(c);
	}
	if (!p->conn) {
		fprintf(stderr, "no connected HDMI connector\n");
		return -1;
	}
	if (!find_prop(p->conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", NULL, &v, NULL) && v)
		p->crtc = v;
	else if (res->count_crtcs)
		p->crtc = res->crtcs[0];
	for (int i = 0; i < res->count_crtcs; i++)
		if (res->crtcs[i] == p->crtc)
			crtc_index = i;
	for (uint32_t i = 0; i < pres->count_planes; i++) {
		drmModePlane *pl = drmModeGetPlane(fd, pres->planes[i]);
		uint64_t type = 0, on = 0;

		if (!pl)
			continue;
		find_prop(pl->plane_id, DRM_MODE_OBJECT_PLANE, "type", NULL, &type, NULL);
		find_prop(pl->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", NULL, &on, NULL);
		if (!p->primary && type == DRM_PLANE_TYPE_PRIMARY && crtc_index >= 0 &&
		    (pl->possible_crtcs & (1u << crtc_index)))
			p->primary = pl->plane_id;
		else if (on == p->crtc && p->nothers < 16)
			p->others[p->nothers++] = pl->plane_id;
		drmModeFreePlane(pl);
	}
	drmModeFreePlaneResources(pres);
	drmModeFreeResources(res);
	printf("connector %u, crtc %u, primary plane %u, %d other plane(s) on the crtc\n",
	       p->conn, p->crtc, p->primary, p->nothers);
	return p->primary ? 0 : -1;
}

static int commit(drmModeAtomicReq *req, const char *what)
{
	if (drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, NULL)) {
		fprintf(stderr, "%s: test commit refused: %s\n", what, strerror(errno));
		return -1;
	}
	if (drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL)) {
		fprintf(stderr, "%s: commit failed: %s\n", what, strerror(errno));
		return -1;
	}
	return 0;
}

/* Exits 0 when a connected HDMI connector offers the tunnel property, so a player can choose it. */
static int probe(void)
{
	struct pipe p;

	if (find_pipe(&p, 0) && !p.conn)
		return 1;
	if (find_prop(p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", NULL, NULL, NULL)) {
		printf("no DVBRIDGE_DV_STANDARD_LAB on connector %u\n", p.conn);
		return 1;
	}
	printf("DVBRIDGE_DV_STANDARD_LAB on connector %u\n", p.conn);
	return 0;
}

/* Clears the tunnel on the connector. Tries the connector alone first, then turns the pipe off. */
static int reset(void)
{
	struct pipe p;
	uint64_t on = 0;
	drmModeAtomicReq *req;
	int ret;

	if (find_pipe(&p, 0) && !p.conn)
		return -1;
	if (find_prop(p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", NULL, &on, NULL)) {
		fprintf(stderr, "this amdgpu has no DVBRIDGE_DV_STANDARD_LAB\n");
		return -1;
	}
	if (!on) {
		printf("tunnel already off\n");
		return 0;
	}
	req = drmModeAtomicAlloc();
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", 0, 1);
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "max bpc",
	    range_max(p.conn, DRM_MODE_OBJECT_CONNECTOR, "max bpc", 16), 0);
	ret = commit(req, "reset");
	drmModeAtomicFree(req);
	if (!ret) {
		printf("tunnel cleared\n");
		return 0;
	}
	print_refused(p.conn);
	req = drmModeAtomicAlloc();
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", 0, 1);
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", 0, 1);
	add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 0, 1);
	add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", 0, 1);
	add(req, p.primary, DRM_MODE_OBJECT_PLANE, "FB_ID", 0, 1);
	add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0, 1);
	for (int i = 0; i < p.nothers; i++) {
		add(req, p.others[i], DRM_MODE_OBJECT_PLANE, "FB_ID", 0, 1);
		add(req, p.others[i], DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0, 1);
	}
	ret = commit(req, "reset with the pipe off");
	drmModeAtomicFree(req);
	printf(ret ? "tunnel still on\n" : "tunnel cleared, pipe off\n");
	return ret;
}

/* CRC-32/MPEG-2 as dvbridge_dv_crc(): MSB first, no reflection, no final XOR. */
static uint32_t dv_crc(const uint8_t *p, size_t n)
{
	uint32_t c = 0xffffffff;

	for (size_t j = 0; j < n; j++) {
		c ^= (uint32_t)p[j] << 24;
		for (int i = 0; i < 8; i++)
			c = (c << 1) ^ ((c >> 31) ? 0x04c11db7u : 0);
	}
	return c;
}

static void put16(uint8_t *b, size_t *n, unsigned v) { b[(*n)++] = v >> 8; b[(*n)++] = v; }
static void put32(uint8_t *b, size_t *n, unsigned v) { put16(b, n, v >> 16); put16(b, n, v & 65535); }

/* One 128-byte packet with the payload dvbridge_dv_metadata() writes for an L1 and a full-raster L5. */
static void build_packet(uint8_t pkt[128], unsigned min_pq, unsigned max_pq, unsigned avg_pq)
{
	static const int matrix[] = {9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0};
	static const unsigned lms[] = {7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962};
	uint8_t pl[128];
	size_t n = 0;
	uint32_t crc;

	pl[n++] = 0;
	pl[n++] = 1; /* scene refresh */
	for (int i = 0; i < 9; i++)
		put16(pl, &n, (uint16_t)matrix[i]);
	put32(pl, &n, 16777216);
	put32(pl, &n, 134217728);
	put32(pl, &n, 134217728);
	for (int i = 0; i < 9; i++)
		put16(pl, &n, lms[i]);
	put16(pl, &n, 65535);
	put32(pl, &n, 0);
	put32(pl, &n, 0);
	pl[n++] = 12;
	pl[n++] = 0;
	pl[n++] = 1;
	pl[n++] = 1;
	put16(pl, &n, 62);   /* source min PQ, 0.005 nits */
	put16(pl, &n, 3079); /* source max PQ, 1000 nits */
	put16(pl, &n, 42);
	pl[n++] = 2;         /* extension blocks: L1 and L5 */
	put32(pl, &n, 6);
	pl[n++] = 1;
	put16(pl, &n, min_pq);
	put16(pl, &n, max_pq);
	put16(pl, &n, avg_pq);
	put32(pl, &n, 8);
	pl[n++] = 5;
	for (int i = 0; i < 4; i++)
		put16(pl, &n, 0);

	memset(pkt, 0, 128);
	pkt[0] = 0; /* the only packet */
	pkt[1] = 0; /* id 0 */
	pkt[3] = n >> 8;
	pkt[4] = n;
	memcpy(pkt + 5, pl, n);
	crc = dv_crc(pkt, 124);
	for (int j = 0; j < 4; j++)
		pkt[124 + j] = crc >> (24 - j * 8);
	printf("metadata payload %zu bytes, crc 0x%08x, residual %u\n", n, crc, dv_crc(pkt, 128));
}

static unsigned parity(unsigned v)
{
	v ^= v >> 16;
	v ^= v >> 8;
	v ^= v >> 4;
	v ^= v >> 2;
	v ^= v >> 1;
	return v & 1;
}

/* PQ grey ramp, E from 0 at the left edge to EMAX at the right, packed as Hades packs it. */
#define EMAX 0.6
static void fill(uint32_t *px, uint32_t stride)
{
	uint8_t pkt[128];
	unsigned max_pq = (unsigned)(EMAX * 4095 + 0.5);

	build_packet(pkt, 0, max_pq, max_pq / 2);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			double e = EMAX * x / (W - 1);
			unsigned yy = (unsigned)(256.0 + 3504.0 * e + 0.5);
			unsigned c = 2048; /* grey: Cb = Cr = centre */
			unsigned index = (unsigned)y * W + x;

			if (index < 3072) {
				unsigned bit = index % 1024;
				unsigned value = (pkt[bit / 8] >> (7 - bit % 8)) & 1;

				c = (c & 4094) | (value ^ parity(c >> 1) ^ parity(yy));
			}
			px[(size_t)y * stride + x] = (c >> 4) << 16 | (yy >> 4) << 8 | ((yy & 15) | (c & 15) << 4);
		}
}

static int show(int seconds, int hz)
{
	struct pipe p;
	struct drm_mode_create_dumb cd = {.width = W, .height = H, .bpp = 32};
	struct drm_mode_map_dumb md = {0};
	uint32_t fb = 0, blob = 0, handles[4] = {0}, pitches[4] = {0}, offsets[4] = {0};
	uint64_t on = 1;
	uint32_t *px;
	drmModeAtomicReq *req;
	int ret = 1;

	if (find_pipe(&p, hz))
		return 1;
	if (!p.have_mode) {
		fprintf(stderr, "the TV offers no 3840x2160 progressive mode at %d Hz\n", hz);
		return 1;
	}
	if (find_prop(p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", NULL, &on, NULL)) {
		fprintf(stderr, "this amdgpu has no DVBRIDGE_DV_STANDARD_LAB\n");
		return 1;
	}
	if (on && reset())
		return 1;
	printf("mode %s %u Hz, clock %u kHz\n", p.mode.name, p.mode.vrefresh, p.mode.clock);

	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
		perror("create dumb buffer");
		return 1;
	}
	md.handle = cd.handle;
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
		perror("map dumb buffer");
		return 1;
	}
	px = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
	if (px == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	fill(px, cd.pitch / 4);
	handles[0] = cd.handle;
	pitches[0] = cd.pitch;
	if (drmModeAddFB2(fd, W, H, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &fb, 0)) {
		perror("add framebuffer");
		return 1;
	}
	if (drmModeCreatePropertyBlob(fd, &p.mode, sizeof(p.mode), &blob)) {
		perror("mode blob");
		return 1;
	}

	req = drmModeAtomicAlloc();
	if (add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", p.crtc, 1) ||
	    add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", 1, 1) ||
	    add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "HDR_OUTPUT_METADATA", 0, 0) ||
	    add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "max bpc", 8, 1) ||
	    add_enum(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "Colorspace", "Default") ||
	    add_enum(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "Broadcast RGB", "Full") ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", blob, 1) ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 1, 1) ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "CTM", 0, 0) ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "GAMMA_LUT", 0, 0) ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "DEGAMMA_LUT", 0, 0) ||
	    add(req, p.crtc, DRM_MODE_OBJECT_CRTC, "VRR_ENABLED", 0, 0) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "FB_ID", fb, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_ID", p.crtc, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "SRC_X", 0, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "SRC_Y", 0, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "SRC_W", (uint64_t)W << 16, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "SRC_H", (uint64_t)H << 16, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_X", 0, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_Y", 0, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_W", W, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "CRTC_H", H, 1) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "rotation", DRM_MODE_ROTATE_0, 0) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "alpha", 65535, 0) ||
	    add(req, p.primary, DRM_MODE_OBJECT_PLANE, "COLOR_PIPELINE", 0, 0) ||
	    add_enum(req, p.primary, DRM_MODE_OBJECT_PLANE, "pixel blend mode", "None") ||
	    add_amd_defaults(req, p.crtc, DRM_MODE_OBJECT_CRTC) ||
	    add_amd_defaults(req, p.primary, DRM_MODE_OBJECT_PLANE)) {
		fprintf(stderr, "could not build the tunnel commit\n");
		goto out;
	}
	for (int i = 0; i < p.nothers; i++) {
		add(req, p.others[i], DRM_MODE_OBJECT_PLANE, "FB_ID", 0, 1);
		add(req, p.others[i], DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0, 1);
	}
	if (commit(req, "tunnel")) {
		print_refused(p.conn);
		drmModeAtomicFree(req);
		goto out;
	}
	drmModeAtomicFree(req);
	printf("tunnel on, holding %d s\n", seconds);
	fflush(stdout);
	for (int i = 0; i < seconds * 10 && !stop; i++) {
		struct timespec ts = {0, 100000000};

		nanosleep(&ts, NULL);
	}
	ret = 0;

	/* Back to an ordinary black frame with the tunnel off, as Hades' EndDVBridge does. */
	memset(px, 0, cd.size);
	req = drmModeAtomicAlloc();
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "DVBRIDGE_DV_STANDARD_LAB", 0, 1);
	add(req, p.conn, DRM_MODE_OBJECT_CONNECTOR, "max bpc",
	    range_max(p.conn, DRM_MODE_OBJECT_CONNECTOR, "max bpc", 16), 0);
	if (commit(req, "restore")) {
		print_refused(p.conn);
		ret = reset() ? 2 : 0;
	} else {
		printf("tunnel off\n");
	}
	drmModeAtomicFree(req);
out:
	if (fb)
		drmModeRmFB(fd, fb);
	if (blob)
		drmModeDestroyPropertyBlob(fd, blob);
	return ret;
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "show";
	int ret;

	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/dri/card0");
		return 1;
	}
	/* probe only reads properties, which needs no master, and gamescope may hold it. */
	if (strcmp(cmd, "probe"))
		drmSetMaster(fd);
	if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
	    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
		perror("atomic client caps");
		return 1;
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGHUP, on_signal);
	if (!strcmp(cmd, "reset"))
		ret = reset();
	else if (!strcmp(cmd, "probe"))
		ret = probe();
	else if (!strcmp(cmd, "show"))
		ret = show(argc > 2 ? atoi(argv[2]) : 20, argc > 3 ? atoi(argv[3]) : 24);
	else {
		fprintf(stderr, "usage: dvframe show [seconds] [hz] | dvframe reset | dvframe probe\n");
		ret = 1;
	}
	close(fd);
	return ret;
}
