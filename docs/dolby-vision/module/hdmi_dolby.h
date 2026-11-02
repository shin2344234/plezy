/* SPDX-License-Identifier: MIT */
/*
 * The Dolby Vision vendor InfoFrames of LibreELEC Hades (linux-9899 and linux-9993), kept in
 * a module for a kernel whose drivers/video/hdmi.c is built in and does not have them. The
 * structures stay out of union hdmi_vendor_any_infoframe so that no structure shared with the
 * built-in kernel changes size.
 *
 * Copyright (C) 2012 Avionic Design GmbH, and the LibreELEC Hades authors. Offered under the
 * permission notice of drivers/video/hdmi.c.
 */
#ifndef _LINUX_HDMI_DOLBY_H
#define _LINUX_HDMI_DOLBY_H

#include <linux/hdmi.h>
#include <linux/types.h>

#define HDMI_DOLBY_IEEE_OUI 0x00d046
#define HDMI_DOLBY_VENDOR_INFOFRAME_SIZE 27
#define HDMI_DOLBY_HDMI14B_INFOFRAME_SIZE 24

struct hdmi_dolby_vendor_infoframe {
	enum hdmi_infoframe_type type;
	unsigned char version;
	unsigned char length;
	unsigned int oui;
	bool signal;
	bool low_latency;
	bool backlight_present;
	bool auxiliary_present;
	bool l11_present;
	u16 effective_tmax_pq;
	u8 auxiliary_runmode;
	u8 auxiliary_version;
	u8 auxiliary_debug;
	u8 content_type;
	u8 content_subtype;
	u8 intended_white_point;
	u8 crf;
	u8 l11_byte2;
	u8 l11_byte3;
};

void hdmi_dolby_vendor_infoframe_init(struct hdmi_dolby_vendor_infoframe *frame);
int hdmi_dolby_vendor_infoframe_check(const struct hdmi_dolby_vendor_infoframe *frame);
ssize_t hdmi_dolby_vendor_infoframe_pack(const struct hdmi_dolby_vendor_infoframe *frame,
					 void *buffer, size_t size);

struct hdmi_dolby_hdmi14b_infoframe {
	enum hdmi_infoframe_type type;
	unsigned char version;
	unsigned char length;
	unsigned int oui;
	u8 hdmi_vic;
};

void hdmi_dolby_hdmi14b_infoframe_init(struct hdmi_dolby_hdmi14b_infoframe *frame);
int hdmi_dolby_hdmi14b_infoframe_check(const struct hdmi_dolby_hdmi14b_infoframe *frame);
ssize_t hdmi_dolby_hdmi14b_infoframe_pack(const struct hdmi_dolby_hdmi14b_infoframe *frame,
					  void *buffer, size_t size);

#endif /* _LINUX_HDMI_DOLBY_H */
