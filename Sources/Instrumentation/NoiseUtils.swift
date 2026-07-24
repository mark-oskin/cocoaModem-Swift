// Swift port of NoiseUtils.c
//
//  NoiseUtils.c
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/8/07.

import Foundation

func initGaussianNoise() {
	//  POSIX srandom()/random() are unavailable in Swift; use arc4random (which
	//  is self-seeding).  This is a noise generator, so the exact PRNG sequence
	//  is not observable — only the [-0x1fff, 0x2000] uniform distribution matters.
}

//  sigma = sqrt( variance )
//  for sd = 1.0, total power = 1.0, noise power/Hz with 11025 sampling rate (5512.5 Hz bandwidth) = 0.000178
func gaussianNoise(_ sigma: Float) -> Float {
	var t: Float
	var i: Int32

	t = 0
	i = 0
	while i < 9 {
		t += Float(Int32(arc4random() & 0x3fff) - 0x1fff)
		i += 1
	}
	t = Float(Double(t * sigma) / (8192.0 * 9.0 * 0.1926))
	return t
}
