// Swift port of Boxcar.c
//
//  Boxcar.c
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/10/06.

//  create boxcar filter with length, allowing maximum adustment to maxlength
func BoxcarFilter(_ length: Int32, _ maxLength: Int32) -> UnsafeMutablePointer<CMFIR>! {
	var maxLength = maxLength

	if maxLength < length { maxLength = length }

	let filter = CMFIRLowpassFilter(20 /* not important */, 11025 /*not important*/, maxLength)
	var k = filter!.pointee.kernel!
	let n = filter!.pointee.activeTaps
	let gain = Float(1.0 / Double(length))
	var i: Int32 = 0
	while i < length { k.pointee = gain; k += 1; i += 1 }
	while i < n { k.pointee = 0; k += 1; i += 1 }

	return filter
}

//  Blackman window
func BlackmanWindow(_ length: Int32, _ maxLength: Int32) -> UnsafeMutablePointer<CMFIR>! {
	var maxLength = maxLength
	if maxLength < length { maxLength = length }

	let filter = CMFIRLowpassFilter(20 /* not important */, 11025 /*not important*/, maxLength)
	adjustBlackmanWindow(filter, length)

	return filter
}

func adjustBlackmanWindow(_ filter: UnsafeMutablePointer<CMFIR>!, _ length: Int32) {
	var length = length

	var k = filter!.pointee.kernel!
	let n = filter!.pointee.activeTaps
	if length > n { length = n }

	var gain: Float = 0.0
	var i: Int32 = 0
	i = 0
	while i < n - length { k.pointee = 0; k += 1; i += 1 }
	i = 0
	while i < length {
		let x = Float(CMBlackmanWindow(i, length))
		k.pointee = x
		gain += x
		k += 1          //  advance the kernel pointer (the C original was *k++ = x)
		i += 1
	}
	gain = Float(1.0 / Double(gain))
	k = filter!.pointee.kernel!
	i = 0
	while i < n { k.pointee *= gain; k += 1; i += 1 }
}

func adjustBoxcarFilter(_ filter: UnsafeMutablePointer<CMFIR>!, _ length: Int32) {
	var length = length

	var k = filter!.pointee.kernel!
	let n = filter!.pointee.activeTaps

	if length > n { length = n }
	let gain = Float(1.0 / Double(length))

	let excess = (n - length)
	var i: Int32 = 0
	while i < excess { k.pointee = 0; k += 1; i += 1 }
	while i < n { k.pointee = gain; k += 1; i += 1 }
}

//  constant slope rising and falling edges
func adjustWaveshapedBoxcarFilter(_ filter: UnsafeMutablePointer<CMFIR>!, _ length: Int32) {
	var length = length

	var k = filter!.pointee.kernel!
	let n = filter!.pointee.activeTaps
	if length > n { length = n }
	let gain = Float(1.0 / Double(length))
	var i: Int32 = 0
	while i < 3 { k.pointee = Float(Double(i) * 0.33 * Double(gain)); k += 1; i += 1 }
	while i < length - 3 { k.pointee = gain; k += 1; i += 1 }
	while i < length { k.pointee = Float(Double(length - i) * 0.33 * Double(gain)); k += 1; i += 1 }
	while i < n { k.pointee = 0; k += 1; i += 1 }
}
