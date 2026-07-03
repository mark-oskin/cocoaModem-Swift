// Swift port of error.c
//
//  error.c
//  cocoaModem
//
//  Created by Kok Chen on 3/18/05.

import Foundation

//  BER for non-coherent FSK
//	snr is Eb/No in dB
func BERnFSK(_ snr: Float) -> Float {
	let s: Float

	s = Float(pow(10.0, Double(snr) * 0.1))
	return Float(0.5 * exp(-Double(s) * 0.5))
}

//	BER for non-coherent FSK, 45.45 baud
//	snr is signal to noise ratio within a 3000 Hz noise bandwidth
func BER3kRTTY(_ snr: Float) -> Float {
	let s: Float

	s = Float(Double(snr) + 10.0 * log10(3000.0) - 10.0 * log10(45.45))

	return BERnFSK(s)
}

//	VE3NEA character error rate measure (pseudo synchonous FSK)
//	snr is signal to noise ratio within a 3000 Hz noise bandwidth
func CER(_ snr: Float) -> Float {
	let p: Float, q: Float

	p = BER3kRTTY(snr)
	q = Float(1.0 - Double(p))
	return Float(1.0 - pow(Double(q), 6.0))
}

//	David Mills' word error rate measure (non synchronous FSK, UART model)
//	snr is signal to noise ratio within a 3000 Hz noise bandwidth
func WER(_ snr: Float) -> Float {
	let ber: Float

	ber = BER3kRTTY(snr)
	return WERfromBER(ber)
}

func WERfromBER(_ p: Float) -> Float {
	let q: Float

	q = Float(1.0 - Double(p))
	return Float((1.0 - pow(Double(q), 7.0)) * (0.25 + 4.78 / 2.0 + (2.33 * Double(p) + 3.75 * Double(q)) / 4.0))
}

//   test case for estimating character error rate
//   stop bit error = p
func TER(_ snr: Float) -> Float {
	let p: Float, q: Float, qsync: Float, psync: Float, p5: Float

	p = BER3kRTTY(snr)
	q = 1 - p  //  probability that bit is OK
	qsync = q * q * q
	psync = Float(1.0 - Double(qsync))

	p5 = Float(1.0 - pow(Double(q), 5.0))
	return psync + qsync * p5
}
