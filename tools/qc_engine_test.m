// qc_engine_test: use qc_engine the same way as the Core Audio plug-in, without Core Audio.
// A loop that runs every 2 ms follows the device clock from the zero timestamps, writes the
// output qc_engine_output_lead_frames() early, and reads the input qc_engine_input_delay_frames() late.
//
// Usage: qc_engine_test [-s seconds] [-T] [-o output_dir] [-n requests] [-t microframes]
//                       [-m output_margin_frames] [-i input_margin_frames] [-r rate]
//   -r sets the sample rate: 44100 (default), 48000, 96000 or 192000 Hz.
//   -T plays the test tone: 440 Hz left (0.3-2.3 s), then 660 Hz right (2.7-4.7 s), -30 dBFS.
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <getopt.h>
#include "engine/qc_engine.h"

static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

static void writeWav24(const char *path, const float *s, size_t frames, int ch, uint32_t rate) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    uint32_t bytes = (uint32_t)(frames * ch * 3);
    fwrite("RIFF", 1, 4, f); put32(f, 36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16); put16(f, 1); put16(f, ch); put32(f, rate); put32(f, rate * ch * 3); put16(f, ch * 3); put16(f, 24);
    fwrite("data", 1, 4, f); put32(f, bytes);
    for (size_t i = 0; i < frames * ch; i++) {
        float v = s[i] > 1.0f ? 1.0f : (s[i] < -1.0f ? -1.0f : s[i]);
        int32_t x = (int32_t)lrintf(v * 8388607.0f);
        uint8_t b[3] = {(uint8_t)x, (uint8_t)(x >> 8), (uint8_t)(x >> 16)};
        fwrite(b, 1, 3, f);
    }
    fclose(f);
}

static double dbfs(double v) { return v > 0 ? 20.0 * log10(v) : -INFINITY; }

int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = 5.0;
        bool tone = false;
        NSString *outDir = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"recordings"];
        int ch, nReq = 0, tpr = 0;
        int outMargin = -1, inMargin = -1;
        while ((ch = getopt(argc, argv, "s:To:n:t:m:i:d:r:")) != -1) {
            if (ch == 'd') { qc_engine_set_direct(atoi(optarg)); continue; }
            if (ch == 'r') {
                if (!qc_engine_set_rate((uint32_t)atoi(optarg))) { fprintf(stderr, "unsupported rate\n"); return 2; }
                continue;
            }
            if (ch == 's') seconds = atof(optarg);
            else if (ch == 'T') tone = true;
            else if (ch == 'o') outDir = @(optarg);
            else if (ch == 'n') nReq = atoi(optarg);
            else if (ch == 't') tpr = atoi(optarg);
            else if (ch == 'm') outMargin = atoi(optarg);
            else if (ch == 'i') inMargin = atoi(optarg);
            else { fprintf(stderr, "usage: qc_engine_test [-s seconds] [-T] [-o dir] [-n requests] [-t microframes] [-m out_margin] [-i in_margin] [-r rate]\n"); return 2; }
        }
        if (nReq || tpr || outMargin >= 0 || inMargin >= 0)
            qc_engine_configure(nReq ? nReq : 8, tpr ? tpr : 128, outMargin >= 0 ? outMargin : 44, inMargin >= 0 ? inMargin : 44);
        const double rate = qc_engine_get_rate();
        const int64_t lead = qc_engine_output_lead_frames(), delay = qc_engine_input_delay_frames();
        printf("%.0f Hz. Output lead %lld frames (%.1f ms), input delay %lld frames (%.1f ms)\n", rate, lead,
               lead * 1000.0 / rate, delay, delay * 1000.0 / rate);
        if (tone && seconds < 5.0) seconds = 5.0;

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        const double ticksPerFrame = 1e9 / rate * tb.denom / tb.numer;

        uint64_t t0 = mach_absolute_time();
        // The loop below runs in real time, as the Core Audio IO thread does (2 ms period).
        {
            thread_time_constraint_policy_data_t pol;
            const double ticksPerUs = 1000.0 * tb.denom / tb.numer;
            pol.period = (uint32_t)(2000 * ticksPerUs);
            pol.computation = (uint32_t)(300 * ticksPerUs);
            pol.constraint = (uint32_t)(1000 * ticksPerUs);
            pol.preemptible = 1;
            if (thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                                  THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS)
                fprintf(stderr, "real-time policy refused\n");
        }
        int rc = qc_engine_start();
        double startMs = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
        if (rc) { fprintf(stderr, "qc_engine_start failed: %d (see: log show --last 1m --predicate 'subsystem == \"com.louistissot.quadcapture\"')\n", rc); return 1; }
        printf("Engine started in %.0f ms\n", startMs);

        size_t capMax = (size_t)((seconds + 1) * rate);
        float *cap = calloc(capMax * QC_IN_CHANNELS, sizeof(float));
        size_t capFrames = 0;
        float buf[1024 * 4];
        int64_t outPos = INT64_MIN, inPos = INT64_MIN, outStart = 0;
        double lastZeroSample = -1;
        int zeroBackwards = 0;
        uint64_t loops = 0;
        // Input lag: frames between the current sample time and the end of the data in the ring.
        double lagMax = 0, lagSum = 0;
        int lagHist[8] = {0};   // < 512, < 1024, < 1536, < 2048, < 3072, < 4096, < 8192, more
        uint64_t lastMissing = 0;
        int missEvents = 0;
        double missAt[16];

        uint64_t tEnd = mach_absolute_time() + (uint64_t)(seconds * 1e9 * tb.denom / tb.numer);
        while (mach_absolute_time() < tEnd) {
            usleep(2000);
            loops++;
            double zs; uint64_t zh, seed;
            if (!qc_engine_zero_timestamp(&zs, &zh, &seed)) { fprintf(stderr, "engine stopped\n"); break; }
            if (zs < lastZeroSample) zeroBackwards++;
            lastZeroSample = zs;
            uint64_t now = mach_absolute_time();
            double cur = zs + ((double)now - (double)zh) / ticksPerFrame;
            QCEngineStats ls;
            qc_engine_get_stats(&ls);
            double lag = cur - (double)ls.inputFrames;
            if (lag > lagMax) lagMax = lag;
            lagSum += lag;
            static const double edges[7] = {512, 1024, 1536, 2048, 3072, 4096, 8192};
            int b = 0;
            while (b < 7 && lag >= edges[b]) b++;
            lagHist[b]++;
            if (ls.inputMissing != lastMissing) {
                if (missEvents < 16) missAt[missEvents] = cur / rate;
                missEvents++;
                lastMissing = ls.inputMissing;
            }

            // Output: write lead early, in chunks of up to 1024 frames.
            int64_t want = (int64_t)cur + lead + 512;
            if (outPos == INT64_MIN) outPos = outStart = (int64_t)cur + lead;
            while (outPos < want) {
                uint32_t n = (uint32_t)MIN(1024, want - outPos);
                for (uint32_t i = 0; i < n; i++) {
                    double t = (double)(outPos + i - outStart) / rate;
                    float l = 0, r = 0;
                    if (tone) {
                        const double amp = pow(10.0, -30.0 / 20.0), fade = 0.03;
                        if (t >= 0.3 && t < 2.3) {
                            double a = t - 0.3, b = 2.3 - t, env = 1;
                            if (a < fade) env = 0.5 - 0.5 * cos(M_PI * a / fade);
                            if (b < fade) env = 0.5 - 0.5 * cos(M_PI * b / fade);
                            l = (float)(amp * env * sin(2 * M_PI * 440.0 * a));
                        } else if (t >= 2.7 && t < 4.7) {
                            double a = t - 2.7, b = 4.7 - t, env = 1;
                            if (a < fade) env = 0.5 - 0.5 * cos(M_PI * a / fade);
                            if (b < fade) env = 0.5 - 0.5 * cos(M_PI * b / fade);
                            r = (float)(amp * env * sin(2 * M_PI * 660.0 * a));
                        }
                    }
                    for (int c = 0; c < QC_OUT_CHANNELS; c++) buf[i * QC_OUT_CHANNELS + c] = 0.0f;
                    buf[i * QC_OUT_CHANNELS] = l;
                    buf[i * QC_OUT_CHANNELS + 1] = r;
                }
                qc_engine_write_output(outPos, n, buf);
                outPos += n;
            }

            // Input: read delay late.
            int64_t avail = (int64_t)cur - delay;
            if (inPos == INT64_MIN) inPos = avail;
            while (inPos < avail && capFrames < capMax) {
                uint32_t n = (uint32_t)MIN(1024, MIN(avail - inPos, (int64_t)(capMax - capFrames)));
                qc_engine_read_input(inPos, n, cap + capFrames * QC_IN_CHANNELS);
                capFrames += n;
                inPos += n;
            }
        }

        QCEngineStats st;
        qc_engine_get_stats(&st);
        qc_engine_stop();

        printf("Loops: %llu; zero timestamps: %llu (backwards: %d); measured device rate: %.2f Hz\n",
               loops, st.zeroTimestamps, zeroBackwards, st.measuredRate);
        printf("Input lag (frames behind real time): average %.0f, maximum %.0f; histogram <512:%d <1024:%d <1536:%d <2048:%d <3072:%d <4096:%d <8192:%d more:%d\n",
               lagSum / (loops ? loops : 1), lagMax, lagHist[0], lagHist[1], lagHist[2], lagHist[3], lagHist[4],
               lagHist[5], lagHist[6], lagHist[7]);
        if (missEvents) {
            printf("Missing input seen at (s):");
            for (int i = 0; i < missEvents && i < 16; i++) printf(" %.3f", missAt[i]);
            printf("\n");
        }
        static const char *bk[QC_LAG_BUCKETS] = {"<0.5", "<1", "<2", "<4", "<8", "<16", "<32", ">=32"};
        printf("Callback lag after the end of a request (ms): capture max %.2f, playback max %.2f\n  capture: ",
               st.inLagMaxMs, st.outLagMaxMs);
        for (int b = 0; b < QC_LAG_BUCKETS; b++) printf(" %s:%llu", bk[b], st.inLagHist[b]);
        printf("\n  playback:");
        for (int b = 0; b < QC_LAG_BUCKETS; b++) printf(" %s:%llu", bk[b], st.outLagHist[b]);
        printf("\nResyncs: %llu, gap frames: %llu; direct %llu, ring %llu, races %llu; callback priority %d, scanner priority %d\n",
               st.resyncs, st.gapFrames, st.directFrames, st.ringFrames, st.races, st.callbackPriority, st.scannerPriority);
        printf("Input frames: %llu, missing: %llu, empty packets: %llu; output late: %llu; USB errors in/out: %llu/%llu\n",
               st.inputFrames, st.inputMissing, st.emptyPackets, st.outputLate, st.inErrors, st.outErrors);
        for (int c = 0; c < QC_IN_CHANNELS; c++) {
            double peak = 0, sum = 0;
            for (size_t i = 0; i < capFrames; i++) {
                double v = cap[i * QC_IN_CHANNELS + c];
                if (fabs(v) > peak) peak = fabs(v);
                sum += v * v;
            }
            printf("  input %d: peak %6.1f dBFS, rms %6.1f dBFS\n", c + 1, dbfs(peak), dbfs(sqrt(sum / (capFrames ? capFrames : 1))));
        }
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [outDir stringByAppendingPathComponent:@"engine-test-in1-2.wav"];
        writeWav24(path.UTF8String, cap, capFrames, QC_IN_CHANNELS, (uint32_t)rate);
        printf("Wrote %s (%.2f s)\n", path.UTF8String, capFrames / rate);
    }
    return 0;
}
