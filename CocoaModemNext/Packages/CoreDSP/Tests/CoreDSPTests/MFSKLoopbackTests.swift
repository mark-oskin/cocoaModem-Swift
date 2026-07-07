import XCTest
@testable import CoreDSP

final class MFSKLoopbackTests: XCTestCase {

    func testMFSK16Loopback() {
        let tx = MFSKEngineCore()
        tx.selectFrequency(1000, fromWaterfall: false)

        let rx = MFSKEngineCore()
        rx.selectFrequency(1000, fromWaterfall: false)

        let message = "CQ CQ DE W7AY K"
        tx.queueTransmitText(message)
        tx.queueTransmitText(" ") // trailing idle so the last character flushes through

        var decoded = ""
        var scratch = [Float](repeating: 0, count: 512)
        //  MFSK16 runs at 15.625 baud (~2 chars/sec incl. FEC + varicode + interleaver
        //  overhead, plus the demodulator's own AFC/sync acquisition time); give this
        //  short message generous headroom -- 40 seconds of audio.
        for _ in 0..<(40 * 11025 / 512) {
            scratch.withUnsafeMutableBufferPointer { buf in
                tx.produceTransmitSamples(buf.baseAddress!, count: 512)
                rx.receiveSamples(buf.baseAddress!, count: 512)
            }
            decoded += rx.drainReceivedText()
        }

        XCTAssertTrue(decoded.contains("W7AY"),
                       "expected the loopback-decoded text to contain the original message, got: \(decoded)")
    }
}
