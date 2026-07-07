import XCTest
@testable import CoreDSP

/// SITOR-B is receive-only in this app (see SITOREngineCore's header comment
/// -- the original cocoaModem SITOR.swift itself documents "Receive-only (no
/// transmitter)", and no SITORModulator exists anywhere in the old source),
/// so there is no TX->RX loopback to run like PSKLoopbackTests/
/// RTTYLoopbackTests. Instead, exactly like FAXLoopbackTests, this
/// synthesizes the continuous-phase FSK waveform a real SITOR-B/NAVTEX
/// transmitter would send -- mark tone (2125 Hz) for '1' bits, space tone
/// (2295 Hz) for '0' bits, 100 baud, CCIR-476 Moore codewords transmitted
/// LSB-first (verified against MooreDecoder's bit-shift-register convention:
/// the first bit shifted in ends up at the register's LSB) -- and feeds it
/// straight into SITOREngineCore.receiveSamples, then asserts the decoded
/// text contains the original characters.
///
/// SITOR-B/AMTOR's FEC scheme repeats every character exactly 35 bit-periods
/// (5 character-widths) later (MooreDecoder compares the current 7-bit
/// window against bitRegister[5]); a signal whose bit period is an exact
/// divisor of 35 (e.g. a single repeated character, period 7) satisfies the
/// decoder's "perfect copy" fast path (err == 0) at every bit position once
/// the pipeline has filled, independent of the receive-side sync-phase lock
/// -- which is what the test below relies on for a clean, deterministic
/// assertion.
final class SITORLoopbackTests: XCTestCase {

    /// LSB-first bit order (matches MooreDecoder.importData's shift-register
    /// convention -- the earliest-sent bit ends up at bitRegister[0]'s LSB).
    private func codewordBits(_ code: Int32) -> [Int] {
        (0..<7).map { (Int(code) >> $0) & 1 }
    }

    /// Synthesizes a continuous-phase FSK burst for `bits` (mark tone per '1',
    /// space tone per '0') at 100 baud / CMFs (11025 Hz), feeding it into `rx`
    /// 512 samples at a time.
    private func transmit(bits: [Int], mark: Double, space: Double, rx: SITOREngineCore, phase: inout Double) {
        let sampleRate = CMFs
        let baud = 100.0
        //  11025 / 100 = 110.25 samples/bit -- not an integer, so bit
        //  boundaries are tracked with a persistent fractional accumulator
        //  (rather than rounding each bit's duration independently, which
        //  would systematically drift the long-run baud rate away from 100).
        let samplesPerBit = sampleRate / baud
        var scratch = [Float](repeating: 0, count: 512)
        var scratchCount = 0

        func emit(_ sample: Float) {
            scratch[scratchCount] = sample
            scratchCount += 1
            if scratchCount == 512 {
                scratch.withUnsafeBufferPointer { buf in
                    rx.receiveSamples(buf.baseAddress!, count: 512)
                }
                scratchCount = 0
            }
        }

        var bitBoundary = samplesPerBit
        var sampleIndex = 0.0
        for bit in bits {
            let freq = (bit != 0) ? mark : space
            while sampleIndex < bitBoundary {
                emit(Float(sin(phase)))
                phase += 2.0 * Double.pi * freq / sampleRate
                if phase > 2.0 * Double.pi * 1_000_000 { phase = phase.truncatingRemainder(dividingBy: 2.0 * Double.pi) }
                sampleIndex += 1
            }
            bitBoundary += samplesPerBit
        }
        //  flush partial 512-sample tail with silence so the last bits reach the demodulator
        while scratchCount != 0 { emit(0) }
    }

    /// Look up a CCIR-476 LTRS codeword for a plain ASCII character (must be one of the
    /// letters/space/CR/LF actually present in MooreCode.ltrs).
    private func ltrsCodeword(for char: Character) -> Int32 {
        let target = Int8(char.asciiValue!)
        guard let idx = MooreCode.ltrs.firstIndex(of: target) else {
            fatalError("no CCIR-476 LTRS codeword for \(char)")
        }
        return Int32(idx)
    }

    /// A single repeated codeword (period 7 bits) is a multiple of the FEC
    /// tap's 35-bit delay, so MooreDecoder's "perfect copy" path (bit-exact
    /// match, squelch-independent) applies at literally every bit position
    /// once the pipeline has filled. But a bare repeated letter, with no
    /// RQ/alpha phasing markers anywhere in the stream, is the maximally
    /// *ambiguous* case for the sync-phase voting in `importData`: every one
    /// of the 14 cycle phases sees an identical, symmetric "vector ==
    /// repeatedFrom" hit rate, so once a real RQ/alpha phasing preamble's
    /// tie-breaking advantage decays away (nothing in a bare repeated letter
    /// keeps reinforcing one phase over the others), the lock can wander to
    /// a different phase over a long enough run -- confirmed empirically.
    /// Real SITOR-B/AMTOR FEC traffic is never a single repeated letter for
    /// this reason (see testRepeatingPhraseDecodesAllCharacters for a
    /// realistic multi-character message, which stays locked for the full
    /// run). This test mirrors standard practice by leading with an
    /// RQ/alpha phasing preamble (MooreDecoder's probability formula gives
    /// RQ/alpha sightings extra weight -- the `prob *= 1.4` modifiers), then
    /// checks the short window immediately afterwards -- exactly the
    /// "does it phase in correctly" behavior a real receiver is judged on.
    func testRepeatedCharacterLocksAndDecodesAfterPhasingPreamble() {
        let rx = SITOREngineCore()
        let code = ltrsCodeword(for: "E")   // CCIR-476 LTRS 'E' = 0x29
        let rq = MooreCode.rq
        let alpha = MooreCode.alpha

        var bits: [Int] = []
        for _ in 0..<40 { bits += codewordBits(rq) + codewordBits(alpha) }   // phasing preamble
        for _ in 0..<40 { bits += codewordBits(code) }                      // 280 bits of 'E' (~2.8s)

        var phase = 0.0
        transmit(bits: bits, mark: 2125, space: 2295, rx: rx, phase: &phase)

        let decoded = rx.drainReceivedText()
        XCTAssertFalse(decoded.isEmpty, "expected the FSK->Moore chain to decode at least one character, got nothing")

        let eCount = decoded.filter { $0 == "E" }.count
        XCTAssertGreaterThan(eCount, decoded.count / 2,
                              "expected the decoded stream to be dominated by 'E' (the repeated character) once phased in, got: \(decoded.debugDescription)")
    }

    /// A 5-character repeating phrase (35 bits == the FEC tap delay) also
    /// satisfies the "perfect copy" fast path at every bit position, so all 5
    /// characters should eventually appear in the decoded stream (their
    /// relative order isn't asserted: MooreDecoder's sync-phase lock only
    /// fires once per super-cycle at whichever of the 5 aligned phases it
    /// locks onto first, so distinct characters can interleave with a
    /// non-1:1 cadence -- what matters is that every transmitted character
    /// is genuinely recoverable end-to-end.)
    func testRepeatingPhraseDecodesAllCharacters() {
        let rx = SITOREngineCore()
        let phrase: [Character] = ["T", "E", "S", "T", " "]
        let codewords = phrase.map { ltrsCodeword(for: $0) }

        var bits: [Int] = []
        for _ in 0..<80 {                      // 80 * 5 chars * 7 bits = 2800 bits = 28s of audio
            for code in codewords { bits += codewordBits(code) }
        }

        var phase = 0.0
        transmit(bits: bits, mark: 2125, space: 2295, rx: rx, phase: &phase)

        let decoded = rx.drainReceivedText()
        XCTAssertFalse(decoded.isEmpty, "expected the FSK->Moore chain to decode at least one character, got nothing")

        let decodedSet = Set(decoded)
        for expected in Set(phrase) {
            XCTAssertTrue(decodedSet.contains(expected),
                           "expected '\(expected)' to appear somewhere in the decoded output, got: \(decoded.debugDescription)")
        }
    }
}
