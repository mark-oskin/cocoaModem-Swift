import XCTest
@testable import CoreDSP

final class RTTYLoopbackTests: XCTestCase {

    func testRTTYLoopback45Baud170Shift() {
        let tx = RTTYEngineCore()
        tx.setShift(mark: 2125, space: 2295)   // 170 Hz shift, standard RTTY
        tx.setBaudRate(45.45)

        let rx = RTTYEngineCore()
        rx.setShift(mark: 2125, space: 2295)
        rx.setBaudRate(45.45)

        let message = "CQ CQ DE W7AY K"
        //  Real RTTY operators lead every transmission with a sync preamble
        //  (traditionally "RYRYRYRY...") specifically because the receiving
        //  terminal's bit-sync/AGC needs to see a character's worth of mark/
        //  space transitions before it locks on -- a cold start with zero
        //  preamble reliably garbles the very first character. Mirror that
        //  standard practice here rather than asserting on an unrealistic
        //  zero-preamble cold start.
        tx.queueTransmitText("RYRYRYRYRY ")
        tx.queueTransmitText(message)
        tx.queueTransmitText(" ")   // trailing idle so the last character flushes through

        var decoded = ""
        var scratch = [Float](repeating: 0, count: 512)
        // 45.45 baud RTTY runs at ~6 chars/sec; give this short message generous
        // headroom -- 10 seconds of audio at CMFs (11025 Hz).
        for _ in 0..<(10 * 11025 / 512) {
            scratch.withUnsafeMutableBufferPointer { buf in
                tx.produceTransmitSamples(buf.baseAddress!, count: 512)
                rx.receiveSamples(buf.baseAddress!, count: 512)
            }
            decoded += rx.drainReceivedText()
        }

        XCTAssertTrue(decoded.contains("CQ CQ DE W7AY"),
                       "expected the loopback-decoded text to contain the original message, got: \(decoded)")
    }
}
