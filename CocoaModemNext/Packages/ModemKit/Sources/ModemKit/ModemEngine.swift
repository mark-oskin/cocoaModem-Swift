import Foundation

/// Unifies every mode (PSK, CW, RTTY, MFSK, Hell, FAX, SITOR-B, ASCII...) behind
/// one shape the app shell and audio engine can drive without knowing which
/// mode is active.
public protocol ModemEngine: AnyObject {
    var name: String { get }

    /// The audio hardware's actual sample rate; called once before audio starts
    /// flowing so the engine can set up its device-rate <-> DSP-rate resampling.
    func configure(deviceSampleRate: Double)

    /// Consume one buffer of receive audio (mono, device sample rate).
    func processReceiveAudio(_ samples: UnsafePointer<Float>, count: Int)

    /// Fill `buffer` with up to `count` samples of transmit audio (device sample
    /// rate); returns the number of samples actually written (0 when there is
    /// nothing to send).
    func produceTransmitAudio(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Int

    /// Text decoded from the receive stream since the last read, if any.
    func drainReceivedText() -> String

    /// Queue text for transmission (already-typed characters).
    func queueTransmitText(_ text: String)
}
