/*
 * sp11-sensor-read — Sensor reader for Surface Pro 11 (all 13 working sensors)
 *
 * Reads every SSC sensor verified to produce data on this hardware. Physical
 * sensors (accel/gyro/mag/light/compass) use libssc's dedicated classes; the
 * remaining working sensors use the generic report path, parsing the value
 * where the byte layout is known (gravity/fmv = vec3, rotv/geomag_rv/game_rv =
 * quaternion, rmd = state) and dumping raw bytes where it isn't (sar/color —
 * their libssc-decoded payload has no published schema).
 *
 * Why subprocesses: opening more than one generic sensor in a single process
 * corrupts the shared libssc client (later SUID lookups fail). So the parent
 * spawns one fresh child per sensor and relays its single-line reading.
 *
 *   sp11-sensor-read                  read all 13 sensors
 *   sp11-sensor-read accel compass    read specific sensors
 *   sp11-sensor-read all 8            all sensors, 8s timeout each
 *   sp11-sensor-read --read-one T [s] worker: read one sensor, print its value
 *
 * Build: gcc -O2 -o sp11-sensor-read sp11-sensor-read.c $(pkg-config --cflags --libs libssc)
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

typedef enum {
    K_ACCEL, K_GYRO, K_MAG, K_LIGHT, K_COMPASS,
    K_VEC3,    /* gravity, fmv            → 3 floats (x y z)         */
    K_QUAT,    /* rotv, geomag_rv, game_rv → 4 floats (x y z w)      */
    K_VARINT,  /* rmd                     → 1 state varint           */
    K_RAW      /* sar, color              → raw bytes (no schema)    */
} Kind;

typedef struct { const char *name; Kind kind; } Probe;

static Probe probes[] = {
    { "accel",     K_ACCEL   },
    { "gyro",      K_GYRO    },
    { "mag",       K_MAG     },
    { "light",     K_LIGHT   },
    { "compass",   K_COMPASS },
    { "gravity",   K_VEC3    },
    { "fmv",       K_VEC3    },
    { "rotv",      K_QUAT    },
    { "geomag_rv", K_QUAT    },
    { "game_rv",   K_QUAT    },
    { "rmd",       K_VARINT  },
    { "sar",       K_RAW     },
    { "color",     K_RAW     },
};
static const int n_probes = (int)(sizeof(probes) / sizeof(probes[0]));

static Probe *find_probe(const char *name) {
    for (int i = 0; i < n_probes; i++)
        if (!strcmp(probes[i].name, name)) return &probes[i];
    return NULL;
}

/* ── worker (one sensor, fresh process) ─────────────────────────────── */
static GMainLoop  *wloop;
static guint       wto;
static guint64     cur_uh, cur_ul;
static const char *wname;
static gboolean    w_done = FALSE;

static void w_quit(void) { w_done = TRUE; if (wloop) g_main_loop_quit(wloop); }

static void w_print_raw(GArray *d) {
    printf("%s %u bytes:", wname, d->len);
    for (guint i = 0; i < d->len; i++) printf(" %02x", (guchar)d->data[i]);
    printf("\n");
}

/* Interpret one generic report (full libssc report message in d). */
static void w_emit_generic(GArray *d) {
    Kind k = find_probe(wname)->kind;
    if (d->len >= 2 && d->data[0] == 0x0a) {            /* field 1, length-delimited */
        guint len = (guchar)d->data[1];
        if (2 + len <= d->len) {
            const guchar *p = (const guchar *)(d->data + 2);
            if (k == K_VEC3 && len >= 12) {
                gfloat f[3]; memcpy(f, p, 12);
                printf("%s %g %g %g\n", wname, f[0], f[1], f[2]); fflush(stdout); w_quit(); return;
            }
            if (k == K_QUAT && len >= 16) {
                gfloat f[4]; memcpy(f, p, 16);
                printf("%s %g %g %g %g\n", wname, f[0], f[1], f[2], f[3]); fflush(stdout); w_quit(); return;
            }
        }
    }
    if (k == K_VARINT && d->len >= 2 && d->data[0] == 0x08) {   /* field 1, varint */
        printf("%s %u\n", wname, (guchar)d->data[1]); fflush(stdout); w_quit(); return;
    }
    w_print_raw(d); fflush(stdout); w_quit();
}

static void w_accel(SSCSensorAccelerometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    (void)s; (void)u;
    if (w_done) return;
    printf("%s %g %g %g\n", wname, x, y, z); fflush(stdout); w_quit();
}
static void w_gyro(SSCSensorGyroscope *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    (void)s; (void)u;
    if (w_done) return;
    printf("%s %g %g %g\n", wname, x, y, z); fflush(stdout); w_quit();
}
static void w_mag(SSCSensorMagnetometer *s, gfloat x, gfloat y, gfloat z, gpointer u) {
    (void)s; (void)u;
    if (w_done) return;
    printf("%s %g %g %g\n", wname, x, y, z); fflush(stdout); w_quit();
}
static void w_light(SSCSensorLight *s, gfloat v, gpointer u) {
    (void)s; (void)u;
    if (w_done) return;
    printf("%s %g\n", wname, v); fflush(stdout); w_quit();
}
static void w_compass(SSCSensorCompass *s, gfloat v, gpointer u) {
    (void)s; (void)u;
    if (w_done) return;
    printf("%s %g\n", wname, v); fflush(stdout); w_quit();
}
static void w_report(GObject *c, guint mid, guint64 uh, guint64 ul, GArray *d, gpointer u) {
    (void)c; (void)mid; (void)u;
    if (w_done) return;
    if (uh == cur_uh && ul == cur_ul) w_emit_generic(d);
}
static gboolean w_timeout(gpointer u) {
    (void)u;
    if (w_done) return G_SOURCE_REMOVE;
    printf("%s <no data>\n", wname); fflush(stdout); w_quit(); return G_SOURCE_REMOVE;
}

static void w_open_cb(GObject *o, GAsyncResult *r, gpointer u) {
    GError *e = NULL;
    (void)u;
    if (!ssc_sensor_open_finish(SSC_SENSOR(o), r, &e)) {
        printf("%s <unavailable>\n", wname); fflush(stdout); g_clear_error(&e); w_quit(); return;
    }
    g_clear_error(&e);
}
static void w_new_cb(GObject *o, GAsyncResult *r, gpointer u) {
    GError *e = NULL;
    SSCSensor *s = ssc_sensor_new_finish(r, &e); g_clear_error(&e); (void)u; (void)o;
    if (!s) { printf("%s <unavailable>\n", wname); fflush(stdout); w_quit(); return; }
    g_object_get(s, "uid-high", &cur_uh, "uid-low", &cur_ul, NULL);
    GObject *c = NULL; g_object_get(s, SSC_SENSOR_CLIENT, &c, NULL);
    if (c) g_signal_connect(c, "report", G_CALLBACK(w_report), NULL);
    ssc_sensor_open(s, NULL, w_open_cb, NULL);
}

static int worker_main(const char *name, int secs) {
    Probe *p = find_probe(name);
    if (!p) { fprintf(stderr, "Unknown sensor: %s\n", name); return 2; }
    wname = name; w_done = FALSE;
    setvbuf(stdout, NULL, _IONBF, 0);
    wloop = g_main_loop_new(NULL, FALSE);
    wto = g_timeout_add_seconds(secs, w_timeout, NULL);

    GError *err = NULL;
    gboolean ok = FALSE;
    switch (p->kind) {
    case K_ACCEL: { SSCSensorAccelerometer *s = ssc_sensor_accelerometer_new_sync(NULL, &err); g_clear_error(&err);
        if (s) { g_signal_connect(s, "measurement", G_CALLBACK(w_accel), NULL); ok = ssc_sensor_accelerometer_open_sync(s, NULL, &err); } g_clear_error(&err); break; }
    case K_GYRO: { SSCSensorGyroscope *s = ssc_sensor_gyroscope_new_sync(NULL, &err); g_clear_error(&err);
        if (s) { g_signal_connect(s, "measurement", G_CALLBACK(w_gyro), NULL); ok = ssc_sensor_gyroscope_open_sync(s, NULL, &err); } g_clear_error(&err); break; }
    case K_MAG: { SSCSensorMagnetometer *s = ssc_sensor_magnetometer_new_sync(NULL, &err); g_clear_error(&err);
        if (s) { g_signal_connect(s, "measurement", G_CALLBACK(w_mag), NULL); ok = ssc_sensor_magnetometer_open_sync(s, NULL, &err); } g_clear_error(&err); break; }
    case K_LIGHT: { SSCSensorLight *s = ssc_sensor_light_new_sync(NULL, &err); g_clear_error(&err);
        if (s) { g_signal_connect(s, "measurement", G_CALLBACK(w_light), NULL); ok = ssc_sensor_light_open_sync(s, NULL, &err); } g_clear_error(&err); break; }
    case K_COMPASS: { SSCSensorCompass *s = ssc_sensor_compass_new_sync(NULL, &err); g_clear_error(&err);
        if (s) { g_signal_connect(s, "measurement", G_CALLBACK(w_compass), NULL); ok = ssc_sensor_compass_open_sync(s, NULL, &err); } g_clear_error(&err); break; }
    default:
        ssc_sensor_new((gchar *)name, NULL, w_new_cb, NULL);   /* generic async */
        ok = TRUE;
        break;
    }

    if (ok) g_main_loop_run(wloop);
    g_source_remove(wto);
    return 0;
}

/* ── parent (aggregate) ─────────────────────────────────────────────── */
static gchar *self_exe(void) {
    gchar buf[PATH_MAX];
    gssize n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return NULL;
    buf[n] = '\0';
    return g_strdup(buf);
}

static gchar *run_child(const gchar *exe, const char *type, int secs) {
    gchar secs_str[16];
    g_snprintf(secs_str, sizeof(secs_str), "%d", secs);
    gchar *argv[] = { (gchar *)exe, (gchar *)"--read-one", (gchar *)type, secs_str, NULL };
    gchar *out = NULL; gint status; GError *err = NULL;
    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_STDERR_TO_DEV_NULL,
                      NULL, NULL, &out, NULL, &status, &err)) {
        g_error_free(err);
        return NULL;
    }
    return out;
}

static int aggregate_main(int argc, char *argv[]) {
    int secs = 6;
    gboolean sel[16] = {FALSE};
    gboolean any = FALSE;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "all")) { for (int j = 0; j < n_probes; j++) sel[j] = TRUE; any = TRUE; }
        else if (find_probe(argv[i])) { sel[find_probe(argv[i]) - probes] = TRUE; any = TRUE; }
        else {
            char *end; long t = strtol(argv[i], &end, 10);
            if (*end == '\0' && t > 0) secs = (int)t;
            else {
                fprintf(stderr, "Unknown sensor: %s\n", argv[i]);
                fprintf(stderr, "Usage: %s [sensor ... | all] [timeout]\n  sensors:", argv[0]);
                for (int j = 0; j < n_probes; j++) fprintf(stderr, " %s", probes[j].name);
                fprintf(stderr, "\n");
                return 2;
            }
        }
    }
    if (!any) for (int j = 0; j < n_probes; j++) sel[j] = TRUE;

    setvbuf(stdout, NULL, _IONBF, 0);
    gchar *exe = self_exe();
    if (!exe) { fprintf(stderr, "cannot resolve own executable path\n"); return 1; }

    for (int i = 0; i < n_probes; i++) {
        if (!sel[i]) continue;
        gchar *line = run_child(exe, probes[i].name, secs);
        if (line) fputs(line, stdout);
        else      printf("%s <error>\n", probes[i].name);
        g_free(line);
    }
    g_free(exe);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc >= 3 && !strcmp(argv[1], "--read-one"))
        return worker_main(argv[2], (argc >= 4) ? atoi(argv[3]) : 6);
    return aggregate_main(argc, argv);
}
