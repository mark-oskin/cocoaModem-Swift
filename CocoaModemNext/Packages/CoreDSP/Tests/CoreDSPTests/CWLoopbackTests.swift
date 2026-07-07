import XCTest
@testable import CoreDSP

final class CWLoopbackTests: XCTestCase {

    func testCWLoopback() {
        let tx = CWEngineCore()
        tx.setToneFrequency(700)
        tx.setWPM(20)

        let rx = CWEngineCore()
        rx.setToneFrequency(700)
        rx.setWPM(20)   //  pins the RX matched filter to 20 wpm, matching TX exactly

        let message = "CQ CQ DE W7AY K"
        tx.queueTransmitText(message)
        tx.queueTransmitText(" ")   // trailing idle so the last character flushes through

        var decoded = ""
        var scratch = [Float](repeating: 0, count: 512)
        //  20 wpm is roughly 100 characters/minute; give this 16-character
        //  message (plus inter-word gaps) generous headroom -- 20 seconds of audio.
        for _ in 0..<(20 * 11025 / 512) {
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
