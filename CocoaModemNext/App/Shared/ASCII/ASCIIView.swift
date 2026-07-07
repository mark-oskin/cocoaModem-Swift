import SwiftUI
import ModemKit

struct ASCIIView: View {
    @ObservedObject var engine: ASCIIEngine
    @ObservedObject var audio: AudioIOEngine
    @State private var txText: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Baud", selection: $engine.baudRate) {
                    Text("45.45").tag(45.45)
                    Text("50").tag(50.0)
                    Text("75").tag(75.0)
                    Text("110").tag(110.0)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Picker("Bits", selection: $engine.bitsPerCharacter) {
                    Text("7").tag(7)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 100)

                Spacer()

                Text("Mark")
                Slider(value: $engine.markFrequency, in: 300...2700)
                    .frame(maxWidth: 140)
                Text("\(Int(engine.markFrequency)) Hz")
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
                    // frequency markers at the tuned mark/space tones
                    GeometryReader { geo in
                        ForEach([engine.markFrequency, engine.spaceFrequency], id: \.self) { freq in
                            let x = geo.size.width * CGFloat((freq - 300) / (2700 - 300))
                            Rectangle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 2)
                                .position(x: x, y: geo.size.height / 2)
                        }
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
        .navigationTitle("ASCII")
    }

    private func sendText() {
        guard !txText.isEmpty else { return }
        engine.queueTransmitText(txText + " ")
        txText = ""
    }
}
