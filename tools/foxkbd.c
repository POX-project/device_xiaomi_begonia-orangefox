/*
 * foxkbd - on-screen keyboard and pty launcher for FoxBrowse.
 *
 * The browser is started with a pseudo-terminal as stdin.  Links2 already
 * understands ordinary terminal input, so this helper only has to put bytes on
 * the master side of that pty; no uinput or browser patch is needed.
 *
 * The keyboard is modal:
 *   - hold Volume Up for about 0.7 s to show or hide it
 *   - tap a key, or tap above the keyboard to dismiss it
 *   - while it is visible the physical touchscreen is grabbed, so taps on
 *     keys cannot leak through to the page underneath
 *
 * This is intentionally self-contained: framebuffer drawing, evdev scanning,
 * a small 8x8 font and pty handling are all in this file.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <linux/fb.h>
#include <linux/input.h>

#include "font8x8.h"

#ifndef ABS_CNT
#define ABS_CNT (ABS_MAX + 1)
#endif
#ifndef KEY_CNT
#define KEY_CNT (KEY_MAX + 1)
#endif

#define BIT_WORD(n) ((n) / (8 * sizeof(unsigned long)))
#define BIT_MASK(n) (1UL << ((n) % (8 * sizeof(unsigned long))))
#define TEST_BIT(bits, n) ((bits)[BIT_WORD(n)] & BIT_MASK(n))

#define COL_BG       0x0b1016u
#define COL_PANEL    0x111a24u
#define COL_KEY      0x1b2733u
#define COL_KEY_DOWN 0x2d6f8fu
#define COL_BORDER   0x3a4b5cu
#define COL_TEXT     0xe8eef5u
#define COL_ACCENT   0x7fd1ffu
#define COL_MUTED    0x9aa7b4u

#define TOP_BAR_H 84

enum {
    A_NONE = 0,
    A_CHAR,
    A_SPACE,
    A_BACKSPACE,
    A_ENTER,
    A_TAB,
    A_ESC,
    A_URL,
    A_HIDE,
    A_SHIFT,
    A_LAYER,
    A_LEFT,
    A_RIGHT,
    A_UP,
    A_DOWN
};

struct key {
    int x, y, w, h;
    char label[16];
    int action;
    int code;
};

static int master_fd = -1;
static pid_t child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;

static int fb_fd = -1;
static unsigned char *fb_mem = NULL;
static size_t fb_len = 0;
static struct fb_var_screeninfo vinfo;
static struct fb_fix_screeninfo finfo;
static int screen_w = 0, screen_h = 0, bpp = 0, stride = 0;

static int touch_fd = -1;
static int touch_xcode = ABS_X, touch_ycode = ABS_Y;
static int touch_xmin = 0, touch_xmax = 1, touch_ymin = 0, touch_ymax = 1;
static int touch_use_mt = 0;

static int key_fd = -1;
static int keyboard_visible = 0;
static int layer = 0;       /* 0 = letters, 1 = symbols */
static int shift = 0;
static int pressed_key = -1;

static int kb_top = 0, kb_height = 0;
static struct key keys[96];
static int nkeys = 0;

static int touch_active = 0;
static int touch_moved = 0;
static int touch_start_x = -1, touch_start_y = -1;
static int touch_last_x = 0, touch_last_y = 0;
static int touch_raw_x = 0, touch_raw_y = 0;
static long long touch_start_ms = 0;

static int vol_held = 0;
static long long vol_press_ms = 0;

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_signal(int sig)
{
    (void)sig;
    stop_requested = 1;
}

static void logmsg(const char *s)
{
    fprintf(stderr, "foxkbd: %s\n", s);
}

static uint32_t pack_color(uint32_t rgb)
{
    uint32_t r = (rgb >> 16) & 0xff;
    uint32_t g = (rgb >> 8) & 0xff;
    uint32_t b = rgb & 0xff;
    uint32_t v = 0;

    if (bpp == 32) {
        if (vinfo.red.length)
            v |= ((r >> (8 - vinfo.red.length)) & ((1u << vinfo.red.length) - 1)) << vinfo.red.offset;
        if (vinfo.green.length)
            v |= ((g >> (8 - vinfo.green.length)) & ((1u << vinfo.green.length) - 1)) << vinfo.green.offset;
        if (vinfo.blue.length)
            v |= ((b >> (8 - vinfo.blue.length)) & ((1u << vinfo.blue.length) - 1)) << vinfo.blue.offset;
    } else {
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
    }
    return v;
}

static void fill_rect(int x, int y, int w, int h, uint32_t rgb)
{
    int yy, xx;
    uint32_t c;

    if (!fb_mem || w <= 0 || h <= 0) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > screen_w) w = screen_w - x;
    if (y + h > screen_h) h = screen_h - y;
    if (w <= 0 || h <= 0) return;

    c = pack_color(rgb);
    for (yy = 0; yy < h; yy++) {
        unsigned char *row = fb_mem + (size_t)(y + yy) * stride;
        if (bpp == 32) {
            uint32_t *p = (uint32_t *)(void *)(row + (size_t)x * 4);
            for (xx = 0; xx < w; xx++) p[xx] = c;
        } else {
            uint16_t *p = (uint16_t *)(void *)(row + (size_t)x * 2);
            for (xx = 0; xx < w; xx++) p[xx] = (uint16_t)c;
        }
    }
}

static void draw_rect(int x, int y, int w, int h, int bw, uint32_t rgb)
{
    fill_rect(x, y, w, bw, rgb);
    fill_rect(x, y + h - bw, w, bw, rgb);
    fill_rect(x, y, bw, h, rgb);
    fill_rect(x + w - bw, y, bw, h, rgb);
}

static void draw_char(int x, int y, unsigned char ch, int scale, uint32_t rgb)
{
    const unsigned char *g;
    int row, col;

    if (ch < 32 || ch > 126) ch = '?';
    g = font8x8[ch - 32];
    for (row = 0; row < 8; row++) {
        unsigned char bits = g[row];
        for (col = 0; col < 8; col++) {
            if (bits & (0x80 >> col))
                fill_rect(x + col * scale, y + row * scale, scale, scale, rgb);
        }
    }
}

static int text_width(const char *s, int scale)
{
    int n = (int)strlen(s);
    return n > 0 ? n * 8 * scale - scale : 0;
}

static void draw_text(int x, int y, const char *s, int scale, uint32_t rgb)
{
    int i;
    for (i = 0; s[i]; i++)
        draw_char(x + i * 8 * scale, y, (unsigned char)s[i], scale, rgb);
}

static void draw_key_label(const struct key *k, uint32_t rgb)
{
    int n = (int)strlen(k->label);
    int scale = n == 1 ? 4 : 3;
    int tw, th, x, y;

    while (scale > 1 && text_width(k->label, scale) > k->w - 10)
        scale--;
    if (scale < 1) scale = 1;
    tw = text_width(k->label, scale);
    th = 8 * scale;
    x = k->x + (k->w - tw) / 2;
    y = k->y + (k->h - th) / 2;
    draw_text(x, y, k->label, scale, rgb);
}

static void add_key(int x, int y, int w, int h, const char *label, int action, int code)
{
    struct key *k;

    if (nkeys >= (int)(sizeof(keys) / sizeof(keys[0]))) return;
    k = &keys[nkeys++];
    k->x = x;
    k->y = y;
    k->w = w;
    k->h = h;
    snprintf(k->label, sizeof(k->label), "%s", label);
    k->action = action;
    k->code = code;
}

static void add_row(int y, int h, int n, const int *weights,
                    const char *const *labels, const int *actions, const int *codes)
{
    int margin = 8, gap = 6;
    int avail = screen_w - 2 * margin - gap * (n - 1);
    int total = 0, i, x = margin;

    for (i = 0; i < n; i++) total += weights[i];
    if (total <= 0) return;

    for (i = 0; i < n; i++) {
        int w = (i == n - 1) ? (screen_w - margin - x) : avail * weights[i] / total;
        add_key(x, y, w, h, labels[i], actions[i], codes ? codes[i] : 0);
        x += w + gap;
    }
}

static void build_keyboard(void)
{
    static const int bar_w[8] = {14, 14, 10, 10, 10, 10, 10, 10};
    static const char *bar_l[8] = {"Hide", "URL", "Esc", "Tab", "<", ">", "^", "v"};
    static const int bar_a[8] = {A_HIDE, A_URL, A_ESC, A_TAB, A_LEFT, A_RIGHT, A_UP, A_DOWN};

    static const int row1_w[10] = {10, 10, 10, 10, 10, 10, 10, 10, 10, 10};
    static const int row2_w[9] = {10, 10, 10, 10, 10, 10, 10, 10, 10};
    static const int row3_w[9] = {16, 10, 10, 10, 10, 10, 10, 10, 16};
    static const int row4_w[9] = {14, 8, 8, 8, 8, 8, 8, 25, 13};

    static const char *l1[10] = {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"};
    static const char *l2[9] = {"a", "s", "d", "f", "g", "h", "j", "k", "l"};
    static const char *l3[9] = {"Shift", "z", "x", "c", "v", "b", "n", "m", "Bksp"};
    static const char *l4[9] = {"123", "/", ".", "-", "_", ":", "?", "Space", "Enter"};
    static const char *s1[10] = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"};
    static const char *s2[9] = {"@", "#", "%", "&", "*", "(", ")", "[", "]"};
    static const char *s3[9] = {"+", "=", "\"", "'", "~", ";", "!", ",", "Bksp"};
    static const char *s4[9] = {"ABC", "/", ".", "-", "_", ":", "?", "Space", "Enter"};

    static const int r1a[10] = {A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR};
    static const int r2a[9] = {A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR};
    static const int r3a[9] = {A_SHIFT, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_BACKSPACE};
    static const int r4a[9] = {A_LAYER, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_SPACE, A_ENTER};
    static const int s3a[9] = {A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_BACKSPACE};
    static const int s4a[9] = {A_LAYER, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_CHAR, A_SPACE, A_ENTER};

    int bar_h = TOP_BAR_H, gap = 6;
    int bar_y, row_h, row_y, i;
    char upper1[10][2], upper2[9][2], upper3[9][2];
    const char *u1[10], *u2[9], *u3[9];
    int c1[10], c2[9], c3[9];

    kb_height = screen_h * 44 / 100;
    if (kb_height < 700) kb_height = 700;
    if (kb_height > 980) kb_height = 980;
    if (kb_height > screen_h - 100) kb_height = screen_h - 100;
    kb_top = screen_h - kb_height;

    bar_y = kb_top + 8;
    row_h = (kb_height - bar_h - 5 * gap - 20) / 4;
    if (row_h < 100) row_h = 100;

    nkeys = 0;
    add_row(bar_y, bar_h, 8, bar_w, bar_l, bar_a, NULL);

    for (i = 0; i < 10; i++) {
        upper1[i][0] = (char)(l1[i][0] - 32);
        upper1[i][1] = 0;
        u1[i] = upper1[i];
        c1[i] = (unsigned char)l1[i][0];
    }
    for (i = 0; i < 9; i++) {
        upper2[i][0] = (char)(l2[i][0] - 32);
        upper2[i][1] = 0;
        u2[i] = upper2[i];
        c2[i] = (unsigned char)l2[i][0];
    }
    for (i = 1; i < 8; i++) {
        upper3[i][0] = (char)(l3[i][0] - 32);
        upper3[i][1] = 0;
        u3[i] = upper3[i];
        c3[i] = (unsigned char)l3[i][0];
    }
    u3[0] = l3[0];
    u3[8] = l3[8];
    c3[0] = c3[8] = 0;

    row_y = bar_y + bar_h + gap;
    if (layer == 0) {
        add_row(row_y, row_h, 10, row1_w, shift ? u1 : l1, r1a, c1);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row2_w, shift ? u2 : l2, r2a, c2);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row3_w, shift ? u3 : l3, r3a, c3);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row4_w, l4, r4a, NULL);
    } else {
        add_row(row_y, row_h, 10, row1_w, s1, r1a, NULL);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row2_w, s2, r2a, NULL);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row3_w, s3, s3a, NULL);
        row_y += row_h + gap;
        add_row(row_y, row_h, 9, row4_w, s4, s4a, NULL);
    }

    /* Fill in character codes for the symbol layer. */
    for (i = 0; i < nkeys; i++) {
        if (keys[i].action == A_CHAR && keys[i].code == 0) {
            /* Label is exactly one byte for every symbol key. */
            keys[i].code = (unsigned char)keys[i].label[0];
        }
    }
    /* The letter rows already have codes; make sure Shift/Backspace stay 0. */
    for (i = 0; i < nkeys; i++) {
        if (keys[i].action != A_CHAR) keys[i].code = 0;
    }
}

static void draw_keyboard(void)
{
    int i;

    if (!fb_mem) return;
    fill_rect(0, kb_top, screen_w, kb_height, COL_BG);
    fill_rect(0, kb_top, screen_w, 3, COL_ACCENT);

    for (i = 0; i < nkeys; i++) {
        const struct key *k = &keys[i];
        int active = 0;
        uint32_t label_color = COL_TEXT;

        if (i == pressed_key) active = 1;
        if (k->action == A_SHIFT && shift) active = 1;
        if (k->action == A_LAYER && layer) active = 1;
        if (k->action == A_HIDE) label_color = COL_ACCENT;
        if (k->y < kb_top + TOP_BAR_H + 4) label_color = active ? COL_TEXT : COL_ACCENT;

        fill_rect(k->x, k->y, k->w, k->h, active ? COL_KEY_DOWN : (k->y < kb_top + TOP_BAR_H + 4 ? COL_PANEL : COL_KEY));
        draw_rect(k->x, k->y, k->w, k->h, 2, active ? COL_ACCENT : COL_BORDER);
        draw_key_label(k, label_color);
    }
}

static int key_at(int x, int y)
{
    int i;
    for (i = 0; i < nkeys; i++) {
        if (x >= keys[i].x && x < keys[i].x + keys[i].w &&
            y >= keys[i].y && y < keys[i].y + keys[i].h)
            return i;
    }
    return -1;
}

static void write_master(const char *s, size_t n)
{
    size_t off = 0;
    if (master_fd < 0) return;
    while (off < n) {
        ssize_t r = write(master_fd, s + off, n - off);
        if (r > 0) {
            off += (size_t)r;
        } else if (r < 0 && errno == EINTR) {
            continue;
        } else {
            /* A non-blocking pty can be full if the browser is busy.
             * Dropping a keystroke is preferable to freezing the keyboard. */
            break;
        }
    }
}

static void send_char(int c)
{
    char ch = (char)c;
    write_master(&ch, 1);
}

static void send_string(const char *s)
{
    write_master(s, strlen(s));
}

static void hide_keyboard(void);

static void handle_action(int idx)
{
    struct key *k;
    char c;

    if (idx < 0 || idx >= nkeys) return;
    k = &keys[idx];

    switch (k->action) {
    case A_CHAR:
        c = (char)k->code;
        if (shift && c >= 'a' && c <= 'z') c = (char)(c - 32);
        send_char((unsigned char)c);
        shift = 0;
        break;
    case A_SPACE:
        send_char(' ');
        break;
    case A_BACKSPACE:
        send_char(0x7f);
        break;
    case A_ENTER:
        send_char('\r');
        break;
    case A_TAB:
        send_char('\t');
        break;
    case A_ESC:
        send_char(0x1b);
        break;
    case A_URL:
        send_char('g');
        break;
    case A_HIDE:
        hide_keyboard();
        return;
    case A_SHIFT:
        shift = !shift;
        break;
    case A_LAYER:
        layer = !layer;
        shift = 0;
        break;
    case A_LEFT:
        send_string("\033[D");
        break;
    case A_RIGHT:
        send_string("\033[C");
        break;
    case A_UP:
        send_string("\033[A");
        break;
    case A_DOWN:
        send_string("\033[B");
        break;
    default:
        break;
    }

    /* Links2 repaints around the text field after each key.  Wait a moment,
     * then put the keyboard back on top of the area it owns. */
    usleep(45000);
    draw_keyboard();
}

static int map_x(int raw)
{
    if (touch_xmax <= touch_xmin) return raw;
    if (raw < touch_xmin) raw = touch_xmin;
    if (raw > touch_xmax) raw = touch_xmax;
    return (int)((long long)(raw - touch_xmin) * screen_w / (touch_xmax - touch_xmin));
}

static int map_y(int raw)
{
    if (touch_ymax <= touch_ymin) return raw;
    if (raw < touch_ymin) raw = touch_ymin;
    if (raw > touch_ymax) raw = touch_ymax;
    return (int)((long long)(raw - touch_ymin) * screen_h / (touch_ymax - touch_ymin));
}

static void touch_begin(int x, int y)
{
    touch_active = 1;
    touch_moved = 0;
    /* The real coordinates usually arrive before BTN_TOUCH, but some
     * controllers report the button first.  Mark the start as pending and
     * let the next SYN_REPORT fill it in. */
    touch_start_x = -1;
    touch_start_y = -1;
    touch_last_x = x;
    touch_last_y = y;
    touch_start_ms = now_ms();
}

static void touch_finish(void)
{
    int x, y;
    long long dt;

    if (!touch_active) return;
    touch_active = 0;
    x = touch_start_x;
    y = touch_start_y;
    if (x < 0) x = touch_last_x;
    if (y < 0) y = touch_last_y;
    dt = now_ms() - touch_start_ms;
    if (!touch_moved && dt < 800) {
        int idx = key_at(x, y);
        if (idx >= 0) {
            pressed_key = idx;
            draw_keyboard();
            usleep(35000);
            pressed_key = -1;
            handle_action(idx);
        } else if (y < kb_top) {
            hide_keyboard();
        }
    }
}

static void touch_event(const struct input_event *ev)
{
    if (ev->type == EV_ABS) {
        if (ev->code == touch_xcode) {
            touch_raw_x = ev->value;
            if (touch_active) {
                int x = map_x(touch_raw_x);
                if (touch_start_x >= 0 && abs(x - touch_start_x) > 24) touch_moved = 1;
                touch_last_x = x;
            }
        } else if (ev->code == touch_ycode) {
            touch_raw_y = ev->value;
            if (touch_active) {
                int y = map_y(touch_raw_y);
                if (touch_start_y >= 0 && abs(y - touch_start_y) > 24) touch_moved = 1;
                touch_last_y = y;
            }
        } else if (touch_use_mt && ev->code == ABS_MT_TRACKING_ID) {
            if (ev->value < 0) {
                touch_finish();
            } else if (!touch_active) {
                touch_begin(map_x(touch_raw_x), map_y(touch_raw_y));
            }
        }
    } else if (ev->type == EV_KEY && ev->code == BTN_TOUCH) {
        if (ev->value) {
            if (!touch_active) touch_begin(map_x(touch_raw_x), map_y(touch_raw_y));
        } else {
            touch_finish();
        }
    } else if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
        if (touch_active) {
            int x = map_x(touch_raw_x);
            int y = map_y(touch_raw_y);
            if (touch_start_x < 0 || touch_start_y < 0) {
                touch_start_x = x;
                touch_start_y = y;
            } else if (abs(x - touch_start_x) > 24 || abs(y - touch_start_y) > 24) {
                touch_moved = 1;
            }
            touch_last_x = x;
            touch_last_y = y;
        }
    }
}

static void drain_fd(int fd);

static void volume_event(const struct input_event *ev)
{
    if (ev->type != EV_KEY || ev->code != KEY_VOLUMEUP) return;
    if (ev->value == 1) {
        vol_held = 1;
        vol_press_ms = now_ms();
    } else if (ev->value == 0) {
        if (vol_held && now_ms() - vol_press_ms >= 650) {
            if (keyboard_visible) hide_keyboard();
            else {
                keyboard_visible = 1;
                if (touch_fd >= 0) {
                    if (ioctl(touch_fd, EVIOCGRAB, 1) < 0)
                        logmsg("cannot grab touchscreen");
                    else
                        logmsg("touchscreen grabbed");
                    drain_fd(touch_fd);
                }
                touch_active = 0;
                build_keyboard();
                draw_keyboard();
            }
        }
        vol_held = 0;
    }
}

static void drain_fd(int fd)
{
    struct input_event ev[64];
    ssize_t n;
    while (fd >= 0) {
        n = read(fd, ev, sizeof(ev));
        if (n <= 0) break;
        if ((size_t)n < sizeof(ev[0])) break;
    }
}

static void hide_keyboard(void)
{
    if (!keyboard_visible) return;
    keyboard_visible = 0;
    pressed_key = -1;
    touch_active = 0;
    if (touch_fd >= 0) {
        ioctl(touch_fd, EVIOCGRAB, 0);
        drain_fd(touch_fd);
    }
    /* Ctrl+L is Links2's full-screen redraw key.  It removes the keyboard
     * from the framebuffer without reloading the page. */
    send_char(0x0c);
}

static int open_framebuffer(void)
{
    const char *paths[] = {"/dev/graphics/fb0", "/dev/fb0", NULL};
    int i;

    for (i = 0; paths[i]; i++) {
        fb_fd = open(paths[i], O_RDWR);
        if (fb_fd >= 0) break;
    }
    if (fb_fd < 0) {
        logmsg("no framebuffer");
        return -1;
    }
    memset(&vinfo, 0, sizeof(vinfo));
    memset(&finfo, 0, sizeof(finfo));
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        logmsg("FBIOGET_*SCREENINFO failed");
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }
    screen_w = vinfo.xres;
    screen_h = vinfo.yres;
    bpp = vinfo.bits_per_pixel;
    stride = finfo.line_length ? (int)finfo.line_length : screen_w * (bpp / 8);
    if (screen_w <= 0 || screen_h <= 0 || (bpp != 16 && bpp != 32) || stride <= 0) {
        logmsg("unsupported framebuffer format");
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }
    fb_len = (size_t)stride * screen_h;
    fb_mem = mmap(NULL, fb_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_mem == MAP_FAILED) {
        logmsg("framebuffer mmap failed");
        fb_mem = NULL;
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }
    fprintf(stderr, "foxkbd: framebuffer %dx%d %dbpp stride %d\n", screen_w, screen_h, bpp, stride);
    return 0;
}

static int find_touchscreen(void)
{
    DIR *dir;
    struct dirent *de;
    char path[128];
    int fd;
    unsigned long absbits[8];
    unsigned long keybits[(KEY_CNT + 8 * sizeof(unsigned long) - 1) / (8 * sizeof(unsigned long))];

    dir = opendir("/dev/input");
    if (!dir) {
        logmsg("cannot open /dev/input");
        return -1;
    }
    while ((de = readdir(dir)) != NULL) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) continue;
        memset(absbits, 0, sizeof(absbits));
        memset(keybits, 0, sizeof(keybits));
        if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) < 0) {
            close(fd);
            continue;
        }
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0) {
            close(fd);
            continue;
        }
        if (!(TEST_BIT(absbits, ABS_MT_POSITION_X) && TEST_BIT(absbits, ABS_MT_POSITION_Y)) &&
            !(TEST_BIT(absbits, ABS_X) && TEST_BIT(absbits, ABS_Y))) {
            close(fd);
            continue;
        }
        touch_use_mt = TEST_BIT(absbits, ABS_MT_POSITION_X) && TEST_BIT(absbits, ABS_MT_POSITION_Y);
        touch_xcode = touch_use_mt ? ABS_MT_POSITION_X : ABS_X;
        touch_ycode = touch_use_mt ? ABS_MT_POSITION_Y : ABS_Y;
        {
            struct input_absinfo xi, yi;
            memset(&xi, 0, sizeof(xi));
            memset(&yi, 0, sizeof(yi));
            if (ioctl(fd, EVIOCGABS(touch_xcode), &xi) < 0 ||
                ioctl(fd, EVIOCGABS(touch_ycode), &yi) < 0) {
                close(fd);
                continue;
            }
            touch_xmin = xi.minimum;
            touch_xmax = xi.maximum;
            touch_ymin = yi.minimum;
            touch_ymax = yi.maximum;
            if (touch_xmax <= touch_xmin || touch_ymax <= touch_ymin) {
                close(fd);
                continue;
            }
        }
        fprintf(stderr, "foxkbd: touchscreen %s mt=%d btn=%d x=%d..%d y=%d..%d\n",
                path, touch_use_mt, TEST_BIT(keybits, BTN_TOUCH) ? 1 : 0, touch_xmin, touch_xmax, touch_ymin, touch_ymax);
        closedir(dir);
        return fd;
    }
    closedir(dir);
    logmsg("no touchscreen found");
    return -1;
}

static int find_volume_key(void)
{
    DIR *dir;
    struct dirent *de;
    char path[128];
    int fd;
    unsigned long keybits[(KEY_CNT + 8 * sizeof(unsigned long) - 1) / (8 * sizeof(unsigned long))];

    dir = opendir("/dev/input");
    if (!dir) return -1;
    while ((de = readdir(dir)) != NULL) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        memset(keybits, 0, sizeof(keybits));
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0 ||
            !TEST_BIT(keybits, KEY_VOLUMEUP)) {
            close(fd);
            continue;
        }
        fprintf(stderr, "foxkbd: volume key device %s\n", path);
        closedir(dir);
        return fd;
    }
    closedir(dir);
    logmsg("no volume-up key device found");
    return -1;
}

static int start_browser(char **argv)
{
    int slave;
    char *slave_name;

    master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd < 0) {
        logmsg("posix_openpt failed");
        return -1;
    }
    if (grantpt(master_fd) < 0 || unlockpt(master_fd) < 0) {
        logmsg("grantpt/unlockpt failed");
        return -1;
    }
    slave_name = ptsname(master_fd);
    if (!slave_name) {
        logmsg("ptsname failed");
        return -1;
    }

    child_pid = fork();
    if (child_pid < 0) {
        logmsg("fork failed");
        return -1;
    }
    if (child_pid == 0) {
        struct termios t;
        setsid();
        slave = open(slave_name, O_RDWR);
        if (slave < 0) _exit(127);
        ioctl(slave, TIOCSCTTY, 0);
        if (tcgetattr(slave, &t) == 0) {
            cfmakeraw(&t);
            tcsetattr(slave, TCSANOW, &t);
        }
        dup2(slave, 0);
        if (slave != 0) close(slave);
        close(master_fd);
        execvp(argv[0], argv);
        _exit(127);
    }

    fcntl(master_fd, F_SETFL, fcntl(master_fd, F_GETFL, 0) | O_NONBLOCK);
    return 0;
}

static void cleanup(void)
{
    if (child_pid > 0) {
        int st;
        if (waitpid(child_pid, &st, WNOHANG) == 0) {
            kill(child_pid, SIGTERM);
            waitpid(child_pid, &st, 0);
        }
        child_pid = -1;
    }
    if (keyboard_visible && touch_fd >= 0)
        ioctl(touch_fd, EVIOCGRAB, 0);
    if (touch_fd >= 0) close(touch_fd);
    if (key_fd >= 0) close(key_fd);
    if (fb_mem && fb_mem != MAP_FAILED) munmap(fb_mem, fb_len);
    if (fb_fd >= 0) close(fb_fd);
    if (master_fd >= 0) close(master_fd);
    touch_fd = key_fd = fb_fd = master_fd = -1;
    fb_mem = NULL;
}

int main(int argc, char **argv)
{
    struct sigaction sa;
    int child_status = 0, child_done = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: foxkbd <command> [args...]\n");
        return 2;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    if (open_framebuffer() < 0) return 1;
    touch_fd = find_touchscreen();
    key_fd = find_volume_key();
    if (start_browser(&argv[1]) < 0) {
        cleanup();
        return 1;
    }

    while (!stop_requested) {
        struct pollfd pfd[2];
        int n = 0, timeout, r;
        pid_t w;

        pfd[n].fd = key_fd;
        pfd[n].events = POLLIN;
        n++;
        if (keyboard_visible && touch_fd >= 0) {
            pfd[n].fd = touch_fd;
            pfd[n].events = POLLIN;
            n++;
        }
        timeout = keyboard_visible ? 140 : 500;
        r = poll(pfd, n, timeout);
        if (r < 0 && errno != EINTR) {
            logmsg("poll failed");
            break;
        }
        if (r > 0) {
            struct input_event ev[64];
            ssize_t got;
            int i, cnt;

            if (pfd[0].revents & POLLIN) {
                got = read(key_fd, ev, sizeof(ev));
                if (got > 0) {
                    cnt = (int)(got / (ssize_t)sizeof(ev[0]));
                    for (i = 0; i < cnt; i++) volume_event(&ev[i]);
                }
            }
            if (n > 1 && (pfd[1].revents & POLLIN) && touch_fd >= 0) {
                got = read(touch_fd, ev, sizeof(ev));
                if (got > 0) {
                    cnt = (int)(got / (ssize_t)sizeof(ev[0]));
                    for (i = 0; i < cnt; i++) touch_event(&ev[i]);
                }
            }
        }

        if (keyboard_visible) draw_keyboard();

        w = waitpid(child_pid, &child_status, WNOHANG);
        if (w == child_pid) {
            child_done = 1;
            break;
        }
    }

    cleanup();
    if (child_done) {
        if (WIFEXITED(child_status)) return WEXITSTATUS(child_status);
        if (WIFSIGNALED(child_status)) return 128 + WTERMSIG(child_status);
    }
    return 0;
}
