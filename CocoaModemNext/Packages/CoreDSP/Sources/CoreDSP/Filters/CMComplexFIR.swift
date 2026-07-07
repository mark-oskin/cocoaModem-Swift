// Swift port of CMComplexFIR.c
//
//  CMComplexFIR.c
//  Filter (CoreModem)
//
//  Created by Kok Chen on 11/3/05.

import Foundation

struct CMComplexFIR {
	var re: UnsafeMutablePointer<CMFIR>!
	var im: UnsafeMutablePointer<CMFIR>!
}

//  return a zero filled AnalyticBuffer
func CMMallocAnalyticBuffer(_ size: Int32) -> UnsafeMutablePointer<CMAnalyticBuffer>! {
	let b = UnsafeMutablePointer<CMAnalyticBuffer>.allocate(capacity: 1)
	let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(size))
	let q = UnsafeMutablePointer<Float>.allocate(capacity: Int(size))
	b.pointee.re = p
	b.pointee.im = q
	b.pointee.size = size

	var i: Int32 = 0
	while i < size { p[Int(i)] = 0; q[Int(i)] = 0; i += 1 }
	return b
}

func CMShiftAnalyticBuffer(_ b: UnsafeMutablePointer<CMAnalyticBuffer>!, _ samples: Int32) {
	let n = MemoryLayout<Float>.size * Int(512 - samples)
	memmove(b!.pointee.re, b!.pointee.re + Int(samples), n)
	memmove(b!.pointee.im, b!.pointee.im + Int(samples), n)
}

func freeAnalyticBuffer(_ b: UnsafeMutablePointer<CMAnalyticBuffer>!) {
	b!.pointee.re.deallocate()
	b!.pointee.im.deallocate()
	b!.deallocate()
}

func CMComplexFIRDecimateWithCutoff(_ factor: Int32, _ cutoff: Float, _ fsampling: Float, _ activeTaps: Int32) -> UnsafeMutablePointer<CMComplexFIR>! {
	let fir = UnsafeMutablePointer<CMComplexFIR>.allocate(capacity: 1)

	fir.pointee.re = CMFIRDecimateWithCutoff(factor, cutoff, fsampling, activeTaps)
	fir.pointee.im = CMFIRDecimateWithCutoff(factor, cutoff, fsampling, activeTaps)
	return fir
}

func CMDecimateAnalyticBuffer(_ fir: UnsafeMutablePointer<CMComplexFIR>!, _ inBuffer: UnsafeMutablePointer<CMAnalyticBuffer>!, _ offset: Int32) -> CMAnalyticPair {
	var result = CMAnalyticPair()

	result.re = CMDecimate(fir!.pointee.re, inBuffer!.pointee.re + Int(offset))
	result.im = CMDecimate(fir!.pointee.im, inBuffer!.pointee.im + Int(offset))

	return result
}

func CMDeleteComplexFIR(_ fir: UnsafeMutablePointer<CMComplexFIR>!) {
	CMDeleteFIR(fir!.pointee.re)
	CMDeleteFIR(fir!.pointee.im)
	fir!.deallocate()
}
