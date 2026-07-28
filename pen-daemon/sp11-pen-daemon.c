// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Surface Pro 11 OLED G6 HEAT-to-uinput hybrid Pen & Touch auto-switching daemon.
 * Protects hardware finger multi-touch gestures while providing automatic pen switching.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <linux/hidraw.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <glob.h>

#define SP11_VENDOR 0x045e
#define SP11_PRODUCT 0x0c83
#define MAX_REPORT 8192

static volatile sig_atomic_t stopping;

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

#define SP11_MIN_ENERGY 5000.0
#define SP11_PRESENCE_ENERGY 8000.0
#define SP11_TOUCH_ENERGY 120000.0
#define SP11_PRESSURE_MAX_ENERGY 1080000.0

/* Auto-switch timeout: 1.0 seconds of pen inactivity restores finger touch mode */
#define SP11_AUTO_TOUCH_DELAY_MS 1000
/* Hold finger touch mode continuously for 500ms after finger touch activity */
#define SP11_FINGER_ACTIVE_HOLD_MS 500

static int energy_to_pressure(double energy)
{
	if (energy <= SP11_TOUCH_ENERGY)
		return 1;
	if (energy >= SP11_PRESSURE_MAX_ENERGY)
		return 4095;
	return 1 + (int)lround((energy - SP11_TOUCH_ENERGY) * 4094.0 /
			       (SP11_PRESSURE_MAX_ENERGY - SP11_TOUCH_ENERGY));
}

static double array_energy(const uint8_t *data, int count)
{
	double total = 0.0;
	for (int i = 0; i < count; i++) {
		total += le32(data + i * 4);
	}
	return total;
}

static bool weighted_centroid(const uint8_t *data, int count, double *out)
{
	double total_weight = 0.0, weighted_sum = 0.0;
	for (int i = 0; i < count; i++) {
		double value = le32(data + i * 4);
		total_weight += value;
		weighted_sum += i * value;
	}
	if (total_weight < SP11_MIN_ENERGY)
		return false;
	*out = weighted_sum / total_weight;
	return true;
}

static int64_t monotonic_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_signal(int signal_number)
{
	(void)signal_number;
	stopping = 1;
}

static int open_touchscreen_event_device(void)
{
	glob_t globbuf;
	int found_fd = -1;

	if (glob("/dev/input/event*", 0, NULL, &globbuf) == 0) {
		for (size_t i = 0; i < globbuf.gl_pathc; i++) {
			int fd = open(globbuf.gl_pathv[i], O_RDONLY | O_NONBLOCK);
			if (fd >= 0) {
				char name[256] = {0};
				if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0) {
					if (strstr(name, "Touchscreen") || strstr(name, "045E:0C83")) {
						found_fd = fd;
						fprintf(stderr, "Found Touchscreen event node: %s (%s)\n",
							globbuf.gl_pathv[i], name);
						break;
					}
				}
				close(fd);
			}
		}
		globfree(&globbuf);
	}
	return found_fd;
}

static int set_heat(int fd, bool enabled)
{
	uint8_t feature[2] = {0x05, enabled ? 0x01 : 0x00};

	if (ioctl(fd, HIDIOCSFEATURE(sizeof(feature)), feature) < 0) {
		perror(enabled ? "enable HEAT" : "disable HEAT");
		return -1;
	}
	return 0;
}

static int set_abs(int fd, uint16_t code, int minimum, int maximum,
		   int resolution)
{
	struct uinput_abs_setup abs_setup = {
		.code = code,
		.absinfo = {
			.minimum = minimum,
			.maximum = maximum,
			.resolution = resolution,
		},
	};

	return ioctl(fd, UI_ABS_SETUP, &abs_setup);
}

static int create_uinput(void)
{
	struct uinput_setup setup = {
		.id = {
			.bustype = BUS_VIRTUAL,
			.vendor = SP11_VENDOR,
			.product = SP11_PRODUCT,
			.version = 1,
		},
	};
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);

	if (fd < 0) {
		perror("open /dev/uinput");
		return -1;
	}
	snprintf(setup.name, sizeof(setup.name), "SP11 G6 Virtual Stylus");

#define SET_IOCTL(request, value) \
	do { \
		if (ioctl(fd, request, value) < 0) { \
			perror(#request); \
			close(fd); \
			return -1; \
		} \
	} while (0)

	SET_IOCTL(UI_SET_EVBIT, EV_KEY);
	SET_IOCTL(UI_SET_EVBIT, EV_ABS);
	SET_IOCTL(UI_SET_PROPBIT, INPUT_PROP_DIRECT);
	SET_IOCTL(UI_SET_PROPBIT, INPUT_PROP_POINTER);
	SET_IOCTL(UI_SET_KEYBIT, BTN_TOUCH);
	SET_IOCTL(UI_SET_KEYBIT, BTN_STYLUS);
	SET_IOCTL(UI_SET_KEYBIT, BTN_TOOL_PEN);
	SET_IOCTL(UI_SET_KEYBIT, BTN_TOOL_RUBBER);
	SET_IOCTL(UI_SET_ABSBIT, ABS_X);
	SET_IOCTL(UI_SET_ABSBIT, ABS_Y);
	SET_IOCTL(UI_SET_ABSBIT, ABS_PRESSURE);
	SET_IOCTL(UI_SET_ABSBIT, ABS_MISC);
#undef SET_IOCTL

	if (set_abs(fd, ABS_X, 0, 9600, 34) < 0 ||
	    set_abs(fd, ABS_Y, 0, 7200, 39) < 0 ||
	    set_abs(fd, ABS_PRESSURE, 0, 4095, 0) < 0 ||
	    set_abs(fd, ABS_MISC, 0, 65535, 0) < 0 ||
	    ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
	    ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("configure uinput");
		close(fd);
		return -1;
	}
	return fd;
}

static int emit_event(int fd, uint16_t type, uint16_t code, int32_t value)
{
	struct input_event event = {
		.type = type,
		.code = code,
		.value = value,
	};

	return write(fd, &event, sizeof(event)) == sizeof(event) ? 0 : -1;
}

static void emit_lift(int fd)
{
	emit_event(fd, EV_KEY, BTN_TOUCH, 0);
	emit_event(fd, EV_KEY, BTN_TOOL_PEN, 0);
	emit_event(fd, EV_ABS, ABS_PRESSURE, 0);
	emit_event(fd, EV_SYN, SYN_REPORT, 0);
}

struct pen_sample {
	int x;
	int y;
	int pressure;
	uint16_t scan_time;
	bool valid;
	bool contact;
};

static void output_sample(int ui_fd, bool dry_run,
			  const struct pen_sample *sample)
{
	if (dry_run) {
		printf("x=%d y=%d pressure=%d contact=%d time=%u\n",
		       sample->x, sample->y, sample->pressure, sample->contact,
		       sample->scan_time);
		return;
	}
	emit_event(ui_fd, EV_KEY, BTN_TOOL_PEN, sample->contact);
	emit_event(ui_fd, EV_KEY, BTN_TOUCH, sample->contact);
	emit_event(ui_fd, EV_ABS, ABS_X, sample->x);
	emit_event(ui_fd, EV_ABS, ABS_Y, sample->y);
	emit_event(ui_fd, EV_ABS, ABS_PRESSURE, sample->pressure);
	emit_event(ui_fd, EV_SYN, SYN_REPORT, 0);
}

static bool parse_ff00(const uint8_t *payload, size_t length,
		       struct pen_sample *sample)
{
	size_t offset = 0;
	bool have_position = false;
	bool have_contact = false;
	bool raw_contact_bit = false;
	double signal_energy = -1.0;

	while (offset + 4 <= length) {
		uint8_t type = payload[offset];
		uint16_t size = le16(payload + offset + 2);
		const uint8_t *data = payload + offset + 4;

		if (offset + 4 + size > length)
			return false;
		if (type == 0x5b && size == 464) {
			uint8_t x0 = data[0], y0 = data[1];
			uint8_t x1 = data[2], y1 = data[3];

			signal_energy = array_energy(data + 8, 46) +
					array_energy(data + 192, 68);
			if (x0 < 68 && x1 < 68 && y0 < 46 && y1 < 46 &&
			    signal_energy > SP11_PRESENCE_ENERGY) {
				double px = -24.0 + 72.0 * ((double)x0 + x1);
				double py = (225.0 + 315.0 * ((double)y0 + y1)) / 4.0;
				double c46, c68;

				if (weighted_centroid(data + 8, 46, &c46) &&
				    weighted_centroid(data + 192, 68, &c68)) {
					px = 38.609 + 142.080 * c46;
					py = -3466.93 + 158.341 * c68;
				}

				sample->x = (int)lround(px);
				sample->y = (int)lround(py);
				if (sample->x < 0) sample->x = 0;
				if (sample->x > 9600) sample->x = 9600;
				if (sample->y < 0) sample->y = 0;
				if (sample->y > 7200) sample->y = 7200;
				have_position = true;
			}
		} else if (type == 0x62 && size == 16) {
			raw_contact_bit = data[11] == 0;
			have_contact = true;
		}
		offset += 4 + size;
	}

	sample->valid = have_position;
	sample->contact = raw_contact_bit && signal_energy >= SP11_TOUCH_ENERGY;
	sample->pressure = sample->contact ? energy_to_pressure(signal_energy) : 0;
	return have_position && have_contact;
}

static bool parse_report(const uint8_t *report, size_t length,
			 struct pen_sample *sample)
{
	const uint8_t *capimg;
	uint32_t declared, top_length;
	size_t offset;

	memset(sample, 0, sizeof(*sample));
	/* Accept both 0x0c and 0x08 report IDs */
	if (length < 14 || (report[0] != 0x0c && report[0] != 0x08))
		return false;
	sample->scan_time = le16(report + 1);
	declared = le32(report + 3);
	if (declared < 7 || declared > length - 3)
		return false;
	capimg = report + 3;
	top_length = le32(capimg);
	if (top_length < 7 || top_length > declared || le16(capimg + 4) != 0)
		return false;

	for (offset = 7; offset + 7 <= top_length;) {
		uint32_t section_length = le32(capimg + offset);
		uint16_t section_type = le16(capimg + offset + 4);

		if (section_length < 7 || offset + section_length > top_length)
			return false;
		if (section_type == 0xff00)
			return parse_ff00(capimg + offset + 7,
					  section_length - 7, sample);
		offset += section_length;
	}
	return false;
}

enum daemon_mode {
	MODE_TOUCH,
	MODE_PEN
};

int main(int argc, char **argv)
{
	const char *device = "/dev/sp11-pen";
	bool dry_run = false;
	uint8_t report[MAX_REPORT];
	int hid_fd, touch_fd = -1, ui_fd = -1;
	bool active = false;
	enum daemon_mode mode = MODE_TOUCH;
	int64_t last_pen_activity = 0;
	int64_t last_finger_activity = 0;
	int previous_x = 0, previous_y = 0, stable = 0;
	int emitted_x = 0, emitted_y = 0, emitted_pressure = 0;
	bool emitted_contact = false, have_emitted = false, have_pending = false;
	bool changed_x = false, changed_y = false;
	bool raw_contact = false, debounced_contact = false;
	int contact_stable = 0;
	int64_t pending_since = 0;
	struct pen_sample pending = {0};

	if (argc > 1 && strcmp(argv[1], "--dry-run") == 0) {
		dry_run = true;
		if (argc > 2) device = argv[2];
	} else if (argc > 1) {
		device = argv[1];
	}

	hid_fd = open(device, O_RDWR | O_CLOEXEC);
	if (hid_fd < 0) {
		perror(device);
		return EXIT_FAILURE;
	}
	touch_fd = open_touchscreen_event_device();
	if (!dry_run) {
		ui_fd = create_uinput();
		if (ui_fd < 0) {
			close(hid_fd);
			if (touch_fd >= 0) close(touch_fd);
			return EXIT_FAILURE;
		}
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	/* Ensure starting in FINGER TOUCH MODE */
	set_heat(hid_fd, false);
	fprintf(stderr, "Hybrid Auto-Switch Daemon started; FINGER TOUCH MODE active on %s\n", device);

	while (!stopping) {
		int64_t now = monotonic_ms();

		/* Drain finger touch events to monitor finger touch activity */
		if (touch_fd >= 0) {
			struct input_event evs[64];
			ssize_t r = read(touch_fd, evs, sizeof(evs));
			if (r > 0) {
				last_finger_activity = now;
			}
		}

		if (mode == MODE_TOUCH) {
			/* If finger touch is actively being used, do NOT probe to protect multi-touch gestures */
			if (now - last_finger_activity < SP11_FINGER_ACTIVE_HOLD_MS) {
				set_heat(hid_fd, false);
				usleep(50000); // 50ms smooth sleep
				continue;
			}

			/* Finger touch is idle: run 25ms probe for pen presence */
			struct pollfd pollfd = {.fd = hid_fd, .events = POLLIN};
			set_heat(hid_fd, true);
			int res = poll(&pollfd, 1, 25);
			if (res > 0 && (pollfd.revents & POLLIN)) {
				struct pen_sample sample;
				ssize_t size = read(hid_fd, report, sizeof(report));
				if (size > 0 && parse_report(report, (size_t)size, &sample) && sample.valid) {
					mode = MODE_PEN;
					last_pen_activity = now;
					fprintf(stderr, "Auto-switching to PEN MODE (HEAT enabled)\n");
					output_sample(ui_fd, dry_run, &sample);
					emitted_x = sample.x;
					emitted_y = sample.y;
					emitted_contact = sample.contact;
					emitted_pressure = sample.pressure;
					have_emitted = true;
					continue;
				}
			}
			/* No valid pen signal detected, return digitizer to Finger Touch mode */
			set_heat(hid_fd, false);
			usleep(100000); // 100ms window
		} else if (mode == MODE_PEN) {
			/* Pen mode: read active pen stream */
			struct pollfd pollfd = {.fd = hid_fd, .events = POLLIN};
			int res = poll(&pollfd, 1, 40);

			if (now - last_pen_activity > SP11_AUTO_TOUCH_DELAY_MS) {
				if (active && !dry_run)
					emit_lift(ui_fd);
				active = false;
				stable = 0;
				have_emitted = false;
				have_pending = false;
				changed_x = changed_y = false;
				contact_stable = 0;
				raw_contact = debounced_contact = false;

				set_heat(hid_fd, false);
				mode = MODE_TOUCH;
				fprintf(stderr, "Pen inactive for %.1fs -> Auto-switching to FINGER TOUCH MODE\n",
					SP11_AUTO_TOUCH_DELAY_MS / 1000.0);
				continue;
			}

			if (res > 0 && (pollfd.revents & POLLIN)) {
				struct pen_sample sample;
				ssize_t size = read(hid_fd, report, sizeof(report));

				if (size < 0) {
					if (errno == EINTR) continue;
					perror("read hidraw");
					break;
				}
				if (!parse_report(report, (size_t)size, &sample))
					continue;

				if (sample.valid)
					last_pen_activity = now;

				if (abs(sample.x - previous_x) <= 600 &&
				    abs(sample.y - previous_y) <= 600)
					stable++;
				else
					stable = 1;
				previous_x = sample.x;
				previous_y = sample.y;
				if (stable < 3) continue;

				if (sample.contact == raw_contact) {
					contact_stable++;
				} else {
					raw_contact = sample.contact;
					contact_stable = 1;
				}
				if (contact_stable >= 3)
					debounced_contact = raw_contact;
				sample.contact = debounced_contact;
				active = true;

				if (!have_emitted) {
					output_sample(ui_fd, dry_run, &sample);
					emitted_x = sample.x;
					emitted_y = sample.y;
					emitted_contact = sample.contact;
					emitted_pressure = sample.pressure;
					have_emitted = true;
					continue;
				}
				if (sample.contact != emitted_contact) {
					output_sample(ui_fd, dry_run, &sample);
					emitted_x = sample.x;
					emitted_y = sample.y;
					emitted_contact = sample.contact;
					emitted_pressure = sample.pressure;
					have_pending = false;
					changed_x = changed_y = false;
					continue;
				}
				if (sample.x == emitted_x && sample.y == emitted_y) {
					if (sample.pressure != emitted_pressure) {
						output_sample(ui_fd, dry_run, &sample);
						emitted_pressure = sample.pressure;
					}
					have_pending = false;
					changed_x = changed_y = false;
					continue;
				}
				if (!have_pending) {
					pending_since = now;
					changed_x = changed_y = false;
				}
				pending = sample;
				have_pending = true;
				changed_x = changed_x || sample.x != emitted_x;
				changed_y = changed_y || sample.y != emitted_y;

				if ((changed_x && changed_y) ||
				    now - pending_since >= 25) {
					output_sample(ui_fd, dry_run, &pending);
					emitted_x = pending.x;
					emitted_y = pending.y;
					emitted_contact = pending.contact;
					emitted_pressure = pending.pressure;
					have_pending = false;
					changed_x = changed_y = false;
				}
			}
		}
	}

	if (active && !dry_run)
		emit_lift(ui_fd);
	set_heat(hid_fd, false);
	fprintf(stderr, "HEAT disabled\n");
	if (touch_fd >= 0) close(touch_fd);
	if (ui_fd >= 0) { ioctl(ui_fd, UI_DEV_DESTROY); close(ui_fd); }
	close(hid_fd);
	return EXIT_SUCCESS;
}
