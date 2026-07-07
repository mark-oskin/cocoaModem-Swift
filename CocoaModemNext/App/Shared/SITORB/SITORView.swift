import SwiftUI
import ModemKit

/// SITOR-B (maritime/NAVTEX teleprinter, CCIR-476 Moore code with FEC)
/// receive view. Like FAXView there is no transmit field: SITOR-B is
/// receive-only in this app -- see SITOREngineCore/SITOREngine's header
/// comments -- so this is receive-only controls (squelch, USOS, error-print)
/// plus the waterfall, a lock-state indicator lamp (mirrors the original
/// SITORRxControl status lamp), and the scrolling RX text.
struct SITORView: View {
    @ObservedObject var engine: SITOREngine
    @ObservedObject var audio: AudioIOEngine

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                indicatorLamp
                Text(indicatorLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Squelch")
                Slider(value: $engine.squelch, in: 0...1)
                    .frame(maxWidth: 140)

                Toggle("USOS", isOn: $engine.usos)
                Toggle("Show Errors", isOn: $engine.errorPrint)

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
            .frame(minHeight: 200)

            Text("SITOR-B is receive-only (maritime/NAVTEX broadcast) -- there is no transmit side to key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            if let error = audio.lastErrorDescription {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("SITOR-B")
    }

    private var indicatorLamp: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 14, height: 14)
    }

    private var indicatorColor: Color {
        switch engine.syncState {
        case .off: return .gray
        case .locked: return .green
        case .waitingForSync: return .yellow
        case .fecCorrected: return .orange
        case .error: return .red
        }
    }

    private var indicatorLabel: String {
        switch engine.syncState {
        case .off: return "Off"
        case .locked: return "Locked"
        case .waitingForSync: return "Waiting"
        case .fecCorrected: return "FEC"
        case .error: return "Error"
        }
    }
}
