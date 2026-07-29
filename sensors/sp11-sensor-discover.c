/*
 * sp11-sensor-discover — List every SSC sensor on a Surface Pro 11 and verify
 * that each one produces data.
 *
 * Why two modes: probing several sensors inside a single process corrupts the
 * shared libssc client state — later SUID lookups fail even for sensors that
 * work fine in isolation (verified 2026-07-29). So the parent spawns one fresh
 * child process per sensor. Each child probes exactly one sensor and prints a
 * machine-readable verdict; the parent aggregates them into the table.
 *
 *   sp11-sensor-discover                  aggregate: probe all, print table
 *   sp11-sensor-discover --probe-one T    worker: probe one sensor, print verdict
 *
 * The candidate list holds only sensors verified to produce data on this SSC.
 * Removed (no SUID, or registered but open fails — verified 2026-07-29):
 *   proximity, linear_accel, pressure, significant_motion,
 *   flat, device_orient, hinge_angle, step_detect, tilt, amd
 * Re-add any of these here only after a confirmed DATA reading.
 *
 * Build: gcc -O2 -o sp11-sensor-discover sp11-sensor-discover.c $(pkg-config --cflags --libs libssc)
 */

#include <glib.h>
#include <gio/gio.h>
#include <libssc.h>
#include <libssc-sensor-accelerometer.h>
#include <libssc-sensor-gyroscope.h>
#include <libssc-sensor-magnetometer.h>
#include <libssc-sensor-light.h>
#include <libssc-sensor-compass.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>

typedef enum { K_ACCEL, K_GYRO, K_MAG, K_LIGHT, K_COMPASS, K_GENERIC } Kind;

typedef struct { const char *name; Kind kind; } Probe;

/* The 13 sensors verified to produce data on this SSC. */
static Probe probes[] = {
    { "accel",     K_ACCEL   },
    { "gyro",      K_GYRO    },
    { "mag",       K_MAG     },
    { "light",     K_LIGHT   },
    { "compass",   K_COMPASS },
    { "gravity",   K_GENERIC },
    { "rotv",      K_GENERIC },
    { "geomag_rv", K_GENERIC },
    { "game_rv",   K_GENERIC },
    { "color",     K_GENERIC },
    { "fmv",       K_GENERIC },
    { "rmd",       K_GENERIC },
    { "sar",       K_GENERIC },
};
static const int n_probes = (int)(sizeof(probes) / sizeof(probes[0]));

/* Per-probe state (worker mode, single sensor) */
static GMainLoop *probe_loop = NULL;
static gboolean   created, opened, got_data, resolved;
static int        got_bytes;
static guint64    cur_uh, cur_ul;
static gpointer   cur_sensor;     /* SSCSensor* (base), for cleanup */

/* ── resolution helper ──────────────────────────────────────────────── */
static void cb_resolve(void) {
    if (resolved) return;
    resolved = TRUE;
    if (probe_loop) g_main_loop_quit(probe_loop);
}
static gboolean on_probe_timeout(gpointer u) { (void)u; cb_resolve(); return G_SOURCE_REMOVE; }

/* ── data callbacks ─────────────────────────────────────────────────── */
static void cb_float(GObject *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    (void)s; (void)x; (void)y; (void)z; (void)u; got_data = TRUE; cb_resolve();
}
static void cb_double(GObject *s, gdouble v, gpointer u) {
    (void)s; (void)v; (void)u; got_data = TRUE; cb_resolve();
}
static void cb_report(GObject *c, guint msg_id, guint64 uh, guint64 ul,
                      GArray *data, gpointer u) {
    (void)c; (void)msg_id; (void)u;
    if (uh == cur_uh && ul == cur_ul && data && !got_data) {
        got_data = TRUE; got_bytes = data->len;
    }
    cb_resolve();
}

/* ── generic async path ─────────────────────────────────────────────── */
static void open_cb(GObject *obj, GAsyncResult *res, gpointer u) {
    GError *err = NULL;
    if (ssc_sensor_open_finish(SSC_SENSOR(obj), res, &err)) opened = TRUE;
    g_clear_error(&err);
    if (!opened) cb_resolve();
}
static void new_cb(GObject *obj, GAsyncResult *res, gpointer u) {
    GError *err = NULL;
    SSCSensor *s = ssc_sensor_new_finish(res, &err);
    g_clear_error(&err);
    if (!s) { created = FALSE; cb_resolve(); return; }   /* no SUID */
    created = TRUE; cur_sensor = s;
    g_object_get(s, "uid-high", &cur_uh, "uid-low", &cur_ul, NULL);
    GObject *client = NULL;
    g_object_get(s, SSC_SENSOR_CLIENT, &client, NULL);
    if (client) g_signal_connect(client, "report", G_CALLBACK(cb_report), NULL);
    ssc_sensor_open(s, NULL, open_cb, NULL);
}

/* ── dedicated sync path ────────────────────────────────────────────── */
static gpointer open_dedicated(Kind k) {
    GError *err = NULL;
    gpointer s = NULL;
    switch (k) {
    case K_ACCEL: { SSCSensorAccelerometer *a = ssc_sensor_accelerometer_new_sync(NULL, &err);
        if (a) { created = TRUE; s = a; g_signal_connect(a, "measurement", G_CALLBACK(cb_float), NULL);
            opened = ssc_sensor_accelerometer_open_sync(a, NULL, &err); } break; }
    case K_GYRO: { SSCSensorGyroscope *g = ssc_sensor_gyroscope_new_sync(NULL, &err);
        if (g) { created = TRUE; s = g; g_signal_connect(g, "measurement", G_CALLBACK(cb_float), NULL);
            opened = ssc_sensor_gyroscope_open_sync(g, NULL, &err); } break; }
    case K_MAG: { SSCSensorMagnetometer *m = ssc_sensor_magnetometer_new_sync(NULL, &err);
        if (m) { created = TRUE; s = m; g_signal_connect(m, "measurement", G_CALLBACK(cb_float), NULL);
            opened = ssc_sensor_magnetometer_open_sync(m, NULL, &err); } break; }
    case K_LIGHT: { SSCSensorLight *l = ssc_sensor_light_new_sync(NULL, &err);
        if (l) { created = TRUE; s = l; g_signal_connect(l, "measurement", G_CALLBACK(cb_double), NULL);
            opened = ssc_sensor_light_open_sync(l, NULL, &err); } break; }
    case K_COMPASS: { SSCSensorCompass *c = ssc_sensor_compass_new_sync(NULL, &err);
        if (c) { created = TRUE; s = c; g_signal_connect(c, "measurement", G_CALLBACK(cb_double), NULL);
            opened = ssc_sensor_compass_open_sync(c, NULL, &err); } break; }
    default: break;
    }
    g_clear_error(&err);
    if (!opened && s) { g_object_unref(s); s = NULL; cur_sensor = NULL; }
    else if (s) cur_sensor = s;
    return s;
}
static void close_current(Kind k) {
    if (!cur_sensor) return;
    switch (k) {
    case K_ACCEL:   ssc_sensor_accelerometer_close_sync((SSCSensorAccelerometer *)cur_sensor, NULL, NULL); break;
    case K_GYRO:    ssc_sensor_gyroscope_close_sync((SSCSensorGyroscope *)cur_sensor, NULL, NULL); break;
    case K_MAG:     ssc_sensor_magnetometer_close_sync((SSCSensorMagnetometer *)cur_sensor, NULL, NULL); break;
    case K_LIGHT:   ssc_sensor_light_close_sync((SSCSensorLight *)cur_sensor, NULL, NULL); break;
    case K_COMPASS: ssc_sensor_compass_close_sync((SSCSensorCompass *)cur_sensor, NULL, NULL); break;
    default: break;   /* generic: rely on finalize (process exits immediately) */
    }
    g_object_unref(cur_sensor);
    cur_sensor = NULL;
}

/* ── single-sensor probe (worker) ───────────────────────────────────── */
typedef enum { V_DATA, V_NO_SUID, V_OPEN_FAIL, V_NODATA } Verdict;

static Verdict probe_one(Probe *p) {
    created = opened = got_data = resolved = FALSE;
    got_bytes = 0; cur_uh = cur_ul = 0; cur_sensor = NULL;

    gboolean wait = TRUE;
    if (p->kind == K_GENERIC)
        ssc_sensor_new((gchar *)p->name, NULL, new_cb, NULL);
    else
        wait = (open_dedicated(p->kind) != NULL);   /* non-NULL iff opened */

    if (wait && !resolved) {
        probe_loop = g_main_loop_new(NULL, FALSE);
        guint to = g_timeout_add_seconds(4, on_probe_timeout, NULL);
        g_main_loop_run(probe_loop);
        g_source_remove(to);
        g_main_loop_unref(probe_loop);
        probe_loop = NULL;
    }

    Verdict v;
    if (got_data)        v = V_DATA;
    else if (!created)   v = V_NO_SUID;
    else if (!opened)    v = V_OPEN_FAIL;
    else                 v = V_NODATA;
    close_current(p->kind);
    return v;
}

static Probe *find_probe(const char *name) {
    for (int i = 0; i < n_probes; i++)
        if (!strcmp(probes[i].name, name)) return &probes[i];
    return NULL;
}

/* Worker: probe one sensor, print machine-readable verdict. */
static int worker_main(const char *name) {
    setvbuf(stdout, NULL, _IONBF, 0);
    Probe *p = find_probe(name);
    if (!p) { printf("UNKNOWN\n"); return 2; }
    Verdict v = probe_one(p);
    switch (v) {
    case V_DATA:      printf("DATA %d\n", got_bytes); break;
    case V_NO_SUID:   printf("NO_SUID\n"); break;
    case V_OPEN_FAIL: printf("OPEN_FAIL\n"); break;
    case V_NODATA:    printf("NODATA\n"); break;
    }
    return 0;
}

/* ── aggregate parent ───────────────────────────────────────────────── */
static gchar *self_exe(void) {
    gchar buf[PATH_MAX];
    gssize n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return NULL;
    buf[n] = '\0';
    return g_strdup(buf);
}

static gchar *run_child(const gchar *exe, const char *type) {
    gchar *argv[] = { (gchar *)exe, (gchar *)"--probe-one", (gchar *)type, NULL };
    gchar *out = NULL;
    gint status;
    GError *err = NULL;
    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_STDERR_TO_DEV_NULL,
                      NULL, NULL, &out, NULL, &status, &err)) {
        g_error_free(err);
        return NULL;
    }
    if (out) g_strchomp(out);
    return out;
}

static int aggregate_main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    gchar *exe = self_exe();
    if (!exe) { fprintf(stderr, "cannot resolve own executable path\n"); return 1; }

    printf("Probing %d SSC sensors (one fresh process each)...\n\n", n_probes);
    int n_data = 0, n_reg = 0;
    for (int i = 0; i < n_probes; i++) {
        Probe *p = &probes[i];
        gchar *res = run_child(exe, p->name);
        if (res && g_str_has_prefix(res, "DATA")) {
            int b = atoi(res + 4);
            if (b > 0) printf("  \u2713 %-20s DATA (%d bytes)\n", p->name, b);
            else       printf("  \u2713 %-20s DATA\n", p->name);
            n_data++;
        } else if (res && !strcmp(res, "NO_SUID")) {
            printf("  \u2717 %-20s no SUID\n", p->name);
        } else if (res && !strcmp(res, "OPEN_FAIL")) {
            printf("  \u2717 %-20s open failed\n", p->name);
        } else if (res && !strcmp(res, "NODATA")) {
            printf("  \u00b7 %-20s registered (no data)\n", p->name);
            n_reg++;
        } else {
            printf("  ? %-20s (probe failed)\n", p->name);
        }
        g_free(res);
    }
    g_free(exe);
    printf("\n%d producing data, %d registered (no spontaneous data)\n", n_data, n_reg);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc >= 3 && !strcmp(argv[1], "--probe-one"))
        return worker_main(argv[2]);
    return aggregate_main();
}
