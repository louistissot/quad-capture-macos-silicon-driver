// qc_midi_test: test the QUAD-CAPTURE MIDI driver through CoreMIDI, the same way as an app.
//
// Usage: qc_midi_test [-l] [-r seconds] [-n] [-x]
//   -l          list the MIDI sources and destinations
//   -r seconds  print the messages that arrive at QUAD-CAPTURE MIDI IN
//   -n          send a short test melody to QUAD-CAPTURE MIDI OUT (channel 1)
//   -x          loopback test: needs a MIDI cable from MIDI OUT to MIDI IN; sends notes and SysEx
//               of several sizes and compares what comes back
#include <CoreMIDI/CoreMIDI.h>
#include <getopt.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint8_t gRx[65536];
static _Atomic size_t gRxLen;
static bool gPrint;

static bool nameIs(MIDIEndpointRef e, const char *want) {
    CFStringRef name = NULL;
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name);
    char buf[256] = "";
    if (name) { CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(name); }
    return strstr(buf, want) != NULL;
}

static void printName(const char *kind, MIDIEndpointRef e) {
    CFStringRef name = NULL;
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name);
    char buf[256] = "?";
    if (name) { CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(name); }
    SInt32 offline = 0;
    MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &offline);
    printf("  %s: %s%s\n", kind, buf, offline ? " (offline)" : "");
}

static void readProc(const MIDIPacketList *list, void *refCon, void *srcRef) {
    (void)refCon; (void)srcRef;
    const MIDIPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        size_t n = atomic_load(&gRxLen);
        if (n + p->length <= sizeof gRx) {
            memcpy(gRx + n, p->data, p->length);
            atomic_store(&gRxLen, n + p->length);
        }
        if (gPrint) {
            printf("  IN:");
            for (UInt16 k = 0; k < p->length && k < 32; k++) printf(" %02X", p->data[k]);
            printf(p->length > 32 ? " ... (%u bytes)\n" : "\n", p->length);
            fflush(stdout);
        }
        p = MIDIPacketNext(p);
    }
}

static void sendBytes(MIDIPortRef port, MIDIEndpointRef dest, const uint8_t *b, size_t n) {
    Byte buf[70000];
    MIDIPacketList *list = (MIDIPacketList *)buf;
    MIDIPacket *p = MIDIPacketListInit(list);
    p = MIDIPacketListAdd(list, sizeof buf, p, 0, n, b);
    if (p) MIDISend(port, dest, list);
}

int main(int argc, char **argv) {
    bool list = false, melody = false, loop = false;
    double recvSeconds = 0;
    int ch;
    while ((ch = getopt(argc, argv, "lr:nx")) != -1) {
        if (ch == 'l') list = true;
        else if (ch == 'r') recvSeconds = atof(optarg);
        else if (ch == 'n') melody = true;
        else if (ch == 'x') loop = true;
        else { fprintf(stderr, "usage: qc_midi_test [-l] [-r seconds] [-n] [-x]\n"); return 2; }
    }
    if (!list && !recvSeconds && !melody && !loop) list = true;

    MIDIClientRef client;
    MIDIPortRef in, out;
    MIDIClientCreate(CFSTR("qc_midi_test"), NULL, NULL, &client);
    MIDIInputPortCreate(client, CFSTR("in"), readProc, NULL, &in);
    MIDIOutputPortCreate(client, CFSTR("out"), &out);

    MIDIEndpointRef src = 0, dst = 0;
    if (list) printf("Sources:\n");
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
        MIDIEndpointRef e = MIDIGetSource(i);
        if (list) printName("source", e);
        if (!src && nameIs(e, "QUAD-CAPTURE")) src = e;
    }
    if (list) printf("Destinations:\n");
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) {
        MIDIEndpointRef e = MIDIGetDestination(i);
        if (list) printName("destination", e);
        if (!dst && nameIs(e, "QUAD-CAPTURE")) dst = e;
    }
    if ((recvSeconds || loop) && !src) { fprintf(stderr, "No QUAD-CAPTURE MIDI source.\n"); return 1; }
    if ((melody || loop) && !dst) { fprintf(stderr, "No QUAD-CAPTURE MIDI destination.\n"); return 1; }
    if (src) MIDIPortConnectSource(in, src, NULL);

    if (melody) {
        static const uint8_t notes[] = {60, 64, 67, 72, 67, 64, 60};
        printf("Sending a melody to QUAD-CAPTURE MIDI OUT (channel 1) ...\n");
        for (size_t i = 0; i < sizeof notes; i++) {
            uint8_t on[3] = {0x90, notes[i], 90}, off[3] = {0x80, notes[i], 0};
            sendBytes(out, dst, on, 3);
            usleep(250000);
            sendBytes(out, dst, off, 3);
            usleep(50000);
        }
    }
    if (recvSeconds) {
        gPrint = true;
        printf("Messages at QUAD-CAPTURE MIDI IN for %.0f s:\n", recvSeconds);
        fflush(stdout);
        usleep((useconds_t)(recvSeconds * 1e6));
    }
    if (loop) {
        // Notes, a pitch bend, and SysEx messages of 2 to 300 bytes.
        uint8_t msg[400];
        size_t n = 0;
        uint8_t expect[8192];
        size_t en = 0;
        int fails = 0;
        atomic_store(&gRxLen, 0);
        const uint8_t notes[] = {0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00, 0xE0, 0x00, 0x40, 0xC5, 0x10};
        sendBytes(out, dst, notes, sizeof notes);
        memcpy(expect + en, notes, sizeof notes);
        en += sizeof notes;
        static const size_t sizes[] = {2, 3, 4, 5, 6, 7, 8, 16, 33, 100, 300};
        for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
            n = sizes[s];
            msg[0] = 0xF0;
            for (size_t k = 1; k + 1 < n; k++) msg[k] = (uint8_t)((k * 7 + s) & 0x7F);
            msg[n - 1] = 0xF7;
            sendBytes(out, dst, msg, n);
            memcpy(expect + en, msg, n);
            en += n;
            usleep(20000);
        }
        usleep(500000);
        size_t got = atomic_load(&gRxLen);
        bool ok = got == en && memcmp(gRx, expect, en) == 0;
        if (!ok) {
            fails++;
            printf("Loopback: sent %zu bytes, received %zu bytes\n", en, got);
            for (size_t i = 0; i < en && i < got; i++)
                if (gRx[i] != expect[i]) { printf("  first difference at byte %zu: %02X != %02X\n", i, gRx[i], expect[i]); break; }
        }
        printf("Loopback test: %s (%zu bytes: notes, pitch bend, program change, 11 SysEx messages)\n",
               ok ? "PASSED" : "FAILED", en);
        return fails ? 1 : 0;
    }
    return 0;
}
