// PanelModel: the settings of the QUAD-CAPTURE, the SysEx messages that read and change them, and
// the link to QCPanelUSB. See docs/PROTOCOL.md, "Control panel (SysEx)".
import Foundation
import SwiftUI

// MARK: - Roland SysEx

enum SysEx {
    static let header: [UInt8] = [0xF0, 0x41, 0x10, 0x00, 0x00, 0x56]   // Roland, device 0x10, model 00 00 56
    static let rq1: UInt8 = 0x11
    static let dt1: UInt8 = 0x12
    static let blockAddress: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    static let blockSize = 59

    // The sum of the address, the data and the checksum is a multiple of 128.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return UInt8((128 - (sum & 0x7F)) & 0x7F)
    }

    static func message(_ command: UInt8, _ body: [UInt8]) -> [UInt8] {
        header + [command] + body + [checksum(body[...]), 0xF7]
    }

    static func requestBlock() -> [UInt8] {
        message(rq1, blockAddress + [0x00, 0x00, 0x00, UInt8(blockSize)])
    }

    // A DT1 message: address (4 bytes) and data. Returns nil for an address that the panel does not
    // know (the panel never sends the "Initialize" address 00 00 00 02).
    static func dataSet(_ address: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        guard address.count == 4, data.allSatisfy({ $0 < 0x80 }), Parameter.isKnown(address, dataCount: data.count) else { return nil }
        return message(dt1, address + data)
    }

    // A DT1 message from the device: address and data, or nil.
    static func parseDataSet(_ m: [UInt8]) -> (address: [UInt8], data: [UInt8])? {
        guard m.count >= 13, Array(m[0..<6]) == header, m[6] == dt1, m.last == 0xF7 else { return nil }
        let body = m[7..<(m.count - 2)]
        guard checksum(body) == m[m.count - 2] else { return nil }
        return (Array(body.prefix(4)), Array(body.dropFirst(4)))
    }
}

// MARK: - Parameters

enum Parameter: UInt8, CaseIterable {
    case loCut = 0x01, phase = 0x02, sens = 0x04, comp = 0x06, gate = 0x07, attack = 0x08, release = 0x09
    case threshold = 0x0A, ratio = 0x0B, gain = 0x0C

    // Address of the parameter for input channel ch (0 = IN 1, 1 = IN 2).
    func address(_ ch: Int) -> [UInt8] { [0x00, 0x05, UInt8(ch), rawValue] }

    var maximum: Int {
        switch self {
        case .loCut, .phase, .comp: return 1
        case .sens: return 108
        case .gate, .threshold: return 50
        case .attack: return 25
        case .release: return 45
        case .ratio: return 8
        case .gain: return 74
        }
    }

    static let linkAddress: [UInt8] = [0x00, 0x05, 0x00, 0x05]
    // AUTO-SENS button: DT1 with the value 1. The device starts the measurement, or stops it if it
    // runs. It then sends 00 02 01 02 = 0 and changes byte 21 of the state block.
    static let autoSensAddress: [UInt8] = [0x00, 0x02, 0x01, 0x02]
    // Level meter: DT1 with 1 (on) or 0 (off). While it is on, the device sends the levels as DT1
    // messages to meterDataAddress (16 data bytes) several times per second. The meter needs no
    // audio stream.
    static let meterAddress: [UInt8] = [0x00, 0x0A, 0x00, 0x00]
    static let meterDataAddress: [UInt8] = [0x00, 0x0A, 0x00, 0x01]
    static func mixerAddress(_ index: Int) -> [UInt8] { [0x00, 0x06, UInt8(index), 0x08] }

    static func isKnown(_ a: [UInt8], dataCount: Int) -> Bool {
        if a == linkAddress { return dataCount == 1 }
        if a == autoSensAddress { return dataCount == 1 }
        if a == meterAddress { return dataCount == 1 }
        if a[0] == 0x00, a[1] == 0x05, a[2] <= 1, Parameter(rawValue: a[3]) != nil { return dataCount == 1 }
        if a[0] == 0x00, a[1] == 0x06, a[2] <= 2, a[3] == 0x08 { return dataCount == 6 }
        return false
    }

    static let ratios = ["1:1.0", "1:1.2", "1:1.5", "1:2.0", "1:2.8", "1:4.0", "1:8.0", "1:16", "1:INF"]
    static let attacks = ["0.2", "0.5", "1", "2", "4", "6", "8", "10"] + stride(from: 15, through: 100, by: 5).map { "\($0)" }
    static let releases = [10, 12, 15, 18] + Array(stride(from: 20, through: 100, by: 5)) + Array(stride(from: 110, through: 200, by: 10))
        + Array(stride(from: 220, through: 500, by: 20))

    func text(_ v: Int) -> String {
        switch self {
        case .loCut, .phase, .comp: return v != 0 ? "On" : "Off"
        case .sens: return String(format: "%.1f dB", Double(v) / 2)
        case .gate: return v == 0 ? "Off" : "\(v - 70) dB"
        case .attack: return v < Parameter.attacks.count ? "\(Parameter.attacks[v]) ms" : "?"
        case .release: return v < Parameter.releases.count ? "\(Parameter.releases[v]) ms" : "?"
        case .threshold: return "\(v - 50) dB"
        case .ratio: return v < Parameter.ratios.count ? Parameter.ratios[v] : "?"
        case .gain: return String(format: "%+d dB", v - 50)
        }
    }
}

struct InputSettings: Equatable {
    // Factory values (docs/PROTOCOL.md).
    var values: [Parameter: Int] = [.loCut: 0, .phase: 0, .sens: 0, .comp: 0, .gate: 0, .attack: 3, .release: 30,
                                    .threshold: 30, .ratio: 5, .gain: 50]
    subscript(p: Parameter) -> Int {
        get { values[p] ?? 0 }
        set { values[p] = newValue }
    }
}

// Mixer levels: 24-bit linear gain, 0x200000 = 0 dB, 0x7FFFFF = +12 dB, 0 = -INF.
enum MixerLevel {
    static let unity = 0x200000
    static let maximum = 0x7FFFFF
    static let minimumDB = -60.0   // the slider position below this value is -INF

    static func decibels(_ raw: Int) -> Double {
        raw <= 0 ? -.infinity : 20 * log10(Double(raw) / Double(unity))
    }
    static func raw(_ db: Double) -> Int {
        guard db.isFinite, db >= minimumDB else { return 0 }
        if db >= 12 { return maximum }
        return min(maximum, Int((Double(unity) * pow(10, db / 20)).rounded()))
    }
    static func text(_ raw: Int) -> String {
        raw <= 0 ? "-INF" : String(format: "%+.1f dB", decibels(raw))
    }
    static func nibbles(_ raw: Int) -> [UInt8] {
        (0..<6).map { UInt8((raw >> (20 - 4 * $0)) & 0x0F) }
    }
    static func value(_ n: ArraySlice<UInt8>) -> Int {
        n.reduce(0) { ($0 << 4) | Int($1 & 0x0F) }
    }
}

// MARK: - Meter data

enum MeterData {
    // The 16 data bytes are 8 pairs; the panel uses the first 6: IN 1, IN 2, COAX L, COAX R, OUT L,
    // OUT R. 7F 7F = no value. Probable scale: high x 128 + low = linear amplitude, 16383 = full
    // scale (docs/PROTOCOL.md, "Level meter"; a calibrated test is not done yet).
    static func decibels(_ d: [UInt8]) -> [Float?] {
        guard d.count == 16 else { return [] }
        return (0..<6).map { i in
            let hi = d[2 * i], lo = d[2 * i + 1]
            if hi == 0x7F && lo == 0x7F { return nil }
            let v = Int(hi) << 7 | Int(lo)
            return v == 0 ? -.infinity : Float(20 * log10(Double(v) / 16383))
        }
    }
}

// MARK: - Model

final class PanelModel: ObservableObject {
    enum Link { case noDevice, opening, busy, released, open, noReply }

    @Published var link: Link = .noDevice
    @Published var loaded = false                     // true after the first state block
    @Published var inputs = [InputSettings(), InputSettings()]
    @Published var stereoLink = false
    @Published var mixer = [MixerLevel.unity, MixerLevel.unity, MixerLevel.unity]
    @Published var autoSens = 0                       // 0 off, 2 measurement, 1 complete
    @Published var lastError: String?
    @Published var log: [String] = []
    @Published var metersWanted = true { didSet { updateMeter() } }
    let meters = MeterModel()
    private var windowVisible = true
    private var meterOn = false            // the last value sent to the device
    private var meterDataSeen = false

    private let usb = QCPanelUSB()
    private var pendingWrites: [[UInt8]: [UInt8]] = [:]   // address -> data; the last value wins
    private var flushScheduled = false
    private var writeGeneration = 0                  // changes at each flush of writes
    private var requestGeneration = -1               // writeGeneration when the RQ1 went out (-1: none)
    private var requestTimer: Timer?
    private var requestFailures = 0
    private var verifyWork: DispatchWorkItem?
    private var inFlight: (address: [UInt8], data: [UInt8])?   // the DT1 that waits for its echo
    private var echoTimer: Timer?

    init() {
        usb.onState = { [weak self] state, detail in self?.usbState(state, detail) }
        usb.onSysEx = { [weak self] data in self?.received([UInt8](data)) }
        // When the panel closes the interface by itself, the device meter goes off.
        usb.closeMessage = Data(SysEx.dataSet(Parameter.meterAddress, [0])!)
        usb.onError = { [weak self] text in
            self?.lastError = text
            self?.addLog("ERROR: \(text)")
        }
    }

    func start() { usb.start() }
    func retry() { usb.retryNow() }
    func stop() { usb.stop() }
    func reload() { requestBlock() }

    var canEdit: Bool { link == .open && loaded }

    // MARK: Changes from the user

    func set(_ ch: Int, _ p: Parameter, _ v: Int) {
        let v = max(0, min(p.maximum, v))
        guard inputs[ch][p] != v else { return }
        inputs[ch][p] = v
        queueWrite(p.address(ch), [UInt8(v)])
    }

    func setStereoLink(_ on: Bool) {
        guard stereoLink != on else { return }
        stereoLink = on
        queueWrite(Parameter.linkAddress, [on ? 1 : 0])
    }

    // The AUTO-SENS button of the front panel.
    func pressAutoSens() {
        guard canEdit else { return }
        // Always send it: the same value again is the next press.
        pendingWrites[Parameter.autoSensAddress] = [1]
        verifyWork?.cancel()
        if flushScheduled || inFlight != nil { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.flushWrites() }
    }

    // The window is visible or not: the meter operates only while it is visible.
    func setWindowVisible(_ v: Bool) {
        windowVisible = v
        updateMeter()
    }

    private func updateMeter() {
        let want = metersWanted && windowVisible && canEdit
        guard want != meterOn else { return }
        meterOn = want
        meterDataSeen = false
        pendingWrites[Parameter.meterAddress] = [want ? 1 : 0]
        if !want { meters.reset() }
        if flushScheduled || inFlight != nil { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.flushWrites() }
    }

    func setMixer(_ index: Int, _ raw: Int) {
        let raw = max(0, min(MixerLevel.maximum, raw))
        guard mixer[index] != raw else { return }
        mixer[index] = raw
        queueWrite(Parameter.mixerAddress(index), MixerLevel.nibbles(raw))
    }

    // Slider moves make many changes, and the firmware is fragile. Thus the panel sends one DT1 at a
    // time: the device sends each DT1 back after it applied it (about 20 to 140 ms), and the panel
    // sends the next one only after that echo (or after 300 ms). For each address, only the last value
    // goes out. When all writes are done, the panel reads the state block again to show what the
    // device has.
    private func queueWrite(_ address: [UInt8], _ data: [UInt8]) {
        guard canEdit else { return }
        pendingWrites[address] = data
        verifyWork?.cancel()
        if flushScheduled || inFlight != nil { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.flushWrites() }
    }

    private func flushWrites() {
        flushScheduled = false
        guard link == .open else { pendingWrites.removeAll(); return }
        guard inFlight == nil else { return }
        guard let address = pendingWrites.keys.min(by: { $0.lexicographicallyPrecedes($1) }),
              let data = pendingWrites.removeValue(forKey: address) else {
            // All writes are done.
            let work = DispatchWorkItem { [weak self] in self?.requestBlock() }
            verifyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        guard let m = SysEx.dataSet(address, data) else {
            addLog("ERROR: address \(hex(address)) is not known; not sent")
            flushWrites()
            return
        }
        addLog("Sent DT1 \(hex(address)) = \(hex(data))")
        usb.sendSysEx(Data(m))
        writeGeneration += 1
        inFlight = (address, data)
        echoTimer?.invalidate()
        echoTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.addLog("No echo of the DT1 in 300 ms")
            self?.writeDone()
        }
    }

    private func writeDone() {
        echoTimer?.invalidate()
        inFlight = nil
        flushWrites()
    }

    // MARK: Requests and replies

    private func requestBlock() {
        guard link == .open else { return }
        requestGeneration = writeGeneration
        usb.sendSysEx(Data(SysEx.requestBlock()))
        requestTimer?.invalidate()
        requestTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in self?.requestTimedOut() }
    }

    private func requestTimedOut() {
        requestFailures += 1
        addLog("No reply to the RQ1 in 2 s (\(requestFailures))")
        if requestFailures >= 2 {
            requestGeneration = -1
            link = .noReply
        } else {
            requestBlock()
        }
    }

    private func received(_ m: [UInt8]) {
        guard let (address, data) = SysEx.parseDataSet(m) else {
            addLog("Received (not decoded): \(hex(m))")
            return
        }
        if address == Parameter.meterDataAddress {   // several times per second: not in the log
            if meterOn {
                if !meterDataSeen {
                    meterDataSeen = true
                    addLog("Received meter data \(hex(data)) (this line only once after each \"meter on\")")
                }
                meters.note(MeterData.decibels(data))
            }
            return
        }
        if address == SysEx.blockAddress, data.count == SysEx.blockSize {
            requestTimer?.invalidate()
            requestFailures = 0
            if link == .noReply { link = .open }
            // A write that went out after the request (or that waits) is not in this block yet: wait
            // for the next block.
            let current = requestGeneration == writeGeneration && pendingWrites.isEmpty && inFlight == nil
            requestGeneration = -1
            addLog(current ? "Received the state block" : "Received an old state block (ignored)")
            if current { apply(block: data) }
            return
        }
        addLog("Received DT1 \(hex(address)) = \(hex(data))")
        if let w = inFlight, w.address == address {
            // The echo of our write. The model already has this value or a newer one.
            if w.data != data {
                addLog("The device changed the value of \(hex(address))")
                applyDataSet(address, data)
            }
            writeDone()
            return
        }
        if pendingWrites[address] != nil { return }   // a newer value from the user goes out soon
        applyDataSet(address, data)
    }

    private func applyDataSet(_ address: [UInt8], _ data: [UInt8]) {
        if address == Parameter.linkAddress, data.count == 1 {
            stereoLink = data[0] & 1 != 0
        } else if address[0] == 0x00, address[1] == 0x05, address[2] <= 1, let p = Parameter(rawValue: address[3]), data.count == 1 {
            inputs[Int(address[2])][p] = Int(data[0])
        } else if address[0] == 0x00, address[1] == 0x06, address[2] <= 2, address[3] == 0x08, data.count == 6 {
            mixer[Int(address[2])] = MixerLevel.value(data[...])
        } else if address[0] == 0x00, address[1] == 0x02 {
            // AUTO-SENS starts or stops: read the state block to follow it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.requestBlock() }
        }
    }

    private func apply(block k: [UInt8]) {
        var new = [InputSettings(), InputSettings()]
        for ch in 0..<2 {
            new[ch][.loCut] = Int(k[23] >> ch) & 1
            new[ch][.phase] = Int(k[24] >> ch) & 1
            new[ch][.sens] = Int(k[25 + ch])
            new[ch][.comp] = Int(k[28] >> ch) & 1
            new[ch][.gate] = Int(k[29 + ch])
            new[ch][.attack] = Int(k[31 + ch])
            new[ch][.release] = Int(k[33 + ch])
            new[ch][.threshold] = Int(k[35 + ch])
            new[ch][.ratio] = Int(k[37 + ch])
            new[ch][.gain] = Int(k[39 + ch])
        }
        inputs = new
        stereoLink = k[27] & 1 != 0
        mixer = [MixerLevel.value(k[41..<47]), MixerLevel.value(k[47..<53]), MixerLevel.value(k[53..<59])]
        autoSens = Int(k[21])
        loaded = true
        updateMeter()
        // While AUTO-SENS measures, read the block each second until the result is there.
        if autoSens == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.requestBlock() }
        }
    }

    private func usbState(_ state: QCLinkState, _ detail: String) {
        addLog("USB: \(detail)")
        switch state {
        case .open:
            link = .open
            lastError = nil
            requestFailures = 0
            requestBlock()
        case .opening: link = .opening
        case .busy: link = .busy
        case .released: link = .released
        default: link = .noDevice
        }
        if state != .open {
            meterOn = false   // the interface is closed: the panel sends the meter state again later
            meters.reset()
            requestTimer?.invalidate()
            echoTimer?.invalidate()
            inFlight = nil
            pendingWrites.removeAll()
        }
    }

    private func addLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let entry = "\(f.string(from: Date()))  \(line)"
        log.append(entry)
        FileHandle.standardError.write((entry + "\n").data(using: .utf8)!)   // for tests from Terminal
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
