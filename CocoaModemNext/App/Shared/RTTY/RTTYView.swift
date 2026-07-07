import SwiftUI
import ModemKit

struct RTTYView: View {
    @ObservedObject var engine: RTTYEngine
    @ObservedObject var audio: AudioIOEngine
    @State private var txText: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Mark")
                Slider(value: $engine.markFrequency, in: 300...2700)
                    .frame(maxWidth: 160)
                Text("\(Int(engine.markFrequency)) Hz")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)

                Text("Shift")
                Picker("Shift", selection: $engine.shift) {
                    Text("170 Hz").tag(Float(170))
                    Text("425 Hz").tag(Float(425))
                    Text("850 Hz").tag(Float(850))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Text("Baud")
                Picker("Baud", selection: $engine.baudRate) {
                    Text("45.45").tag(Float(45.45))
                    Text("50").tag(Float(50))
                    Text("75").tag(Float(75))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Spacer()

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
                    // frequency marker at the mark tone
                    GeometryReader { geo in
                        let x = geo.size.width * CGFloat((engine.markFrequency - 300) / (2700 - 300))
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
        .navigationTitle("RTTY")
    }

    private func sendText() {
        guard !txText.isEmpty else { return }
        engine.queueTransmitText(txText + " ")
        txText = ""
    }
}
