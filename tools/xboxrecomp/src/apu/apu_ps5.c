/**
 * PS5 Audio Output Backend (__PROSPERO__) - the xa2_* contract on sceAudioOut.
 *
 * [ps5 port] elripalda/defjam-ps5 kept this backend inside apu_xaudio2.c's
 * non-Windows half (v0.9.3). Upstream moved the POSIX backends into
 * apu_sdl2.c/apu_sdl3.c and now paces the APU from the device queue
 * (mcpx_apu_pace_step reads xa2_queued_samples), so blz/ps5-1.1.2 (Kaoz625)
 * moves it here and adds the queue/underrun/played counters that contract asks
 * for. The ring, the pre-roll, the fades and the output thread are elripalda's.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "apu_xaudio2.h"

#if defined(__PROSPERO__)

#include <pthread.h>
#include <sched.h>
#include <unistd.h>

int32_t sceAudioOutInit(void);
int32_t sceAudioOutOpen(int32_t user_id, int32_t type, int32_t index, uint32_t len,
                        uint32_t freq, uint32_t param);
int32_t sceAudioOutOutput(int32_t handle, const void *ptr);
int32_t sceAudioOutClose(int32_t handle);

#define XA2_SAMPLE_RATE   48000
#define XA2_CHANNELS      2
#define XA2_BUF_SAMPLES   1024   /* ~21ms per submission */
#define XA2_NUM_BUFS      4      /* pacing mark: high = 4096 frames, low = 2048 */
#define RING_FRAMES       8192   /* power of two, well over what is ever queued */
/* The device starts, and starts again after running out, once this much is
 * waiting. One more submission of slack each way than the desktop (the console
 * has no device queue of its own between this ring and the output). */
#define XA2_PREROLL       (3 * XA2_BUF_SAMPLES)
#define XA2_RING_MAX      (5 * XA2_BUF_SAMPLES)

static int g_dev;                            /* the audio port's handle + 1 */
static pthread_mutex_t g_ring_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t g_out_thread;
static volatile int g_out_running;
static int16_t  g_ring[RING_FRAMES][XA2_CHANNELS];
static unsigned g_ring_r, g_ring_w;          /* frame counters, free-running */
static uint64_t g_played;                    /* frames handed to the port */
static int g_xa2_initialized;
static int g_xa2_frames_written;
static int g_dry;                            /* the output is in a gap */
static int g_primed;                         /* enough is queued to play from */
static int g_drain_expected;                 /* xa2_expect_drain: the next gap is not an underrun */
int  g_xa2_dropped, g_xa2_starved;

/* A gap starts and ends with a 64-frame ramp, so neither edge clicks. */
#define XA2_FADE 64
static int16_t g_last_out[XA2_CHANNELS];
static int     g_fade_in;

static void fade_out_into(int16_t (*out)[XA2_CHANNELS], unsigned n)
{
    unsigned i, c, k = n < XA2_FADE ? n : XA2_FADE;
    for (i = 0; i < n; i++)
        for (c = 0; c < XA2_CHANNELS; c++)
            out[i][c] = i < k ? (int16_t)((int)g_last_out[c] * (int)(k - 1 - i) / (int)k) : 0;
    for (c = 0; c < XA2_CHANNELS; c++)
        g_last_out[c] = 0;
}

/* Fill `want` frames from the ring (called with g_ring_lock held). */
static void ring_pull(int16_t (*out)[XA2_CHANNELS], unsigned want)
{
    unsigned have = g_ring_w - g_ring_r, i;

    if (!g_primed) {
        if (have < XA2_PREROLL) {
            fade_out_into(out, want);
            return;
        }
        g_primed = 1;
        g_fade_in = XA2_FADE;
    }
    if (have > want)
        have = want;
    for (i = 0; i < have; i++)
        memcpy(out[i], g_ring[(g_ring_r + i) % RING_FRAMES], sizeof out[i]);
    g_ring_r += have;
    g_played += have;
    for (i = 0; i < have && g_fade_in > 0; i++, g_fade_in--) {
        unsigned c;
        int gain = XA2_FADE - g_fade_in + 1;         /* 1..64 of 64 */
        for (c = 0; c < XA2_CHANNELS; c++)
            out[i][c] = (int16_t)((int)out[i][c] * gain / XA2_FADE);
    }
    if (have > 0)
        memcpy(g_last_out, out[have - 1], sizeof g_last_out);
    if (have < want) {
        fade_out_into(out + have, want - have);
        if (!g_dry && g_xa2_frames_written > 0) {
            g_dry = 1;
            if (!g_drain_expected)
                g_xa2_starved++;
        }
        g_primed = 0;
    } else {
        g_dry = 0;
        g_drain_expected = 0;
    }
}

/* sceAudioOutOutput blocks until the previous buffer has started playing, so
 * this loop runs at exactly the output rate: 256 frames, 5.3 ms. */
#define PS5_GRAIN 256
static void *ps5_out_thread(void *unused)
{
    static int16_t buf[PS5_GRAIN][XA2_CHANNELS] __attribute__((aligned(256)));
    extern void ps5_prof_register(const char *name) __attribute__((weak));
    extern void ps5_off_guest_cpu(void) __attribute__((weak));
    unsigned failures = 0;
    (void)unused;
    if (ps5_prof_register)
        ps5_prof_register("audio out");
    {
        /* Off the title's CPU and ahead of the other host threads: a late
         * return is a click the ring cannot see. */
        struct sched_param sp;
        int e;
        if (ps5_off_guest_cpu)
            ps5_off_guest_cpu();
        memset(&sp, 0, sizeof sp);
        sp.sched_priority = 650;
        e = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
        fprintf(stderr, "[XA2] output thread priority 650 (%s)\n", e ? "refused" : "ok");
    }
    while (g_out_running) {
        int r;
        pthread_mutex_lock(&g_ring_lock);
        ring_pull(buf, PS5_GRAIN);
        pthread_mutex_unlock(&g_ring_lock);
        r = sceAudioOutOutput(g_dev - 1, buf);
        if (r < 0) {
            if (failures++ < 4)
                fprintf(stderr, "[XA2] sceAudioOutOutput failed (0x%x)\n", (unsigned)r);
            usleep(5000);
        }
    }
    return NULL;
}

int xa2_init(void)
{
    int port;
    if (g_xa2_initialized)
        return 1;
    sceAudioOutInit();   /* already initialised by someone else is fine */
    port = sceAudioOutOpen(0xFF /* system user */, 0 /* main */, 0, PS5_GRAIN,
                           XA2_SAMPLE_RATE, 1 /* s16 stereo */);
    if (port < 0) {
        fprintf(stderr, "[XA2] sceAudioOutOpen failed (0x%x)\n", (unsigned)port);
        return 0;
    }
    g_dev = port + 1;
    g_out_running = 1;
    if (pthread_create(&g_out_thread, NULL, ps5_out_thread, NULL) != 0) {
        sceAudioOutClose(port);
        g_dev = 0;
        return 0;
    }
    g_xa2_initialized = 1;
    g_xa2_frames_written = 0;
    fprintf(stderr, "[XA2] PS5 audio output initialized (%d Hz, %d channels, port %d)\n",
            XA2_SAMPLE_RATE, XA2_CHANNELS, port);
    return 1;
}

void xa2_shutdown(void)
{
    if (g_out_running) {
        g_out_running = 0;
        pthread_join(g_out_thread, NULL);
    }
    if (g_dev) {
        sceAudioOutClose(g_dev - 1);
        g_dev = 0;
    }
    if (g_xa2_initialized)
        fprintf(stderr, "[XA2] Shut down (%d frames written)\n", g_xa2_frames_written);
    g_xa2_initialized = 0;
}

int xa2_is_active(void) { return g_xa2_initialized; }

int xa2_submit_samples(const int16_t *samples, int num_samples)
{
    unsigned n = (unsigned)(num_samples > XA2_BUF_SAMPLES ? XA2_BUF_SAMPLES : num_samples), i;
    int ok = 1;

    if (!g_xa2_initialized || !g_dev)
        return 0;
    {
        static int told, seen;
        if (g_xa2_starved != seen && told < 60) {
            fprintf(stderr, "[XA2] the device ran dry (gap %d, %d frames written, %d submissions refused)\n",
                    g_xa2_starved, g_xa2_frames_written, g_xa2_dropped);
            told++;
        }
        seen = g_xa2_starved;
    }
    pthread_mutex_lock(&g_ring_lock);
    if (g_ring_w - g_ring_r + n > XA2_RING_MAX) {
        g_xa2_dropped++;
        ok = 0;
    } else {
        for (i = 0; i < n; i++)
            memcpy(g_ring[(g_ring_w + i) % RING_FRAMES], samples + i * XA2_CHANNELS,
                   sizeof g_ring[0]);
        g_ring_w += n;
        g_xa2_frames_written++;
    }
    pthread_mutex_unlock(&g_ring_lock);
    return ok;
}

int xa2_get_buffer_size(void) { return XA2_BUF_SAMPLES; }
int xa2_get_buffer_count(void) { return XA2_NUM_BUFS; }

int xa2_queued_samples(void)
{
    unsigned q;
    if (!g_xa2_initialized) return 0;
    pthread_mutex_lock(&g_ring_lock);
    q = g_ring_w - g_ring_r;
    pthread_mutex_unlock(&g_ring_lock);
    return (int)q;
}

void xa2_expect_drain(void) { g_drain_expected = 1; }

unsigned xa2_underruns(void) { return (unsigned)g_xa2_starved; }

uint64_t xa2_samples_played(void)
{
    uint64_t p;
    pthread_mutex_lock(&g_ring_lock);
    p = g_played;
    pthread_mutex_unlock(&g_ring_lock);
    return p;
}

#endif /* __PROSPERO__ */
