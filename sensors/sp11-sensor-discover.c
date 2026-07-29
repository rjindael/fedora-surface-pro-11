/*
 * sp11-sensor-discover — List ALL sensors available on the SSC
 *
 * Queries the Snapdragon Sensor Core for every known SNS data type.
 * Reports which sensors are registered and their SUIDs.
 *
 * Build: gcc -O2 -o sp11-sensor-discover sp11-sensor-discover.c $(pkg-config --cflags --libs libssc)
 */

#include <glib.h>
#include <gio/gio.h>
#include <libssc.h>
#include <stdio.h>

/* All known SNS data types from Qualcomm/AOSP source */
static const char * const data_types[] = {
    /* Core motion sensors */
    "accel", "gyro", "mag",
    "gravity", "linear_accel",
    "rotv", "geomag_rv", "game_rv",
    "orientation",
    /* Environmental */
    "light", "proximity", "pressure", "humidity", "ambient_temp",
    "color",
    /* Activity / gesture */
    "step_count", "step_detect", "significant_motion",
    "tilt", "flat", "device_orient",
    "amd", "fmv", "rmd",
    /* Other */
    "sar", "hinge_angle",
    "compass",
    NULL
};

static GMainLoop *loop = NULL;
static int idx = 0;
static int found = 0;

static void try_next(void);

static void sensor_new_cb(GObject *obj, GAsyncResult *res, gpointer user_data) {
    const char *dt = data_types[idx];
    GError *err = NULL;

    SSCSensor *sensor = ssc_sensor_new_finish(res, &err);
    if (sensor) {
        /* Get SUID properties */
        guint64 uid_high = 0, uid_low = 0;
        g_object_get(sensor,
            "uid-high", &uid_high,
            "uid-low", &uid_low,
            NULL);
        printf("  ✓ %-20s  SUID: %lu %lu\n", dt, uid_high, uid_low);
        found++;
        g_object_unref(sensor);
    } else {
        g_clear_error(&err);
    }

    idx++;
    try_next();
}

static void try_next(void) {
    if (data_types[idx] == NULL) {
        printf("\n%d sensor type(s) available\n", found);
        g_main_loop_quit(loop);
        return;
    }
    ssc_sensor_new((gchar *)data_types[idx], NULL, sensor_new_cb, NULL);
}

int main(int argc, char *argv[]) {
    printf("Discovering sensors via SUID lookup...\n\n");
    loop = g_main_loop_new(NULL, FALSE);
    try_next();
    g_main_loop_run(loop);
    return 0;
}
