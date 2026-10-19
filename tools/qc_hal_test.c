// qc_hal_test: test the installed QUAD-CAPTURE plug-in through the Core Audio HAL, the same way as an app.
// It records INPUT 1-2 and, with -T, plays the test tone: 440 Hz left (0.3-2.3 s), then 660 Hz right
// (2.7-4.7 s), -30 dBFS. It reports IO cycles, sample time continuity, and input levels.
//
// Usage: qc_hal_test [-s seconds] [-T] [-o output.wav] [-b buffer_frames]
//                    [-c requests,microframes,outMargin,inMargin,direct] [-q]
//   -b sets the IO buffer size of this client (frames), as an app does (for example 128).
//   -c sets the USB queue of the plug-in (custom property 'qcfg'); -q prints the plug-in configuration
//   and statistics (custom property 'qsta') and stops.
#include <CoreAudio/CoreAudio.h>
#include <getopt.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define DEVICE_UID "QuadCaptureMac:0582:012f"
#define kQCPropertyConfig 'qcfg'
#define kQCPropertyStats 'qsta'

static void printValue(CFTypeRef v) {
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        double x = 0;
        CFNumberGetValue(v, kCFNumberDoubleType, &x);
        if (x == floor(x) && fabs(x) < 1e15) printf("%.0f", x);
        else printf("%.3f", x);
    } else if (CFGetTypeID(v) == CFArrayGetTypeID()) {
        printf("[");
        for (CFIndex i = 0; i < CFArrayGetCount(v); i++) {
            if (i) printf(" ");
            printValue(CFArrayGetValueAtIndex(v, i));
        }
        printf("]");
    } else {
        printf("?");
    }
}

static int compareKeys(const void *a, const void *b) {
    return (int)CFStringCompare(*(CFStringRef const *)a, *(CFStringRef const *)b, 0);
}

static void printProperty(AudioObjectID dev, AudioObjectPropertySelector sel, const char *title) {
    AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFPropertyListRef d = NULL;
    UInt32 sz = sizeof(d);
    OSStatus r = AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d);
    if (r || !d || CFGetTypeID(d) != CFDictionaryGetTypeID()) {
        printf("%s: not available (%d)\n", title, (int)r);
        if (d) CFRelease(d);
        return;
    }
    CFIndex n = CFDictionaryGetCount(d);
    const void *keys[64], *vals[64];
    if (n > 64) n = 64;
    CFDictionaryGetKeysAndValues(d, keys, vals);
    qsort(keys, n, sizeof(keys[0]), compareKeys);
    printf("%s:\n", title);
    for (CFIndex i = 0; i < n; i++) {
        char k[64];
        CFStringGetCString(keys[i], k, sizeof k, kCFStringEncodingUTF8);
        printf("  %-18s ", k);
        printValue(CFDictionaryGetValue(d, keys[i]));
        printf("\n");
    }
    CFRelease(d);
}

static int setConfig(AudioObjectID dev, const char *spec) {
    int v[5];
    if (sscanf(spec, "%d,%d,%d,%d,%d", &v[0], &v[1], &v[2], &v[3], &v[4]) != 5) {
        fprintf(stderr, "-c needs 5 numbers: requests,microframes,outMargin,inMargin,direct\n");
        return -1;
    }
    static const char *names[5] = {"requests", "microframes", "outputMargin", "inputMargin", "direct"};
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 5; i++) {
        CFStringRef k = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v[i]);
        CFDictionarySetValue(d, k, n);
        CFRelease(k);
        CFRelease(n);
    }
    AudioObjectPropertyAddress a = {kQCPropertyConfig, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus r = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(d), &d);
    CFRelease(d);
    if (r) { fprintf(stderr, "setting 'qcfg' failed: %d\n", (int)r); return -1; }
    // The plug-in applies the change in a device configuration change: wait for the new safety offset.
    for (int i = 0; i < 30; i++) {
        usleep(100000);
        AudioObjectPropertyAddress c = {kQCPropertyConfig, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFPropertyListRef cur = NULL;
        UInt32 sz = sizeof(cur);
        if (AudioObjectGetPropertyData(dev, &c, 0, NULL, &sz, &cur) == 0 && cur) {
            int req = 0, mf = 0;
            CFNumberGetValue(CFDictionaryGetValue(cur, CFSTR("requests")), kCFNumberIntType, &req);
            CFNumberGetValue(CFDictionaryGetValue(cur, CFSTR("microframes")), kCFNumberIntType, &mf);
            CFRelease(cur);
            if (req == v[0] && mf == v[1]) return 0;
        }
    }
    fprintf(stderr, "the plug-in did not apply the configuration in 3 s\n");
    return -1;
}

typedef struct {
    float *cap;
    size_t capMax;
    _Atomic size_t capFrames;
    _Atomic uint64_t calls, inDiscont, outDiscont;
    double nextIn, nextOut, outStart;
    double rateMin, rateMax;
    UInt32 lastFrames;
    int tone;
} Ctx;

static float toneSample(double t, int channel) {
    const double amp = pow(10.0, -30.0 / 20.0), fade = 0.03;
    double start = channel == 0 ? 0.3 : 2.7, end = start + 2.0, freq = channel == 0 ? 440.0 : 660.0;
    if (t < start || t >= end) return 0.0f;
    double a = t - start, b = end - t, env = 1.0;
    if (a < fade) env = 0.5 - 0.5 * cos(M_PI * a / fade);
    if (b < fade) env = 0.5 - 0.5 * cos(M_PI * b / fade);
    return (float)(amp * env * sin(2.0 * M_PI * freq * a));
}

static OSStatus ioProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                       const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime, void *p) {
    (void)dev; (void)now;
    Ctx *c = p;
    atomic_fetch_add(&c->calls, 1);
    if (in && in->mNumberBuffers > 0 && in->mBuffers[0].mData) {
        const AudioBuffer *b = &in->mBuffers[0];
        UInt32 ch = b->mNumberChannels ? b->mNumberChannels : 2;
        UInt32 frames = b->mDataByteSize / (sizeof(float) * ch);
        c->lastFrames = frames;
        if (c->nextIn >= 0 && fabs(inTime->mSampleTime - c->nextIn) > 0.5) atomic_fetch_add(&c->inDiscont, 1);
        c->nextIn = inTime->mSampleTime + frames;
        if (inTime->mFlags & kAudioTimeStampRateScalarValid) {
            if (inTime->mRateScalar < c->rateMin) c->rateMin = inTime->mRateScalar;
            if (inTime->mRateScalar > c->rateMax) c->rateMax = inTime->mRateScalar;
        }
        size_t n = atomic_load(&c->capFrames);
        const float *src = b->mData;
        for (UInt32 i = 0; i < frames && n < c->capMax; i++, n++) {
            c->cap[n * 2] = src[i * ch];
            c->cap[n * 2 + 1] = ch > 1 ? src[i * ch + 1] : 0.0f;
        }
        atomic_store(&c->capFrames, n);
    }
    if (out && out->mNumberBuffers > 0 && out->mBuffers[0].mData) {
        AudioBuffer *b = &out->mBuffers[0];
        UInt32 ch = b->mNumberChannels ? b->mNumberChannels : 2;
        UInt32 frames = b->mDataByteSize / (sizeof(float) * ch);
        if (c->nextOut >= 0 && fabs(outTime->mSampleTime - c->nextOut) > 0.5) atomic_fetch_add(&c->outDiscont, 1);
        c->nextOut = outTime->mSampleTime + frames;
        if (c->outStart < 0) c->outStart = outTime->mSampleTime;
        float *dst = b->mData;
        for (UInt32 i = 0; i < frames; i++) {
            double t = (outTime->mSampleTime + i - c->outStart) / 44100.0;
            for (UInt32 k = 0; k < ch; k++) dst[i * ch + k] = (c->tone && k < 2) ? toneSample(t, (int)k) : 0.0f;
        }
    }
    return noErr;
}

static UInt32 getU32(AudioObjectID dev, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0, sz = sizeof(v);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &v);
    return v;
}

static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

int main(int argc, char **argv) {
    double seconds = 5.0;
    int tone = 0;
    const char *outPath = "recordings/hal-test-in1-2.wav";
    int opt, queryOnly = 0;
    UInt32 bufferFrames = 0;
    const char *config = NULL;
    while ((opt = getopt(argc, argv, "s:To:c:qb:")) != -1) {
        if (opt == 'b') { bufferFrames = (UInt32)atoi(optarg); continue; }
        if (opt == 's') seconds = atof(optarg);
        else if (opt == 'T') tone = 1;
        else if (opt == 'o') outPath = optarg;
        else if (opt == 'c') config = optarg;
        else if (opt == 'q') queryOnly = 1;
        else { fprintf(stderr, "usage: qc_hal_test [-s seconds] [-T] [-o output.wav] [-b frames] [-c r,m,out,in,direct] [-q]\n"); return 2; }
    }
    if (tone && seconds < 5.0) seconds = 5.0;

    CFStringRef uid = CFSTR(DEVICE_UID);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    OSStatus r = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev);
    if (r || dev == kAudioObjectUnknown) {
        fprintf(stderr, "The QUAD-CAPTURE device is not in Core Audio (is the plug-in installed?)\n");
        return 1;
    }
    if (config && setConfig(dev, config)) return 1;
    if (queryOnly) {
        printProperty(dev, kQCPropertyConfig, "Configuration");
        printProperty(dev, kQCPropertyStats, "Statistics");
        return 0;
    }
    if (bufferFrames) {
        AudioObjectPropertyAddress b = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        OSStatus br = AudioObjectSetPropertyData(dev, &b, 0, NULL, sizeof(bufferFrames), &bufferFrames);
        if (br) fprintf(stderr, "setting the buffer size failed: %d\n", (int)br);
    }
    printf("Device %u: buffer %u frames; safety offset in/out %u/%u; latency in/out %u/%u\n", dev,
           getU32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
           getU32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
           getU32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
           getU32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
           getU32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput));

    Ctx c = {0};
    c.capMax = (size_t)((seconds + 1) * 44100);
    c.cap = calloc(c.capMax * 2, sizeof(float));
    c.nextIn = c.nextOut = c.outStart = -1;
    c.rateMin = 1e9;
    c.rateMax = -1e9;
    c.tone = tone;

    AudioDeviceIOProcID procID = NULL;
    r = AudioDeviceCreateIOProcID(dev, ioProc, &c, &procID);
    if (r) { fprintf(stderr, "AudioDeviceCreateIOProcID failed: %d\n", (int)r); return 1; }
    r = AudioDeviceStart(dev, procID);
    if (r) { fprintf(stderr, "AudioDeviceStart failed: %d\n", (int)r); return 1; }
    printf("%s for %.1f s ...\n", tone ? "Playing the tone and recording" : "Recording", seconds);
    usleep((useconds_t)(seconds * 1e6));
    AudioDeviceStop(dev, procID);
    AudioDeviceDestroyIOProcID(dev, procID);

    size_t frames = atomic_load(&c.capFrames);
    printf("IO cycles: %llu (%u frames each); input frames %zu (%.2f s); sample time breaks in/out: %llu/%llu\n",
           atomic_load(&c.calls), c.lastFrames, frames, frames / 44100.0, atomic_load(&c.inDiscont),
           atomic_load(&c.outDiscont));
    if (c.rateMax > 0) printf("Rate scalar: %.6f .. %.6f\n", c.rateMin, c.rateMax);
    for (int ch = 0; ch < 2; ch++) {
        double peak = 0, sum = 0;
        for (size_t i = 0; i < frames; i++) {
            double v = c.cap[i * 2 + ch];
            if (fabs(v) > peak) peak = fabs(v);
            sum += v * v;
        }
        printf("  input %d: peak %6.1f dBFS, rms %6.1f dBFS\n", ch + 1, peak > 0 ? 20 * log10(peak) : -INFINITY,
               sum > 0 ? 10 * log10(sum / frames) : -INFINITY);
    }
    printProperty(dev, kQCPropertyStats, "Plug-in statistics");
    FILE *f = fopen(outPath, "wb");
    if (f) {
        uint32_t bytes = (uint32_t)(frames * 2 * 3);
        fwrite("RIFF", 1, 4, f); put32(f, 36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
        put32(f, 16); put16(f, 1); put16(f, 2); put32(f, 44100); put32(f, 44100 * 6); put16(f, 6); put16(f, 24);
        fwrite("data", 1, 4, f); put32(f, bytes);
        for (size_t i = 0; i < frames * 2; i++) {
            float v = c.cap[i] > 1 ? 1 : (c.cap[i] < -1 ? -1 : c.cap[i]);
            int32_t x = (int32_t)lrintf(v * 8388607.0f);
            uint8_t b[3] = {(uint8_t)x, (uint8_t)(x >> 8), (uint8_t)(x >> 16)};
            fwrite(b, 1, 3, f);
        }
        fclose(f);
        printf("Wrote %s\n", outPath);
    }
    return 0;
}
