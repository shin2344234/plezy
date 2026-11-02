// SPDX-License-Identifier: MIT
/*
 * The pack side of the Dolby Vision vendor InfoFrames that LibreELEC Hades adds to
 * drivers/video/hdmi.c (linux-9899 and linux-9993), copied here unchanged because that file is
 * built into this kernel. The unpack and log side stays out: nothing in amdgpu reads frames.
 *
 * Copyright (C) 2012 Avionic Design GmbH, and the LibreELEC Hades authors.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 * and associated documentation files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sub license, and/or sell copies of the Software, and to permit persons to whom
 * the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next paragraph) shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 * BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NON-INFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <linux/bits.h>
#include <linux/errno.h>
#include <linux/string.h>

#include <linux/hdmi_dolby.h>

#define HDMI_DOLBY_FRAME_SIZE		HDMI_INFOFRAME_SIZE(DOLBY_VENDOR)
#define HDMI_DOLBY_HDMI14B_FRAME_SIZE	HDMI_INFOFRAME_SIZE(DOLBY_HDMI14B)
/* where payload byte PB<n> is in a packed frame (the checksum, PB0, is byte 3) */
#define HDMI_DOLBY_PB(n)		(HDMI_INFOFRAME_HEADER_SIZE - 1 + (n))

#define HDMI_DOLBY_PB4_LOW_LATENCY	BIT(0)
#define HDMI_DOLBY_PB4_SIGNAL		BIT(1)
#define HDMI_DOLBY_PB5_L11		BIT(5)
#define HDMI_DOLBY_PB5_AUXILIARY	BIT(6)
#define HDMI_DOLBY_PB5_BACKLIGHT	BIT(7)

#define HDMI_DOLBY_HDMI14B_EXTENDED	0x20	/* PB4: extended resolution format */
#define HDMI_DOLBY_HDMI14B_VIC_MAX	4	/* 4096x2160p24, the last HDMI VIC */

/* hdmi_infoframe_set_checksum() of drivers/video/hdmi.c, which is static there */
static void hdmi_dolby_set_checksum(void *buffer, size_t size)
{
	u8 *ptr = buffer;
	u8 csum = 0;
	size_t i;

	ptr[3] = 0;
	for (i = 0; i < size; i++)
		csum += ptr[i];
	ptr[3] = 256 - csum;
}

void hdmi_dolby_vendor_infoframe_init(struct hdmi_dolby_vendor_infoframe *frame)
{
	memset(frame, 0, sizeof(*frame));

	frame->type = HDMI_INFOFRAME_TYPE_VENDOR;
	frame->version = 1;
	frame->length = HDMI_DOLBY_VENDOR_INFOFRAME_SIZE;
	frame->oui = HDMI_DOLBY_IEEE_OUI;
}

int hdmi_dolby_vendor_infoframe_check(const struct hdmi_dolby_vendor_infoframe *frame)
{
	const unsigned int l11_nibbles = frame->content_type | frame->content_subtype |
					 frame->intended_white_point | frame->crf;

	if (frame->type != HDMI_INFOFRAME_TYPE_VENDOR || frame->version != 1 ||
	    frame->length != HDMI_DOLBY_VENDOR_INFOFRAME_SIZE ||
	    frame->oui != HDMI_DOLBY_IEEE_OUI)
		return -EINVAL;

	/* every field fits its bits */
	if (frame->effective_tmax_pq > 0xfff || l11_nibbles > 0xf)
		return -EINVAL;

	/* low latency and the metadata blocks only with the signal */
	if (!frame->signal && (frame->low_latency || frame->backlight_present ||
			       frame->auxiliary_present || frame->l11_present))
		return -EINVAL;

	/* and the bytes of each block only with its flag */
	if (!frame->backlight_present && frame->effective_tmax_pq)
		return -EINVAL;
	if (!frame->auxiliary_present &&
	    (frame->auxiliary_runmode | frame->auxiliary_version | frame->auxiliary_debug))
		return -EINVAL;
	if (!frame->l11_present && (l11_nibbles | frame->l11_byte2 | frame->l11_byte3))
		return -EINVAL;

	return 0;
}

ssize_t hdmi_dolby_vendor_infoframe_pack(const struct hdmi_dolby_vendor_infoframe *frame,
					 void *buffer, size_t size)
{
	u8 *ptr = buffer;
	int ret;

	ret = hdmi_dolby_vendor_infoframe_check(frame);
	if (ret)
		return ret;

	if (size < HDMI_DOLBY_FRAME_SIZE)
		return -ENOSPC;

	memset(buffer, 0, size);

	ptr[0] = frame->type;
	ptr[1] = frame->version;
	ptr[2] = frame->length;
	ptr[3] = 0; /* checksum */

	/* the OUI, the least significant byte first */
	ptr[HDMI_DOLBY_PB(1)] = HDMI_DOLBY_IEEE_OUI & 0xff;
	ptr[HDMI_DOLBY_PB(2)] = (HDMI_DOLBY_IEEE_OUI >> 8) & 0xff;
	ptr[HDMI_DOLBY_PB(3)] = (HDMI_DOLBY_IEEE_OUI >> 16) & 0xff;

	ptr[HDMI_DOLBY_PB(4)] = (frame->low_latency ? HDMI_DOLBY_PB4_LOW_LATENCY : 0) |
				(frame->signal ? HDMI_DOLBY_PB4_SIGNAL : 0);
	ptr[HDMI_DOLBY_PB(5)] = (frame->effective_tmax_pq >> 8) |
				(frame->l11_present ? HDMI_DOLBY_PB5_L11 : 0) |
				(frame->auxiliary_present ? HDMI_DOLBY_PB5_AUXILIARY : 0) |
				(frame->backlight_present ? HDMI_DOLBY_PB5_BACKLIGHT : 0);
	ptr[HDMI_DOLBY_PB(6)] = frame->effective_tmax_pq & 0xff;
	ptr[HDMI_DOLBY_PB(7)] = frame->auxiliary_runmode;
	ptr[HDMI_DOLBY_PB(8)] = frame->auxiliary_version;
	ptr[HDMI_DOLBY_PB(9)] = frame->auxiliary_debug;
	ptr[HDMI_DOLBY_PB(10)] = frame->content_type | (frame->content_subtype << 4);
	ptr[HDMI_DOLBY_PB(11)] = frame->intended_white_point | (frame->crf << 4);
	ptr[HDMI_DOLBY_PB(12)] = frame->l11_byte2;
	ptr[HDMI_DOLBY_PB(13)] = frame->l11_byte3;
	/* PB14-PB27 stay zero */

	hdmi_dolby_set_checksum(buffer, HDMI_DOLBY_FRAME_SIZE);

	return HDMI_DOLBY_FRAME_SIZE;
}

void hdmi_dolby_hdmi14b_infoframe_init(struct hdmi_dolby_hdmi14b_infoframe *frame)
{
	memset(frame, 0, sizeof(*frame));

	frame->type = HDMI_INFOFRAME_TYPE_VENDOR;
	frame->version = 1;
	frame->length = HDMI_DOLBY_HDMI14B_INFOFRAME_SIZE;
	frame->oui = HDMI_IEEE_OUI;
}

int hdmi_dolby_hdmi14b_infoframe_check(const struct hdmi_dolby_hdmi14b_infoframe *frame)
{
	if (frame->type != HDMI_INFOFRAME_TYPE_VENDOR || frame->version != 1 ||
	    frame->length != HDMI_DOLBY_HDMI14B_INFOFRAME_SIZE || frame->oui != HDMI_IEEE_OUI)
		return -EINVAL;

	if (frame->hdmi_vic > HDMI_DOLBY_HDMI14B_VIC_MAX)
		return -EINVAL;

	return 0;
}

ssize_t hdmi_dolby_hdmi14b_infoframe_pack(const struct hdmi_dolby_hdmi14b_infoframe *frame,
					  void *buffer, size_t size)
{
	u8 *ptr = buffer;
	int ret;

	ret = hdmi_dolby_hdmi14b_infoframe_check(frame);
	if (ret)
		return ret;

	if (size < HDMI_DOLBY_HDMI14B_FRAME_SIZE)
		return -ENOSPC;

	memset(buffer, 0, size);

	ptr[0] = frame->type;
	ptr[1] = frame->version;
	ptr[2] = frame->length;
	ptr[3] = 0; /* checksum */

	/* the OUI, the least significant byte first */
	ptr[HDMI_DOLBY_PB(1)] = HDMI_IEEE_OUI & 0xff;
	ptr[HDMI_DOLBY_PB(2)] = (HDMI_IEEE_OUI >> 8) & 0xff;
	ptr[HDMI_DOLBY_PB(3)] = (HDMI_IEEE_OUI >> 16) & 0xff;

	if (frame->hdmi_vic) {
		ptr[HDMI_DOLBY_PB(4)] = HDMI_DOLBY_HDMI14B_EXTENDED;
		ptr[HDMI_DOLBY_PB(5)] = frame->hdmi_vic;
	}
	/* PB6-PB24 stay zero */

	hdmi_dolby_set_checksum(buffer, HDMI_DOLBY_HDMI14B_FRAME_SIZE);

	return HDMI_DOLBY_HDMI14B_FRAME_SIZE;
}
