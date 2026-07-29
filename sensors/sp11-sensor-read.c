/*
 * sp11-sensor-read — Fast sensor reader for Surface Pro 11
 *
 * Opens all sensors simultaneously via libssc, prints ONE reading
 * from each, then exits. ~0.5s instead of ssccli's 60s.
 *
 * Build: gcc -O2 -o sp11-sensor-read sp11-sensor-read.c $(pkg-config --cflags --libs libssc)
 * Usage: sp11-sensor-read [timeout_seconds]
 */

#include <glib.h>
#include <gio/gio.h>
#include <libssc.h>
#include <libssc-sensor-magnetometer.h>
#include <stdio.h>

static gint remaining = 0;
static GMainLoop *loop = NULL;

/* Track which sensors already reported */
static gboolean reported[5] = {FALSE};

#define SENSOR_ACCEL 0
#define SENSOR_GYRO  1
#define SENSOR_MAG   2
#define SENSOR_LIGHT 3
#define SENSOR_PROX  4

static void check_done(int id) {
    if (reported[id]) return;
    reported[id] = TRUE;
    if (--remaining <= 0) g_main_loop_quit(loop);
}

static void accel_cb(SSCSensorAccelerometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[SENSOR_ACCEL]) return;
    printf("Accelerometer  X=%.3f Y=%.3f Z=%.3f m/s²\n", x, y, z);
    check_done(SENSOR_ACCEL);
}
static void gyro_cb(SSCSensorGyroscope *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[SENSOR_GYRO]) return;
    printf("Gyroscope      X=%.4f Y=%.4f Z=%.4f rad/s\n", x, y, z);
    check_done(SENSOR_GYRO);
}
static void mag_cb(SSCSensorMagnetometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    if (reported[SENSOR_MAG]) return;
    printf("Magnetometer   X=%.1f Y=%.1f Z=%.1f uT\n", x, y, z);
    check_done(SENSOR_MAG);
}
static void light_cb(SSCSensorLight *s, gfloat v, gpointer u) {
    if (reported[SENSOR_LIGHT]) return;
    printf("Light          %.0f Lux\n", v);
    check_done(SENSOR_LIGHT);
}
static void prox_cb(SSCSensorProximity *s, gboolean near, gpointer u) {
    if (reported[SENSOR_PROX]) return;
    printf("Proximity      %s\n", near ? "NEAR" : "FAR");
    check_done(SENSOR_PROX);
}

static gboolean timeout_cb(gpointer u) {
    if (remaining > 0)
        fprintf(stderr, "%d sensor(s) did not report within timeout\n", remaining);
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char *argv[]) {
    GError *err = NULL;
    gint timeout = (argc > 1) ? atoi(argv[1]) : 8;

    remaining = 5;
    loop = g_main_loop_new(NULL, FALSE);

    SSCSensorAccelerometer *accel = ssc_sensor_accelerometer_new_sync(NULL, &err);
    if (accel) {
        g_signal_connect(accel, "measurement", G_CALLBACK(accel_cb), NULL);
        if (!ssc_sensor_accelerometer_open_sync(accel, NULL, &err)) { remaining--; g_clear_error(&err); }
    } else { remaining--; g_clear_error(&err); }

    SSCSensorGyroscope *gyro = ssc_sensor_gyroscope_new_sync(NULL, &err);
    if (gyro) {
        g_signal_connect(gyro, "measurement", G_CALLBACK(gyro_cb), NULL);
        if (!ssc_sensor_gyroscope_open_sync(gyro, NULL, &err)) { remaining--; g_clear_error(&err); }
    } else { remaining--; g_clear_error(&err); }

    SSCSensorMagnetometer *mag = ssc_sensor_magnetometer_new_sync(NULL, &err);
    if (mag) {
        g_signal_connect(mag, "measurement", G_CALLBACK(mag_cb), NULL);
        if (!ssc_sensor_magnetometer_open_sync(mag, NULL, &err)) { remaining--; g_clear_error(&err); }
    } else { remaining--; g_clear_error(&err); }

    SSCSensorLight *light = ssc_sensor_light_new_sync(NULL, &err);
    if (light) {
        g_signal_connect(light, "measurement", G_CALLBACK(light_cb), NULL);
        if (!ssc_sensor_light_open_sync(light, NULL, &err)) { remaining--; g_clear_error(&err); }
    } else { remaining--; g_clear_error(&err); }

    SSCSensorProximity *prox = ssc_sensor_proximity_new_sync(NULL, &err);
    if (prox) {
        g_signal_connect(prox, "measurement", G_CALLBACK(prox_cb), NULL);
        if (!ssc_sensor_proximity_open_sync(prox, NULL, &err)) { remaining--; g_clear_error(&err); }
    } else { remaining--; g_clear_error(&err); }

    if (remaining <= 0) {
        fprintf(stderr, "No sensors available\n");
        return 1;
    }

    g_timeout_add_seconds(timeout, timeout_cb, NULL);
    g_main_loop_run(loop);

    return (remaining > 0) ? 1 : 0;
}
