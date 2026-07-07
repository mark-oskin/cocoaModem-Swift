import SwiftUI
import ModemKit

/// Renders the scrolling Hellschreiber pixel-raster image: each element of
/// `columns` is one demodulated column (oldest first), 28 Floats in 0...1
/// brightness. Drawn left-to-right in array order (oldest at the left, newest
/// at the right) as a grid of grayscale rectangles -- the same "read the
/// picture" experience as the original app's scrolling Hell display, without
/// reproducing its diagonal-wrap scrolling geometry (that was UI/AppKit
/// presentation detail, not DSP).
///
/// Only the most recent `maxVisibleColumns` are drawn, purely to bound the
/// number of rectangles Canvas has to fill per frame; the full history still
/// accumulates in HellEngine.receivedImageColumns.
private struct HellPixelView: View {
    let columns: [[Float]]
    var maxVisibleColumns: Int = 300

    var body: some View {
        Canvas { context, size in
            let visible = columns.suffix(maxVisibleColumns)
            guard !visible.isEmpty else { return }
            let rowCount = visible.map(\.count).max() ?? 28
            guard rowCount > 0 else { return }

            let colWidth = size.width / CGFloat(visible.count)
            let rowHeight = size.height / CGFloat(rowCount)

            for (ci, column) in visible.enumerated() {
                let x = CGFloat(ci) * colWidth
                for (ri, brightness) in column.enumerated() {
                    let y = CGFloat(ri) * rowHeight
                    let b = Double(min(max(brightness, 0), 1))
                    let rect = CGRect(x: x, y: y, width: colWidth + 0.5, height: rowHeight + 0.5)
                    context.fill(Path(rect), with: .color(Color(white: b)))
                }
            }
        }
        .background(Color.black)
    }
}

struct HellView: View {
    @ObservedObject var engine: HellEngine
    @ObservedObject var audio: AudioIOEngine
    @State private var txText: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Mode", selection: $engine.mode) {
                    Text("Feld Hell").tag(HellMode.feldHell)
                    Text("FM Hell 245").tag(HellMode.fmHell245)
                    Text("FM Hell 105").tag(HellMode.fmHell105)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                Spacer()

                Text("Freq")
                Slider(value: $engine.centerFrequency, in: 300...2700)
                    .frame(maxWidth: 200)
                Text("\(Int(engine.centerFrequency)) Hz")
                    .monospacedDigit()
                    .frame(width: 70, alignment: .leading)

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

            // scrolling pixel-raster receive image -- Hellschreiber's RX output
            // is a picture, not text; see HellEngineCore's doc comment.
            HellPixelView(columns: engine.receivedImageColumns)
                .frame(minHeight: 160)
                .overlay(alignment: .topLeading) {
                    Text("Hellschreiber renders a scrolling picture, not decoded text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }

            HStack {
                TextField("Type to transmit…", text: $txText, onCommit: sendText)
                    .textFieldStyle(.roundedBorder)
                Button("Send", action: sendText)
                    .disabled(txText.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let error = audio.lastErrorDescription {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("Hellschreiber")
    }

    private func sendText() {
        guard !txText.isEmpty else { return }
        engine.queueTransmitText(txText + " ")
        txText = ""
    }
}
