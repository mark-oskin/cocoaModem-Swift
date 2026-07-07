import SwiftUI

/// A generic scrolling waterfall driven by a stream of linear-power spectrum
/// snapshots. Mode-agnostic -- any engine's spectrum output can drive this.
struct WaterfallView: View {
    let spectrum: [Float]
    let columns: Int
    let maxRows: Int

    @State private var history: [[Float]] = []

    init(spectrum: [Float], columns: Int = 128, maxRows: Int = 100) {
        self.spectrum = spectrum
        self.columns = columns
        self.maxRows = maxRows
    }

    var body: some View {
        Canvas { context, size in
            guard !history.isEmpty else { return }
            let rowHeight = size.height / CGFloat(maxRows)
            let colWidth = size.width / CGFloat(columns)
            for (r, row) in history.enumerated() {
                for c in 0..<min(columns, row.count) {
                    let level = magnitudeToUnit(row[c])
                    let rect = CGRect(x: CGFloat(c) * colWidth, y: CGFloat(r) * rowHeight,
                                      width: colWidth + 1, height: rowHeight + 1)
                    context.fill(Path(rect), with: .color(heatColor(level)))
                }
            }
        }
        .background(Color.black)
        .onChange(of: spectrum) { _, newValue in
            guard !newValue.isEmpty else { return }
            history.insert(downsample(newValue, to: columns), at: 0)
            if history.count > maxRows { history.removeLast(history.count - maxRows) }
        }
    }

    private func downsample(_ bins: [Float], to targetCount: Int) -> [Float] {
        guard bins.count > targetCount else { return bins }
        let bucket = bins.count / targetCount
        var out = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            var sum: Float = 0
            let start = i * bucket
            for j in start..<min(start + bucket, bins.count) { sum += bins[j] }
            out[i] = sum / Float(bucket)
        }
        return out
    }

    private func magnitudeToUnit(_ magnitude: Float) -> Double {
        // magnitude is linear power (re*re + im*im); compress with log for a usable dynamic range.
        let db = 10 * log10(Double(magnitude) + 1e-9)
        let normalized = (db + 60) / 60 // roughly -60dB..0dB -> 0..1
        return min(max(normalized, 0), 1)
    }

    private func heatColor(_ level: Double) -> Color {
        // black -> blue -> green -> yellow -> red, matching the classic waterfall palette.
        let stops: [(Double, Color)] = [
            (0.0, .black), (0.35, .blue), (0.6, .green), (0.8, .yellow), (1.0, .red)
        ]
        for i in 1..<stops.count {
            if level <= stops[i].0 {
                let (l0, c0) = stops[i - 1]
                let (l1, c1) = stops[i]
                let t = (l1 > l0) ? (level - l0) / (l1 - l0) : 0
                return lerp(c0, c1, t)
            }
        }
        return stops.last!.1
    }

    private func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        Color(
            red: lerpComponent(a, b, t, \.0),
            green: lerpComponent(a, b, t, \.1),
            blue: lerpComponent(a, b, t, \.2)
        )
    }

    private func lerpComponent(_ a: Color, _ b: Color, _ t: Double, _ keyPath: KeyPath<(Double, Double, Double), Double>) -> Double {
        let ac = a.components
        let bc = b.components
        let av = ac[keyPath: keyPath]
        let bv = bc[keyPath: keyPath]
        return av + (bv - av) * t
    }
}

private extension Color {
    /// Approximate RGB extraction that works the same on macOS/iOS for our fixed palette colors.
    var components: (Double, Double, Double) {
        switch self {
        case .black: return (0, 0, 0)
        case .blue: return (0, 0, 1)
        case .green: return (0, 1, 0)
        case .yellow: return (1, 1, 0)
        case .red: return (1, 0, 0)
        default: return (1, 1, 1)
        }
    }
}
