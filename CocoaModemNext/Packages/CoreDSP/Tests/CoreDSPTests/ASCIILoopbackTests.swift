import XCTest
@testable import CoreDSP

final class ASCIILoopbackTests: XCTestCase {

    func testASCIILoopback() {
        let tx = ASCIIEngineCore()
        let rx = ASCIIEngineCore()

        let message = "CQ CQ DE W7AY K"
        tx.queueTransmitText(message)
        tx.queueTransmitText(" ")   // trailing idle so the last character flushes through

        var decoded = ""
        var scratch = [Float](repeating: 0, count: 512)
        // 110 baud (~11 chars/sec incl. start/stop framing) -- this message (15
        // chars) needs well under 2 seconds of audio; give it generous headroom.
        for _ in 0..<(12 * 11025 / 512) {
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
