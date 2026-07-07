import XCTest
@testable import CoreDSP

final class HellLoopbackTests: XCTestCase {

    /// Hellschreiber is a facsimile mode: the receiver reconstructs a scrolling
    /// pixel image, not decoded text, so this test doesn't assert on decoded
    /// characters (there are none -- drainReceivedText() is a documented
    /// no-op). Instead it verifies the loopback spirit of PSKLoopbackTests:
    /// TX -> RX with no audio hardware in between, and checks that real
    /// transmitted text produces a structured, non-trivial pixel image while
    /// silence produces a flat/near-constant one.
    func testFeldHellLoopbackProducesStructuredImage() {
        let tx = HellEngineCore()
        tx.setMode(.feldHell)
        tx.selectFrequency(1000)

        let rx = HellEngineCore()
        rx.setMode(.feldHell)
        rx.selectFrequency(1000)

        let message = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789"
        tx.queueTransmitText(message)

        var scratch = [Float](repeating: 0, count: 512)
        // Feld Hell runs at ~245 pixel-columns/sec baud tick, ~14 pixel-ticks
        // per column; give this message generous headroom -- 20 seconds of
        // audio comfortably covers it plus idle fill.
        for _ in 0..<(20 * 11025 / 512) {
            scratch.withUnsafeMutableBufferPointer { buf in
                tx.produceTransmitSamples(buf.baseAddress!, count: 512)
                rx.receiveSamples(buf.baseAddress!, count: 512)
            }
        }

        let signalColumns = rx.receivedImageRows
        XCTAssertGreaterThan(signalColumns.count, 20,
                              "expected a non-trivial number of demodulated columns, got \(signalColumns.count)")

        // Flatten and check for real variation (not all-zero / all-constant).
        let allPixels = signalColumns.flatMap { $0 }
        XCTAssertFalse(allPixels.isEmpty)
        let minV = allPixels.min() ?? 0
        let maxV = allPixels.max() ?? 0
        XCTAssertGreaterThan(maxV - minV, 0.1,
                              "expected meaningful brightness variation in the received image, got range \(minV)...\(maxV)")

        let mean = allPixels.reduce(0, +) / Float(allPixels.count)
        let variance = allPixels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(allPixels.count)
        XCTAssertGreaterThan(variance, 0.001,
                              "expected non-trivial pixel variance from real transmitted text, got \(variance)")

        // --- contrast: silence in should not produce comparable structure ---
        let silentRx = HellEngineCore()
        silentRx.setMode(.feldHell)
        silentRx.selectFrequency(1000)

        let silence = [Float](repeating: 0, count: 512)
        for _ in 0..<(20 * 11025 / 512) {
            silence.withUnsafeBufferPointer { buf in
                silentRx.receiveSamples(buf.baseAddress!, count: 512)
            }
        }
        let silentPixels = silentRx.receivedImageRows.flatMap { $0 }
        if !silentPixels.isEmpty {
            let silentMean = silentPixels.reduce(0, +) / Float(silentPixels.count)
            let silentVariance = silentPixels.reduce(0) { $0 + ($1 - silentMean) * ($1 - silentMean) } / Float(silentPixels.count)
            XCTAssertLessThan(silentVariance, variance,
                               "expected silence to produce far less pixel variance than real transmitted text")
        }
    }
}
