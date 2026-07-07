import SwiftUI
import ModemKit

struct RootView: View {
    @StateObject private var audio = AudioIOEngine()

    @StateObject private var pskEngine = PSKEngine()
    @StateObject private var cwEngine = CWEngine()
    @StateObject private var rttyEngine = RTTYEngine()
    @StateObject private var asciiEngine = ASCIIEngine()
    @StateObject private var mfskEngine = MFSKEngine()
    @StateObject private var hellEngine = HellEngine()
    @StateObject private var faxEngine = FAXEngine()
    @StateObject private var sitorEngine = SITOREngine()

    var body: some View {
        TabView {
            PSKView(engine: pskEngine, audio: audio)
                .tabItem { Label("PSK", systemImage: "waveform") }
            RTTYView(engine: rttyEngine, audio: audio)
                .tabItem { Label("RTTY", systemImage: "waveform.path") }
            CWView(engine: cwEngine, audio: audio)
                .tabItem { Label("CW", systemImage: "dot.radiowaves.left.and.right") }
            ASCIIView(engine: asciiEngine, audio: audio)
                .tabItem { Label("ASCII", systemImage: "textformat") }
            MFSKView(engine: mfskEngine, audio: audio)
                .tabItem { Label("MFSK", systemImage: "waveform.path.ecg") }
            HellView(engine: hellEngine, audio: audio)
                .tabItem { Label("Hell", systemImage: "photo") }
            FAXView(engine: faxEngine, audio: audio)
                .tabItem { Label("HF-FAX", systemImage: "photo.stack") }
            SITORView(engine: sitorEngine, audio: audio)
                .tabItem { Label("SITOR-B", systemImage: "antenna.radiowaves.left.and.right") }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}
