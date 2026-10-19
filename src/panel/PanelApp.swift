// QuadCapture Panel: a control panel for the Roland QUAD-CAPTURE (UA-55). It replaces the Roland
// control panel, which does not operate on Apple Silicon Macs.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel()
    let audio = AudioDevice()
    lazy var web = WebPanel(model: model, audio: audio)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        _ = web
        // The device meter operates only while the window is visible.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.model.setWindowVisible(NSApp.occlusionState.contains(.visible))
        }
    }

    // Close interface 2, so the audio plug-in reads it again.
    func applicationWillTerminate(_ notification: Notification) {
        web.stop()
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct QuadCapturePanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("QuadCapture Panel") {
            PanelView(model: delegate.model, audio: delegate.audio, web: delegate.web)
        }
    }
}

// MARK: - Main view

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var audio: AudioDevice
    @ObservedObject var web: WebPanel
    @State private var showLog = false
    @State private var showWeb = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBar(model: model, audio: audio)
            HStack(alignment: .top, spacing: 12) {
                PreampSection(model: model, audio: audio)
                CompressorSection(model: model, ch: 0)
                CompressorSection(model: model, ch: 1)
                MixerSection(model: model, audio: audio)
            }
            .disabled(!model.canEdit)
            DisclosureGroup("Web panel (phone or other computer)", isExpanded: $showWeb) {
                WebPanelView(web: web)
            }
            DisclosureGroup("Messages", isExpanded: $showLog) {
                ScrollView {
                    Text(model.log.suffix(80).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 1000, alignment: .top)
    }
}

struct StatusBar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var audio: AudioDevice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail = detail {
                    Text(detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let e = model.lastError { Text(e).font(.callout).foregroundColor(.red) }
                if let e = audio.rateError { Text(e).font(.callout).foregroundColor(.orange) }
            }
            Spacer()
            if !audio.availableRates.isEmpty {
                Picker("Sample rate", selection: Binding(get: { audio.sampleRate }, set: { audio.setSampleRate($0) })) {
                    ForEach(audio.availableRates, id: \.self) { r in
                        Text(r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000)) kHz" : String(format: "%.1f kHz", r / 1000)).tag(r)
                    }
                }
                .frame(width: 210)
                .help("The sample rate of the QUAD-CAPTURE, as in Audio MIDI Setup. At 192 kHz the device has 2 inputs and 2 outputs.")
            }
            if model.link == .open {
                Button("Read again") { model.reload() }
            } else if model.link != .opening {
                Button("Retry") { model.retry() }
            }
        }
    }

    private var color: Color {
        switch model.link {
        case .open: return model.loaded ? .green : .yellow
        case .opening: return .yellow
        case .busy, .released, .noReply: return .orange
        case .noDevice: return .gray
        }
    }

    private var title: String {
        switch model.link {
        case .open:
            if !model.loaded { return "Connected. Reading the settings..." }
            return model.autoSens == 2 ? "Connected. AUTO-SENS measures: play at your loudest level." : "Connected to the QUAD-CAPTURE"
        case .opening: return "Connecting..."
        case .busy: return "Another process uses the control channel"
        case .released: return "Another process asked for the control channel"
        case .noReply: return "The QUAD-CAPTURE does not answer"
        case .noDevice: return "QUAD-CAPTURE not connected"
        }
    }

    private var detail: String? {
        switch model.link {
        case .open:
            return "Changes go to the device at once. The device keeps them after a power cycle."
        case .busy:
            return "USB interface 2 of the QUAD-CAPTURE is in use. Usually the QuadCapture MIDI driver holds it, "
                + "because a MIDI app (for example a music app) is open. Quit the MIDI apps. The panel tries again automatically."
        case .released:
            return "A MIDI app or qc_sysex asked for USB interface 2, and the panel released it. "
                + "When that process stops, the panel connects again automatically."
        case .noReply:
            return "Disconnect the USB cable of the QUAD-CAPTURE for 5 seconds, then connect it again."
        case .noDevice:
            return "Connect the QUAD-CAPTURE with its USB cable."
        case .opening:
            return nil
        }
    }
}

// MARK: - Sections

// A toggle that looks like a lit button of the front panel.
struct PanelButton: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.bold()).frame(minWidth: 58)
        }
        .buttonStyle(.bordered)
        .tint(on ? .accentColor : nil)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.25) : Color.clear))
        .accessibilityValue(on ? "on" : "off")
    }
}

struct PreampSection: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var audio: AudioDevice

    var body: some View {
        GroupBox(label: Text("PREAMP").font(.headline)) {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<2, id: \.self) { ch in
                        VStack(spacing: 6) {
                            Text(ch == 0 ? "IN 1" : "IN 2").font(.subheadline.bold())
                            ParameterKnob(model: model, ch: ch, p: .sens, title: "SENS", size: 54)
                            PanelButton(title: "LO-CUT", on: model.inputs[ch][.loCut] != 0) {
                                model.set(ch, .loCut, model.inputs[ch][.loCut] != 0 ? 0 : 1)
                            }
                            PanelButton(title: "PHASE", on: model.inputs[ch][.phase] != 0) {
                                model.set(ch, .phase, model.inputs[ch][.phase] != 0 ? 0 : 1)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        MeterBar(meters: model.meters, channel: 0, label: "1", height: 150)
                        MeterScale(height: 150)
                        MeterBar(meters: model.meters, channel: 1, label: "2", height: 150)
                    }
                }
                HStack {
                    PanelButton(title: "AUTO-SENS", on: model.autoSens == 2) { model.pressAutoSens() }
                        .help("Starts the AUTO-SENS measurement (as the button on the device). Play at your loudest level; the device then sets SENS.")
                    PanelButton(title: "LINK", on: model.stereoLink) { model.setStereoLink(!model.stereoLink) }
                        .help("Stereo link of IN 1 and IN 2. When it comes on, the device copies the compressor of IN 1 to IN 2.")
                }
                MeterStateText(model: model)
            }
            .padding(4)
        }
    }
}

struct MeterStateText: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Toggle("Meters", isOn: $model.metersWanted)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("The QUAD-CAPTURE sends its own level data on the control channel while the window is visible. No audio stream, no microphone permission.")
    }
}

struct CompressorSection: View {
    @ObservedObject var model: PanelModel
    let ch: Int

    var body: some View {
        let on = model.inputs[ch][.comp] != 0
        GroupBox(label: HStack {
            Text("COMP \(ch + 1)").font(.headline)
            Spacer()
            PanelButton(title: on ? "ON" : "BYPASS", on: on) { model.set(ch, .comp, on ? 0 : 1) }
                .help("Compressor of IN \(ch + 1): ON, or BYPASS (off).")
        }) {
            VStack(spacing: 8) {
                CompressorGraph(settings: model.inputs[ch]).frame(width: 150, height: 150)
                HStack(spacing: 2) {
                    ParameterKnob(model: model, ch: ch, p: .threshold, title: "THRESHOLD", size: 38)
                    ParameterKnob(model: model, ch: ch, p: .ratio, title: "RATIO", size: 38)
                    ParameterKnob(model: model, ch: ch, p: .gain, title: "GAIN", size: 38)
                }
                HStack(spacing: 2) {
                    ParameterKnob(model: model, ch: ch, p: .attack, title: "ATTACK", size: 38)
                    ParameterKnob(model: model, ch: ch, p: .release, title: "RELEASE", size: 38)
                    ParameterKnob(model: model, ch: ch, p: .gate, title: "GATE", size: 38)
                }
            }
            .padding(4)
        }
    }
}

struct MixerSection: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var audio: AudioDevice

    var body: some View {
        GroupBox(label: Text("MIXER").font(.headline)) {
            VStack(spacing: 8) {
                Text("Direct monitor in OUTPUT 1-2").font(.caption).foregroundColor(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 6) {
                        MixerKnob(model: model, index: 0, title: "INPUT 1")
                        MixerKnob(model: model, index: 1, title: "INPUT 2")
                        MixerKnob(model: model, index: 2, title: "COAX")
                    }
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            MeterBar(meters: model.meters, channel: 2, label: "L", height: 150)
                            MeterBar(meters: model.meters, channel: 3, label: "R", height: 150)
                        }
                        Text("COAX IN").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            MeterBar(meters: model.meters, channel: 4, label: "L", height: 150)
                            MeterBar(meters: model.meters, channel: 5, label: "R", height: 150)
                        }
                        Text("OUTPUT").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                Button("All 0 dB") { for i in 0..<3 { model.setMixer(i, MixerLevel.unity) } }
                    .controlSize(.small)
            }
            .padding(4)
        }
    }
}

struct WebPanelView: View {
    @ObservedObject var web: WebPanel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow the panel from a web browser on the local network", isOn: $web.enabled)
                Text("Open the address on a phone or another computer on the same network. "
                     + "The address contains a key: give it only to people who can change the settings of the device. "
                     + "The connection is not encrypted (HTTP): use the web panel only on a network that you trust, not on public Wi-Fi.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let url = web.url {
                    HStack {
                        Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        .controlSize(.small)
                        Button("New key") { web.newKey() }
                            .controlSize(.small)
                            .help("Make a new key. The old address stops to operate on all devices.")
                    }
                }
                if let e = web.error { Text(e).font(.caption).foregroundColor(.red) }
            }
            Spacer()
            if web.url != nil, let image = web.qrImage() {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 110, height: 110)
                    .accessibilityLabel("QR code of the web panel address")
            }
        }
        .padding(.top, 4)
    }
}
