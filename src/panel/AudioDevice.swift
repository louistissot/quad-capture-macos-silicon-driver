// AudioDevice: the QUAD-CAPTURE as a Core Audio device (the device that QuadCapture.driver
// publishes). The panel uses it only for the sample rate: it reads and sets
// kAudioDevicePropertyNominalSampleRate, as Audio MIDI Setup does. The audio driver then changes the
// clock of the QUAD-CAPTURE.
//
// The level meters do not use Core Audio: the device sends its own meter data on the control channel
// (see MeterModel and PanelModel). Thus the panel needs no microphone permission and starts no
// audio stream.
import CoreAudio
import Foundation

// The levels that the meters show, in dBFS, for the 6 meter channels of the device: IN 1, IN 2,
// COAX L, COAX R, OUT L, OUT R. A separate object, so that the meter updates redraw only the meters.
final class MeterModel: ObservableObject {
    static let channels = 6
    static let floor: Float = -60

    @Published var level = [Float](repeating: MeterModel.floor, count: MeterModel.channels)   // falls 20 dB/s
    @Published var hold = [Float](repeating: MeterModel.floor, count: MeterModel.channels)    // peak hold, 1.5 s
    @Published var clip = [Bool](repeating: false, count: MeterModel.channels)                 // click to reset
    @Published var active = [Bool](repeating: false, count: MeterModel.channels)
    private var pending = [Float](repeating: -.infinity, count: MeterModel.channels)
    private var holdTime = [Double](repeating: 0, count: MeterModel.channels)
    private var lastData = Date.distantPast
    private var lastTick = Date()
    private var timer: Timer?

    // A meter message from the device: one value in dBFS for each channel (nil: no value).
    func note(_ db: [Float?]) {
        lastData = Date()
        for i in 0..<min(db.count, MeterModel.channels) {
            guard let v = db[i] else { continue }
            pending[i] = max(pending[i], v)
            if v >= -0.1 && !clip[i] { clip[i] = true }
        }
        let a = (0..<MeterModel.channels).map { $0 < db.count && db[$0] != nil }
        if a != active { active = a }
        if timer == nil {
            lastTick = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now
        var level = self.level, hold = self.hold
        for i in 0..<MeterModel.channels {
            let db = max(MeterModel.floor, pending[i])
            pending[i] = -.infinity
            level[i] = max(db, level[i] - 20 * dt)
            if db >= hold[i] {
                hold[i] = db
                holdTime[i] = now.timeIntervalSinceReferenceDate
            } else if now.timeIntervalSinceReferenceDate - holdTime[i] > 1.5 {
                hold[i] = max(MeterModel.floor, hold[i] - 20 * dt)
            }
        }
        if level != self.level { self.level = level }
        if hold != self.hold { self.hold = hold }
        // No data for 1 s: the meter is off. Stop the timer when all meters are at the floor.
        if now.timeIntervalSince(lastData) > 1, level.allSatisfy({ $0 <= MeterModel.floor }) {
            reset()
        }
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        level = [Float](repeating: MeterModel.floor, count: MeterModel.channels)
        hold = level
        active = [Bool](repeating: false, count: MeterModel.channels)
        pending = [Float](repeating: -.infinity, count: MeterModel.channels)
    }
}

final class AudioDevice: ObservableObject {
    static let uid = "QuadCaptureMac:0582:012f"   // kDevice_UID in src/driver/qc_driver.c

    // Main thread.
    @Published private(set) var deviceID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var availableRates: [Double] = []
    @Published private(set) var rateError: String?

    // All Core Audio calls go to this queue. A call to coreaudiod can block for a long time (for
    // example while coreaudiod restarts); the window must not stop then.
    private let hal = DispatchQueue(label: "com.louistissot.quadcapture.panel.hal")
    private var halDevice: AudioObjectID = kAudioObjectUnknown   // hal queue
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.findDevice() }
    private lazy var rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readRates() }

    init() {
        hal.async {
            var address = self.address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, self.hal, self.devicesListener)
            self.findDevice()
        }
    }

    func setSampleRate(_ rate: Double) {
        hal.async {
            guard self.halDevice != kAudioObjectUnknown else { return }
            var address = self.address(kAudioDevicePropertyNominalSampleRate)
            var value = Float64(rate)
            let status = AudioObjectSetPropertyData(self.halDevice, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
            let text: String?
            switch status {
            case noErr: text = nil
            // The driver refuses other rates while the device runs on the clock of COAXIAL IN.
            case OSStatus(kAudioDeviceUnsupportedFormatError):
                text = "The QUAD-CAPTURE uses the clock of COAXIAL IN. The rate follows the digital input."
            default: text = "Cannot set the sample rate to \(Int(rate)) Hz (error \(status))."
            }
            DispatchQueue.main.async { self.rateError = text }
            self.readRates()   // the menu shows the real rate again
        }
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Device (hal queue)

    private func findDevice() {
        var id = kAudioObjectUnknown
        var uid = AudioDevice.uid as CFString
        var address = self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        if status != noErr { id = kAudioObjectUnknown }
        guard id != halDevice else { return }
        if halDevice != kAudioObjectUnknown {
            for sel in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates] {
                var a = self.address(sel)
                AudioObjectRemovePropertyListenerBlock(halDevice, &a, hal, rateListener)
            }
        }
        halDevice = id
        if id != kAudioObjectUnknown {
            for sel in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates] {
                var a = self.address(sel)
                AudioObjectAddPropertyListenerBlock(id, &a, hal, rateListener)
            }
        }
        DispatchQueue.main.async { self.deviceID = id }
        readRates()
    }

    private func readRates() {
        var rate: Float64 = 0
        var rates: [Double] = []
        if halDevice != kAudioObjectUnknown {
            var address = self.address(kAudioDevicePropertyNominalSampleRate)
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioObjectGetPropertyData(halDevice, &address, 0, nil, &size, &rate) != noErr { rate = 0 }
            address = self.address(kAudioDevicePropertyAvailableNominalSampleRates)
            size = 0
            if AudioObjectGetPropertyDataSize(halDevice, &address, 0, nil, &size) == noErr, size > 0 {
                var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
                if AudioObjectGetPropertyData(halDevice, &address, 0, nil, &size, &ranges) == noErr {
                    rates = ranges.map { $0.mMinimum }.sorted()
                }
            }
        }
        DispatchQueue.main.async {
            self.sampleRate = rate
            self.availableRates = rates
        }
    }
}
