// QuadCapture Panel: a control panel for the Roland QUAD-CAPTURE (UA-55). It replaces the Roland
// control panel, which does not operate on Apple Silicon Macs.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) { model.start() }
    // Close interface 2, so the audio plug-in reads it again.
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct QuadCapturePanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("QuadCapture Panel") {
            PanelView(model: delegate.model)
        }
    }
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBar(model: model)
            HStack(alignment: .top, spacing: 12) {
                InputView(model: model, ch: 0)
                InputView(model: model, ch: 1)
            }
            HStack(alignment: .top, spacing: 12) {
                GroupBox(label: Text("Stereo link")) {
                    Toggle("Link IN 1 and IN 2", isOn: Binding(get: { model.stereoLink }, set: { model.setStereoLink($0) }))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 200)
                MixerView(model: model)
            }
            .disabled(!model.canEdit)
            DisclosureGroup("Messages", isExpanded: $showLog) {
                ScrollView {
                    Text(model.log.suffix(80).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
        }
        .padding(16)
        .frame(minWidth: 760)
    }
}

struct StatusBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail = detail {
                    Text(detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let e = model.lastError { Text(e).font(.callout).foregroundColor(.red) }
            }
            Spacer()
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
            switch model.autoSens {
            case 2: return "Connected. AUTO-SENS measures: play at your loudest level."
            default: return "Connected to the QUAD-CAPTURE"
            }
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

// A slider for an integer parameter, with the value as text.
struct StepSlider: View {
    let title: String
    let value: Int
    let maximum: Int
    let text: (Int) -> String
    let set: (Int) -> Void

    var body: some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: 0...Double(maximum))
            Text(text(value)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Stepper("", onIncrement: { set(min(maximum, value + 1)) }, onDecrement: { set(max(0, value - 1)) })
                .labelsHidden()
        }
    }
}

struct InputView: View {
    @ObservedObject var model: PanelModel
    let ch: Int

    private func slider(_ title: String, _ p: Parameter) -> some View {
        StepSlider(title: title, value: model.inputs[ch][p], maximum: p.maximum, text: p.text) { model.set(ch, p, $0) }
    }

    private func toggle(_ title: String, _ p: Parameter) -> some View {
        Toggle(title, isOn: Binding(get: { model.inputs[ch][p] != 0 }, set: { model.set(ch, p, $0 ? 1 : 0) }))
    }

    var body: some View {
        GroupBox(label: Text(ch == 0 ? "IN 1" : "IN 2").font(.headline)) {
            VStack(alignment: .leading, spacing: 6) {
                slider("SENS", .sens)
                HStack(spacing: 20) {
                    toggle("LO-CUT", .loCut)
                    toggle("PHASE (invert)", .phase)
                }
                Divider()
                toggle("Compressor", .comp)
                Group {
                    slider("Threshold", .threshold)
                    slider("Ratio", .ratio)
                    slider("Attack", .attack)
                    slider("Release", .release)
                    slider("Gate", .gate)
                    slider("Gain", .gain)
                }
                .opacity(model.inputs[ch][.comp] != 0 ? 1 : 0.6)
            }
            .padding(4)
        }
        .disabled(!model.canEdit)
    }
}

struct MixerView: View {
    @ObservedObject var model: PanelModel
    private let names = ["INPUT 1", "INPUT 2", "COAX"]

    var body: some View {
        GroupBox(label: Text("Monitor mixer (OUTPUT 1-2)")) {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    HStack {
                        Text(names[i]).frame(width: 78, alignment: .leading)
                        Slider(value: Binding(get: { position(model.mixer[i]) },
                                              set: { model.setMixer(i, MixerLevel.raw($0.rounded(toPlaces: 1))) }),
                               in: (MixerLevel.minimumDB - 1)...12)
                        Text(MixerLevel.text(model.mixer[i])).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Button("0 dB") { model.setMixer(i, MixerLevel.unity) }
                    }
                }
            }
            .padding(4)
        }
    }

    private func position(_ raw: Int) -> Double {
        raw <= 0 ? MixerLevel.minimumDB - 1 : max(MixerLevel.minimumDB, MixerLevel.decibels(raw))
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10, Double(n))
        return (self * f).rounded() / f
    }
}
