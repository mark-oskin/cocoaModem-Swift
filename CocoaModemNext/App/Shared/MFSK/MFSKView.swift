import SwiftUI
import ModemKit

struct MFSKView: View {
    @ObservedObject var engine: MFSKEngine
    @ObservedObject var audio: AudioIOEngine
    @State private var txText: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("MFSK16")
                    .font(.headline)

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

            WaterfallView(spectrum: engine.spectrum)
                .frame(height: 160)
                .overlay(alignment: .top) {
                    // frequency marker at the tuned tone
                    GeometryReader { geo in
                        let x = geo.size.width * CGFloat((engine.centerFrequency - 300) / (2700 - 300))
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 2)
                            .position(x: x, y: geo.size.height / 2)
                    }
                }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(engine.receivedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("rxEnd")
                }
                .background(Color.black.opacity(0.05))
                .onChange(of: engine.receivedText) { _, _ in
                    proxy.scrollTo("rxEnd", anchor: .bottom)
                }
            }
            .frame(minHeight: 120)

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
        .navigationTitle("MFSK")
    }

    private func sendText() {
        guard !txText.isEmpty else { return }
        engine.queueTransmitText(txText + " ")
        txText = ""
    }
}
