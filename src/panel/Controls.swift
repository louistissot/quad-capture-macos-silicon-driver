// Controls: the knob, the level meter and the compressor curve of the panel.
import SwiftUI

// MARK: - Knob

// A rotary knob. Drag up or right to turn it clockwise. Double-click sets the default value.
// The arrow keys of VoiceOver (accessibility actions) change it one step.
struct Knob: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double                 // the value changes in these steps
    let defaultValue: Double
    let text: String
    let set: (Double) -> Void
    var size: CGFloat = 44

    @State private var dragStart: Double?
    @Environment(\.isEnabled) private var isEnabled

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1)
            ZStack {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                Circle()   // the arc of the value
                    .trim(from: 0, to: 0.75 * max(0, min(1, fraction)))
                    .stroke(isEnabled ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(3)
                Rectangle()   // the pointer
                    .fill(Color.primary)
                    .frame(width: 2, height: size * 0.3)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(-135 + 270 * max(0, min(1, fraction))))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        // 200 points of movement = the full range.
                        let delta = (Double(g.translation.width) - Double(g.translation.height)) / 200
                        apply(dragStart! + delta * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { apply(defaultValue) }
            Text(text).font(.system(.caption, design: .monospaced)).lineLimit(1).fixedSize()
        }
        .frame(minWidth: size + 16)
        .help("\(title): drag up or down to change. Double-click for the default value.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: apply(value + step)
            case .decrement: apply(value - step)
            @unknown default: break
            }
        }
    }

    private func apply(_ v: Double) {
        let stepped = (v / step).rounded() * step
        set(min(range.upperBound, max(range.lowerBound, stepped)))
    }
}

// A knob for an integer parameter of an input channel.
struct ParameterKnob: View {
    @ObservedObject var model: PanelModel
    let ch: Int
    let p: Parameter
    let title: String
    var size: CGFloat = 44

    var body: some View {
        Knob(title: title, value: Double(model.inputs[ch][p]), range: 0...Double(p.maximum), step: 1,
             defaultValue: Double(InputSettings()[p]), text: p.text(model.inputs[ch][p]),
             set: { model.set(ch, p, Int($0)) }, size: size)
    }
}

// A knob for a mixer level, in dB. The position below MixerLevel.minimumDB is -INF.
struct MixerKnob: View {
    @ObservedObject var model: PanelModel
    let index: Int
    let title: String

    var body: some View {
        let raw = model.mixer[index]
        let position = raw <= 0 ? MixerLevel.minimumDB - 1 : max(MixerLevel.minimumDB, MixerLevel.decibels(raw))
        Knob(title: title, value: position, range: (MixerLevel.minimumDB - 1)...12, step: 0.5, defaultValue: 0,
             text: MixerLevel.text(raw), set: { model.setMixer(index, MixerLevel.raw($0)) }, size: 48)
    }
}

// MARK: - Level meter

// A vertical peak meter from -60 to 0 dBFS, with peak hold and a clip light (click it to reset).
struct MeterBar: View {
    @ObservedObject var meters: MeterModel
    let channel: Int
    var label: String
    var height: CGFloat = 120

    var body: some View {
        let active = meters.active[channel]
        VStack(spacing: 3) {
            Circle()
                .fill(meters.clip[channel] ? Color.red : Color.secondary.opacity(0.25))
                .frame(width: 7, height: 7)
                .onTapGesture { meters.clip[channel] = false }
                .help("Clip: a sample reached 0 dBFS. Click to reset.")
            GeometryReader { g in
                let h = g.size.height
                let fill = CGFloat(position(meters.level[channel])) * h
                let hold = CGFloat(position(meters.hold[channel])) * h
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                    LinearGradient(colors: [.green, .green, .yellow, .red],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: h)
                        .mask(alignment: .bottom) { Rectangle().frame(height: fill) }
                    if hold > 1 {
                        Rectangle().fill(Color.primary.opacity(0.8)).frame(height: 1.5).offset(y: -hold + 1)
                    }
                }
            }
            .frame(width: 9, height: height)
            .opacity(active ? 1 : 0.35)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(label)")
        .accessibilityValue(active ? String(format: "%.0f dB", meters.level[channel]) : "off")
    }

    private func position(_ db: Float) -> Double {
        Double((db - MeterModel.floor) / -MeterModel.floor)
    }
}

// The gain reduction of a compressor: a bar from the top down, 0 to 20 dB.
struct ReductionBar: View {
    @ObservedObject var meters: MeterModel
    let index: Int
    let on: Bool
    var height: CGFloat = 120

    var body: some View {
        let r = meters.reduction[index]
        VStack(spacing: 3) {
            Spacer().frame(height: 7)
            GeometryReader { g in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                    Rectangle().fill(Color.orange).frame(height: g.size.height * CGFloat(min(20, max(0, r)) / 20))
                }
            }
            .frame(width: 9, height: height)
            .opacity(on ? 1 : 0.35)
            Text("GR").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).fixedSize()
        }
        .help("Gain reduction of the compressor (0 to 20 dB, from the top)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(String(format: "%.1f dB", r))
    }
}

// A scale for the meters: 0, -6, -12, -24, -40, -60 dB.
struct MeterScale: View {
    var height: CGFloat = 120

    var body: some View {
        VStack(spacing: 3) {
            Spacer().frame(height: 7)
            GeometryReader { g in
                ForEach([0, -6, -12, -24, -40, -60], id: \.self) { db in
                    Text("\(db)")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .position(x: g.size.width / 2, y: g.size.height * CGFloat(Double(-db) / 60))
                }
            }
            .frame(width: 18, height: height)
            Text(" ").font(.system(size: 9))
        }
    }
}

// MARK: - Compressor curve

// The transfer curve of the compressor of one channel: input level (horizontal) against output
// level (vertical), from -60 to 0 dB. The gate cuts the signal below its level. Grey when the
// compressor is off.
struct CompressorGraph: View {
    let settings: InputSettings

    static let ratios: [Double] = [1, 1.2, 1.5, 2, 2.8, 4, 8, 16, .infinity]

    var body: some View {
        let on = settings[.comp] != 0
        Canvas { context, size in
            let w = size.width, h = size.height
            func point(_ inDB: Double, _ outDB: Double) -> CGPoint {
                CGPoint(x: w * CGFloat((inDB + 60) / 60), y: h * CGFloat(-outDB / 60))
            }
            // Grid at -12, -24, -36, -48 dB.
            var grid = Path()
            for db in stride(from: -48.0, through: -12.0, by: 12) {
                grid.move(to: point(db, 0)); grid.addLine(to: point(db, -60))
                grid.move(to: point(-60, db)); grid.addLine(to: point(0, db))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            var unity = Path()
            unity.move(to: point(-60, -60)); unity.addLine(to: point(0, 0))
            context.stroke(unity, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            let threshold = Double(settings[.threshold] - 50)
            let ratioIndex = settings[.ratio]
            let ratio = ratioIndex < CompressorGraph.ratios.count ? CompressorGraph.ratios[ratioIndex] : 1
            let gain = Double(settings[.gain] - 50)
            let gate = settings[.gate] == 0 ? -Double.infinity : Double(settings[.gate] - 70)
            func output(_ x: Double) -> Double {
                let y = x <= threshold ? x : threshold + (x - threshold) / ratio
                return y + gain
            }
            var curve = Path()
            var started = false
            for i in 0...240 {
                let x = -60 + Double(i) * 0.25
                if x < gate { continue }
                let p = point(x, min(0, max(-60, output(x))))
                if !started {
                    // The gate: no output below its level.
                    if gate > -60 { curve.move(to: point(x, -60)); curve.addLine(to: p) } else { curve.move(to: p) }
                    started = true
                } else {
                    curve.addLine(to: p)
                }
            }
            context.stroke(curve, with: .color(on ? .accentColor : .secondary), lineWidth: 2)
            if threshold > -60 {
                var t = Path()
                t.move(to: point(threshold, -60)); t.addLine(to: point(threshold, 0))
                context.stroke(t, with: .color((on ? Color.orange : Color.secondary).opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        .aspectRatio(1, contentMode: .fit)
        .opacity(on ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compressor curve")
    }
}
