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
    int callbackPriority, callbackPolicy;   // scheduling of the USB callback thread (sampled)
} QCEngineStats;

// Scheduling of the USB callbacks: 0 = serial queue (user-interactive QoS), 1 = workloop in an
// audio workgroup, 2 = mode 1 and a real-time (time-constraint) policy on the callback thread.
// Call before qc_engine_start.
void qc_engine_set_scheduling(int mode);

// Queue size: requests in flight for each direction, and microframes (125 us) per request
// (a multiple of 8). The margins (frames) cover the callback lag. Call before qc_engine_start.
void qc_engine_configure(int requests, int microframes, uint32_t outputMarginFrames, uint32_t inputMarginFrames);

// A client must write the output this number of frames before the current sample time, and can
// read the input this number of frames after it. These values follow the configuration.
void qc_engine_get_config(int *requests, int *microframes, uint32_t *outputMarginFrames, uint32_t *inputMarginFrames,
                          int *schedulingMode);

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
