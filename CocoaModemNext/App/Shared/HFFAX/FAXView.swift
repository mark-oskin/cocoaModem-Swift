import SwiftUI
import ModemKit

/// HF-FAX (weather-fax / radiofax) receive view. Unlike PSKView there is no
/// transmit field: HF-FAX is a receive-only broadcast format (unattended
/// coastal weather-fax stations) with no transmit path anywhere in
/// FAXEngineCore/FAXEngine -- see their header comments -- so this view is
/// receive-only controls plus the scrolling grayscale image.
struct FAXView: View {
    @ObservedObject var engine: FAXEngine
    @ObservedObject var audio: AudioIOEngine

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Size", selection: $engine.halfSize) {
                    Text("Half").tag(true)
                    Text("Full").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Toggle("DWD (850 Hz)", isOn: $engine.deviation850)

                Spacer()

                Button("New Image") { engine.startNewImage() }
                Button("Clear") { engine.clearReceivedImage() }

                Button(audio.isRunning ? "Stop" : "Start") {
                    if audio.isRunning {
                        audio.stop()
                    } else {
                        audio.activeEngine = engine
                        audio.start()
                    }
                }
            }
            .padding(.horizontal)

            FAXImageView(rows: engine.receivedImageRows)
                .frame(minHeight: 300)
                .background(Color.black)

            if let error = audio.lastErrorDescription {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("HF-FAX")
    }
}

/// Renders a scrolling grayscale image from rows of brightness values (0...1),
/// newest row at the bottom -- same Canvas-row-rendering approach as
/// WaterfallView, but a plain grayscale fill instead of a heat-color ramp.
private struct FAXImageView: View {
    let rows: [[Float]]

    /// Cap how many of the most recent rows are drawn, so a very long-running
    /// receive session doesn't force Canvas to redraw thousands of rows every frame.
    private let maxVisibleRows = 1200

    var body: some View {
        Canvas { context, size in
            guard !rows.isEmpty else { return }
            let visible = rows.suffix(maxVisibleRows)
            let rowHeight = size.height / CGFloat(maxVisibleRows)
            let columns = visible.map(\.count).max() ?? 0
            guard columns > 0 else { return }
            let colWidth = size.width / CGFloat(columns)

            for (r, row) in visible.enumerated() {
                for c in 0..<row.count {
                    let level = Double(row[c])
                    let rect = CGRect(x: CGFloat(c) * colWidth, y: CGFloat(r) * rowHeight,
                                      width: colWidth + 1, height: rowHeight + 1)
                    context.fill(Path(rect), with: .color(Color(white: level)))
                }
            }
        }
    }
}
