/*
 * sp11-sensor-read — Fast sensor reader for Surface Pro 11
 *
 * Opens requested sensors simultaneously via libssc, prints ONE reading
 * from each, then exits. ~1s instead of ssccli's 60s.
 *
 * Build: gcc -O2 -o sp11-sensor-read sp11-sensor-read.c $(pkg-config --cflags --libs libssc)
 *
 * Usage:
 *   sp11-sensor-read                    read all sensors (default)
 *   sp11-sensor-read accel              read accelerometer only
 *   sp11-sensor-read accel gyro mag     read specific sensors
 *   sp11-sensor-read all 8              read all with 8s timeout
 *
 * Sensor names: accel gyro mag light prox all
 */

#include <glib.h>
#include <gio/gio.h>
#include <libssc.h>
#include <libssc-sensor-magnetometer.h>
#include <stdio.h>
#include <string.h>

static gint remaining = 0;
static GMainLoop *loop = NULL;

/* Track which sensors already reported */
static gboolean reported[5] = {FALSE};

enum { ACCEL, GYRO, MAG, LIGHT, PROX };

/* Sensor name lookup */
static int sensor_id(const char *name) {
    if (!strcmp(name, "accel") || !strcmp(name, "accelerometer")) return ACCEL;
    if (!strcmp(name, "gyro")  || !strcmp(name, "gyroscope"))    return GYRO;
    if (!strcmp(name, "mag")   || !strcmp(name, "magnetometer")) return MAG;
    if (!strcmp(name, "light") || !strcmp(name, "als"))          return LIGHT;
    if (!strcmp(name, "prox")  || !strcmp(name, "proximity"))    return PROX;
    return -1;
}

static void check_done(int id) {
    if (reported[id]) return;
    reported[id] = TRUE;
    if (--remaining <= 0) g_main_loop_quit(loop);
}

/* Callbacks — fire on first measurement only */
static void accel_cb(SSCSensorAccelerometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[ACCEL]) return;
    printf("accel %.3f %.3f %.3f\n", x, y, z);
    check_done(ACCEL);
}
static void gyro_cb(SSCSensorGyroscope *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[GYRO]) return;
    printf("gyro %.4f %.4f %.4f\n", x, y, z);
    check_done(GYRO);
}
static void mag_cb(SSCSensorMagnetometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[MAG]) return;
    printf("mag %.1f %.1f %.1f\n", x, y, z);
    check_done(MAG);
}
static void light_cb(SSCSensorLight *s, gfloat v, gpointer u) {
    if (reported[LIGHT]) return;
    printf("light %.0f\n", v);
    check_done(LIGHT);
}
static void prox_cb(SSCSensorProximity *s, gboolean near, gpointer u) {
    if (reported[PROX]) return;
    printf("prox %s\n", near ? "near" : "far");
    check_done(PROX);
}

static gboolean timeout_cb(gpointer u) {
    if (remaining > 0)
        fprintf(stderr, "timed out: %d sensor(s) not reporting\n", remaining);
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char *argv[]) {
    GError *err = NULL;
    gint timeout = 10;
    gboolean want[5] = {FALSE};

    /* Parse args: sensor names + optional timeout (last numeric arg) */
    for (int i = 1; i < argc; i++) {
        int id = sensor_id(argv[i]);
        if (id >= 0) {
            want[id] = TRUE;
        } else if (!strcmp(argv[i], "all")) {
            memset(want, TRUE, sizeof(want));
        } else {
            /* Try parsing as timeout */
            char *end;
            long t = strtol(argv[i], &end, 10);
            if (*end == '\0' && t > 0) {
                timeout = (int)t;
            } else {
                fprintf(stderr, "Unknown sensor: %s\n", argv[i]);
                fprintf(stderr, "Usage: %s [accel gyro mag light prox all] [timeout]\n", argv[0]);
                return 2;
            }
        }
    }

    /* Default: all sensors */
    gboolean any = FALSE;
    for (int i = 0; i < 5; i++) any = any || want[i];
    if (!any) memset(want, TRUE, sizeof(want));

    /* Count requested */
    for (int i = 0; i < 5; i++) if (want[i]) remaining++;

    loop = g_main_loop_new(NULL, FALSE);

    /* Open each requested sensor */
    if (want[ACCEL]) {
        SSCSensorAccelerometer *s = ssc_sensor_accelerometer_new_sync(NULL, &err);
        if (s) {
            g_signal_connect(s, "measurement", G_CALLBACK(accel_cb), NULL);
            if (!ssc_sensor_accelerometer_open_sync(s, NULL, &err)) { remaining--; g_clear_error(&err); }
        } else { remaining--; fprintf(stderr, "accel: init failed\n"); g_clear_error(&err); }
    }
    if (want[GYRO]) {
        SSCSensorGyroscope *s = ssc_sensor_gyroscope_new_sync(NULL, &err);
        if (s) {
            g_signal_connect(s, "measurement", G_CALLBACK(gyro_cb), NULL);
            if (!ssc_sensor_gyroscope_open_sync(s, NULL, &err)) { remaining--; g_clear_error(&err); }
        } else { remaining--; fprintf(stderr, "gyro: init failed\n"); g_clear_error(&err); }
    }
    if (want[MAG]) {
        SSCSensorMagnetometer *s = ssc_sensor_magnetometer_new_sync(NULL, &err);
        if (s) {
            g_signal_connect(s, "measurement", G_CALLBACK(mag_cb), NULL);
            if (!ssc_sensor_magnetometer_open_sync(s, NULL, &err)) { remaining--; g_clear_error(&err); }
        } else { remaining--; fprintf(stderr, "mag: init failed\n"); g_clear_error(&err); }
    }
    if (want[LIGHT]) {
        SSCSensorLight *s = ssc_sensor_light_new_sync(NULL, &err);
        if (s) {
            g_signal_connect(s, "measurement", G_CALLBACK(light_cb), NULL);
            if (!ssc_sensor_light_open_sync(s, NULL, &err)) { remaining--; g_clear_error(&err); }
        } else { remaining--; fprintf(stderr, "light: init failed\n"); g_clear_error(&err); }
    }
    if (want[PROX]) {
        SSCSensorProximity *s = ssc_sensor_proximity_new_sync(NULL, &err);
        if (s) {
            g_signal_connect(s, "measurement", G_CALLBACK(prox_cb), NULL);
            if (!ssc_sensor_proximity_open_sync(s, NULL, &err)) { remaining--; g_clear_error(&err); }
        } else { remaining--; fprintf(stderr, "prox: init failed\n"); g_clear_error(&err); }
    }

    if (remaining <= 0) {
        fprintf(stderr, "No sensors available\n");
        return 1;
    }

    g_timeout_add_seconds(timeout, timeout_cb, NULL);
    g_main_loop_run(loop);

    return (remaining > 0) ? 1 : 0;
}
