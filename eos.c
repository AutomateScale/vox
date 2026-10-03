/* eos-bin — Canon EOS USB live view without EOS Webcam Utility.
 *
 * Talks PTP via libgphoto2, holds the session open (so the M50 doesn't
 * drop off a USB hub when the presenter closes), and streams JPEG
 * frames to /tmp/vox-eos.sock for cam-bin.
 *
 * The Canon camera extension (DriverKit) exclusive-owns USB while it is
 * enabled — this process will sit in DETECT NONE / claim-retry until
 * that extension is disabled. Do NOT pkill EOSWebcamService from here:
 * bouncing that helper is what knocks the M50 off Archon's hub chain.
 *
 * Usage:
 *   eos-bin              hold session, stream to the socket
 *   eos-bin --detect     print DETECT LIVE / DETECT NONE (no claim)
 *   eos-bin --once       one preview JPEG to stdout, then exit
 *
 * Protocol on the socket: uint32 magic 0x31584F56, uint32 size, JPEG.
 */
#include <errno.h>
#include <fcntl.h>
#include <gphoto2/gphoto2.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define SOCK_PATH "/tmp/vox-eos.sock"
#define READY_PATH "/tmp/vox-eos.ready"
#define EOS_MAGIC 0x31584F56u
#define LOG(fmt, ...) do { fprintf(stderr, "EOS: " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

static volatile sig_atomic_t g_run = 1;
static int g_client = -1;
static pthread_mutex_t g_cli_mu = PTHREAD_MUTEX_INITIALIZER;

static void on_sig(int s) { (void)s; g_run = 0; }

static void ctx_err(GPContext *c, const char *t, void *d) {
    (void)c; (void)d; LOG("gphoto: %s", t ? t : "?");
}

static int set_cfg(Camera *cam, GPContext *ctx, const char *key, const char *val) {
    CameraWidget *w = NULL;
    int r = gp_camera_get_single_config(cam, key, &w, ctx);
    if (r < GP_OK) return r;
    CameraWidgetType t = GP_WIDGET_TEXT;
    gp_widget_get_type(w, &t);
    if (t == GP_WIDGET_TOGGLE) {
        int on = (val && (val[0] == '1' || val[0] == 't' || val[0] == 'T'));
        gp_widget_set_value(w, &on);
    } else {
        gp_widget_set_value(w, val);
    }
    r = gp_camera_set_single_config(cam, key, w, ctx);
    gp_widget_free(w);
    return r;
}

static void enable_liveview(Camera *cam, GPContext *ctx) {
    /* Best-effort: cameras expose different widget names. */
    if (set_cfg(cam, ctx, "viewfinder", "1") == GP_OK) LOG("viewfinder=1");
    else if (set_cfg(cam, ctx, "eosviewfinder", "1") == GP_OK) LOG("eosviewfinder=1");
    if (set_cfg(cam, ctx, "liveviewsize", "0") == GP_OK) LOG("liveviewsize=large");
    /* EOS-M encodes size in output: PC = largest preview. */
    set_cfg(cam, ctx, "output", "PC");
}

static void disable_liveview(Camera *cam, GPContext *ctx) {
    if (!cam) return;
    set_cfg(cam, ctx, "viewfinder", "0");
    set_cfg(cam, ctx, "eosviewfinder", "0");
}

static int detect(GPContext *ctx) {
    CameraList *list = NULL;
    gp_list_new(&list);
    int n = gp_camera_autodetect(list, ctx);
    int count = gp_list_count(list);
    int live = 0;
    for (int i = 0; i < count; i++) {
        const char *name = NULL, *port = NULL;
        gp_list_get_name(list, i, &name);
        gp_list_get_value(list, i, &port);
        LOG("found %s on %s", name ? name : "?", port ? port : "?");
        if (name && (strstr(name, "Canon") || strstr(name, "EOS"))) live = 1;
    }
    gp_list_free(list);
    if (n < 0) LOG("autodetect err %d", n);
    return live || count > 0;
}

static Camera *open_camera(GPContext *ctx) {
    Camera *cam = NULL;
    gp_camera_new(&cam);
    int r = gp_camera_init(cam, ctx);
    if (r < GP_OK) {
        LOG("camera init failed (%d) — Canon camera extension still owning USB?", r);
        gp_camera_unref(cam);
        return NULL;
    }
    CameraText txt;
    if (gp_camera_get_summary(cam, &txt, ctx) == GP_OK)
        LOG("opened: %.80s", txt.text);
    enable_liveview(cam, ctx);
    return cam;
}

static void close_camera(Camera *cam, GPContext *ctx) {
    if (!cam) return;
    disable_liveview(cam, ctx);
    gp_camera_exit(cam, ctx);
    gp_camera_unref(cam);
}

static int write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += (size_t)w; n -= (size_t)w;
    }
    return 0;
}

static void send_frame(const char *jpeg, unsigned long sz) {
    if (sz < 100 || sz > 8u * 1024u * 1024u) return;
    pthread_mutex_lock(&g_cli_mu);
    int fd = g_client;
    if (fd < 0) { pthread_mutex_unlock(&g_cli_mu); return; }
    uint32_t hdr[2] = { EOS_MAGIC, (uint32_t)sz };
    if (write_all(fd, hdr, sizeof hdr) < 0 || write_all(fd, jpeg, sz) < 0) {
        LOG("client gone");
        close(fd);
        g_client = -1;
    }
    pthread_mutex_unlock(&g_cli_mu);
}

static int bind_sock(void) {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { LOG("socket: %s", strerror(errno)); return -1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof addr.sun_path - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        LOG("bind %s: %s", SOCK_PATH, strerror(errno));
        close(fd); return -1;
    }
    chmod(SOCK_PATH, 0600);
    if (listen(fd, 2) < 0) { close(fd); return -1; }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    LOG("listening on %s", SOCK_PATH);
    return fd;
}

static void accept_one(int listen_fd) {
    int c = accept(listen_fd, NULL, NULL);
    if (c < 0) return;
    pthread_mutex_lock(&g_cli_mu);
    if (g_client >= 0) close(g_client);
    g_client = c;
    pthread_mutex_unlock(&g_cli_mu);
    LOG("cam-bin connected");
}

static int capture_one(Camera *cam, GPContext *ctx, int to_stdout) {
    CameraFile *file = NULL;
    gp_file_new(&file);
    int r = gp_camera_capture_preview(cam, file, ctx);
    if (r < GP_OK) {
        gp_file_free(file);
        return r;
    }
    const char *data = NULL;
    unsigned long sz = 0;
    gp_file_get_data_and_size(file, &data, &sz);
    if (to_stdout) {
        fwrite(data, 1, sz, stdout);
        fflush(stdout);
    } else {
        send_frame(data, sz);
    }
    gp_file_free(file);
    return GP_OK;
}

int main(int argc, char **argv) {
    int do_detect = 0, do_once = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--detect") == 0) do_detect = 1;
        else if (strcmp(argv[i], "--once") == 0) do_once = 1;
    }

    GPContext *ctx = gp_context_new();
    gp_context_set_error_func(ctx, ctx_err, NULL);

    if (do_detect) {
        int live = detect(ctx);
        printf(live ? "DETECT LIVE\n" : "DETECT NONE\n");
        return live ? 0 : 2;
    }

    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);
    signal(SIGPIPE, SIG_IGN);

    if (do_once) {
        Camera *cam = open_camera(ctx);
        if (!cam) return 2;
        int r = capture_one(cam, ctx, 1);
        close_camera(cam, ctx);
        return r == GP_OK ? 0 : 3;
    }

    int listen_fd = bind_sock();
    if (listen_fd < 0) return 1;

    Camera *cam = NULL;
    int frames = 0, fails = 0, ready = 0;
    time_t last_report = time(NULL);
    time_t last_try = 0;

    LOG("holding Canon PTP session (no EOS Webcam Utility)");
    while (g_run) {
        accept_one(listen_fd);
        time_t now = time(NULL);
        if (!cam) {
            if (now - last_try < 3) { usleep(200 * 1000); continue; }
            last_try = now;
            if (!detect(ctx)) {
                LOG("no Canon on PTP — disable the EOS Webcam Utility camera extension, or power-cycle the body");
                sleep(3);
                continue;
            }
            cam = open_camera(ctx);
            if (!cam) { sleep(2); continue; }
            fails = 0;
        }
        int r = capture_one(cam, ctx, 0);
        if (r == GP_OK) {
            frames++; fails = 0;
            if (!ready) {
                int rf = open(READY_PATH, O_CREAT | O_WRONLY, 0600);
                if (rf >= 0) close(rf);
                ready = 1;
                LOG("first live frame — PTP ready");
            }
            if (now - last_report >= 60) {
                LOG("holding PTP: %d frames/min", frames);
                frames = 0; last_report = now;
            }
        } else {
            fails++;
            LOG("preview failed (%d) strike %d", r, fails);
            if (fails >= 5) {
                LOG("re-opening camera");
                unlink(READY_PATH); ready = 0;
                close_camera(cam, ctx);
                cam = NULL;
                fails = 0;
                sleep(1);
            } else {
                usleep(80 * 1000);
            }
        }
    }

    pthread_mutex_lock(&g_cli_mu);
    if (g_client >= 0) close(g_client);
    g_client = -1;
    pthread_mutex_unlock(&g_cli_mu);
    close(listen_fd);
    unlink(SOCK_PATH);
    unlink(READY_PATH);
    close_camera(cam, ctx);
    LOG("released");
    return 0;
}
