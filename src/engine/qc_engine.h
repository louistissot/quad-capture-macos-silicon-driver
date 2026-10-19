// qc_engine: USB audio engine for the Roland QUAD-CAPTURE (0582:012f), 44.1 kHz.
//
// The engine streams capture and playback through IOUSBHost and exchanges audio with its client
// through two ring buffers indexed by device sample time. Sample time 0 is the first capture
// frame after the stream is stable. The engine publishes zero timestamps (sample time, host time)
// from the capture packets, so the client clock follows the device clock.
//
// Thread model:
//   qc_engine_configure / qc_engine_start / qc_engine_stop: a normal thread (they block).
//   qc_engine_read_input / qc_engine_write_output / qc_engine_zero_timestamp: real-time safe
//   (no locks, no allocation).
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QC_SAMPLE_RATE 44100.0
#define QC_IN_CHANNELS 4        // capture: INPUT 1, INPUT 2, DIGITAL IN L, DIGITAL IN R
#define QC_OUT_CHANNELS 4       // playback: OUTPUT 1L, OUTPUT 2R, DIGITAL OUT L, DIGITAL OUT R
#define QC_ZERO_PERIOD 16384    // frames between zero timestamps
#define QC_RING_FRAMES 65536    // ring buffer size in frames (power of 2)
#define QC_MAX_REQUESTS 32
#define QC_MAX_MICROFRAMES 128

// Lag histogram buckets (ms): <0.5, <1, <2, <4, <8, <16, <32, >=32.
#define QC_LAG_BUCKETS 8

typedef struct {
    uint64_t inputFrames;        // capture frames written to the ring
    uint64_t inputMissing;       // frames that a client read before they were in the ring
    uint64_t outputLate;         // frames that a client wrote after the USB side read them
    uint64_t emptyPackets;       // empty capture packets after the stream became stable
    uint64_t inErrors, outErrors;
    uint64_t resyncs;            // requests moved to a later frame because they were too late
    uint64_t gapFrames;          // capture frames of silence put in for skipped microframes
    uint64_t zeroTimestamps;
    double measuredRate;         // device sample rate measured against the host clock
    double inLagMaxMs, outLagMaxMs;   // completion callback lag after the end of the request
    uint64_t inLagHist[QC_LAG_BUCKETS], outLagHist[QC_LAG_BUCKETS];
    uint64_t directFrames;       // output frames written directly into queued USB requests
    uint64_t ringFrames;         // output frames written to the ring (read when a request is queued)
    uint64_t races;              // direct writes into a request that changed during the write
    int callbackPriority, callbackPolicy;   // scheduling of the USB callback thread (sampled)
    int scannerPriority;                    // priority of the real-time capture scanner (97 = real time)
} QCEngineStats;

// Direct write (default on): qc_engine_write_output writes into the queued USB requests until
// 1 ms before the transfer. Off: playback data comes from the ring when a request is queued.
// Direct read (default on): a real-time thread reads the capture data from the queued requests
// 250 us after each microframe and publishes the clock. Off: the USB callbacks do it.
// With both on, the latency does not depend on the queue depth or on the time of the callbacks.
// Call before qc_engine_start.
#define QC_DIRECT_WRITE 1
#define QC_DIRECT_READ 2
void qc_engine_set_direct(int mask);

// Queue size: requests in flight for each direction, and microframes (125 us) per request
// (a multiple of 8). The margins (frames) cover the callback lag. Call before qc_engine_start.
void qc_engine_configure(int requests, int microframes, uint32_t outputMarginFrames, uint32_t inputMarginFrames);

// A client must write the output this number of frames before the current sample time, and can
// read the input this number of frames after it. These values follow the configuration.
void qc_engine_get_config(int *requests, int *microframes, uint32_t *outputMarginFrames, uint32_t *inputMarginFrames,
                          int *direct);

uint32_t qc_engine_output_lead_frames(void);
uint32_t qc_engine_input_delay_frames(void);

// Device presence. The callback runs on a private queue when the QUAD-CAPTURE connects (true) or
// disconnects (false), and once at registration with the current state.
typedef void (*QCPresenceCallback)(bool present);
void qc_engine_watch_device(QCPresenceCallback callback);

// 0 on success, or a negative error code. The text of the error goes to the log.
// If the device disconnects while the engine runs, the engine stops its USB requests;
// qc_engine_zero_timestamp then returns false, and the client must call qc_engine_stop.
int qc_engine_start(void);
void qc_engine_stop(void);
bool qc_engine_is_running(void);
bool qc_engine_device_present(void);

// The most recent zero timestamp. Returns false if the engine does not run.
bool qc_engine_zero_timestamp(double *sampleTime, uint64_t *hostTime, uint64_t *seed);

// Interleaved float samples (QC_IN_CHANNELS / QC_OUT_CHANNELS per frame).
void qc_engine_read_input(int64_t sampleTime, uint32_t frames, float *dst);
void qc_engine_write_output(int64_t sampleTime, uint32_t frames, const float *src);

void qc_engine_get_stats(QCEngineStats *stats);

#ifdef __cplusplus
}
#endif
