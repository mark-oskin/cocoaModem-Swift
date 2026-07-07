import XCTest
@testable import CoreDSP

/// HF-FAX is a receive-only broadcast format (unattended coastal weather-fax
/// stations) -- there is no transmit path in this app to loop RX against (see
/// FAXEngineCore's header comment), so instead of a TX->RX loopback like
/// PSKLoopbackTests, this synthesizes the FM subcarrier a real IOC-576
/// radiofax station would send for a simple black/white striped test
/// pattern -- a steady 1500 Hz tone (black) alternated with a steady 2300 Hz
/// tone (white), the two extremes of the standard 1900 Hz +/-400 Hz
/// deviation -- and feeds it straight into FAXEngineCore.receiveSamples, then
/// asserts the reconstructed image rows corresponding to the white stripe are
/// substantially brighter than the ones corresponding to the black stripe.
/// This exercises the full pipeline: FAXReceiver's FM demodulator, the
/// FAXPhasingDetector row-completion bookkeeping, and FAXFrame's
/// backing-store resampling -- everything except the phasing/hsync
/// correlators actually locking onto a real 300/450 Hz start/stop tone
/// (which no test pattern here transmits, so the decoder simply free-runs in
/// its default "wait" state -- exactly what happens on a live signal before
/// the receiver has phased in on a picture).
final class FAXLoopbackTests: XCTestCase {

    func testStripedTestPatternDecodesToAlternatingBrightness() {
        let rx = FAXEngineCore()

        let sampleRate = 11025.0
        let blackHz = 1500.0
        let whiteHz = 2300.0

        //  One scanline is ~5512 samples (~0.5 s) at the fixed IOC 576 sampling
        //  parameters FAXFrame.setSamplingParameters() computes. Six scanlines per
        //  stripe gives the bandpass/AGC/differentiator chain time to settle well
        //  before the stripe's later rows are sampled.
        let samplesPerScanline = 5512
        let scanlinesPerStripe = 6
        let samplesPerStripe = samplesPerScanline * scanlinesPerStripe

        //  black, white, black -- three stripes, ~9 seconds of synthesized audio.
        let stripeFrequencies = [blackHz, whiteHz, blackHz]

        var phase = 0.0
        var scratch = [Float](repeating: 0, count: 512)

        for freq in stripeFrequencies {
            var samplesRemaining = samplesPerStripe
            while samplesRemaining > 0 {
                let take = min(512, samplesRemaining)
                for i in 0..<take {
                    scratch[i] = Float(sin(phase))
                    phase += 2.0 * .pi * freq / sampleRate
                    if phase > 2.0 * .pi * 1_000_000 { phase = phase.truncatingRemainder(dividingBy: 2.0 * .pi) }
                }
                scratch.withUnsafeBufferPointer { buf in
                    rx.receiveSamples(buf.baseAddress!, count: take)
                }
                samplesRemaining -= take
            }
        }

        let rows = rx.receivedImageRows
        XCTAssertGreaterThan(rows.count, 6, "expected several decoded scanlines, got \(rows.count)")

        //  Map an output row index back to which input scanline (and hence which
        //  stripe) it came from. In half-size mode (the default) only odd absolute
        //  scanlines produce an output row, each blending itself with the previous
        //  (even) scanline -- see FAXFrame.resampledRow(atRow:).
        let halfSize = rx.imageWidth == FAXFrame.halfWidth
        func stripe(forOutputRow rowIndex: Int) -> Int {
            let scanline = halfSize ? rowIndex * 2 + 1 : rowIndex
            return min((scanline / scanlinesPerStripe), stripeFrequencies.count - 1)
        }

        var stripeSum = [Float](repeating: 0, count: stripeFrequencies.count)
        var stripeCount = [Int](repeating: 0, count: stripeFrequencies.count)
        for (i, row) in rows.enumerated() {
            let s = stripe(forOutputRow: i)
            let avg = row.reduce(0, +) / Float(row.count)
            stripeSum[s] += avg
            stripeCount[s] += 1
        }

        XCTAssertGreaterThan(stripeCount[0], 0, "expected decoded rows from the first black stripe")
        XCTAssertGreaterThan(stripeCount[1], 0, "expected decoded rows from the white stripe")

        let blackAvg = stripeSum[0] / Float(max(stripeCount[0], 1))
        let whiteAvg = stripeSum[1] / Float(max(stripeCount[1], 1))

        XCTAssertGreaterThan(whiteAvg - blackAvg, 0.3,
                              "expected the white stripe's decoded rows (avg brightness \(whiteAvg)) to be substantially brighter than the black stripe's (avg brightness \(blackAvg)); got rows-per-stripe \(stripeCount)")

        //  Also check the second black stripe (index 2) to confirm the decoder
        //  correctly tracks the tone falling back to black, not just rising to white.
        if stripeCount.count > 2, stripeCount[2] > 0 {
            let secondBlackAvg = stripeSum[2] / Float(stripeCount[2])
            XCTAssertGreaterThan(whiteAvg - secondBlackAvg, 0.3,
                                  "expected brightness to drop back down after the white stripe, got \(secondBlackAvg) vs white \(whiteAvg)")
        }
    }
}
