// Swift port of Clears.c
//
//  Clears.c
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/10/06.

func clearLong(_ p: UnsafeMutablePointer<Int>!, _ length: Int32) {
	var p = p
	var i: Int32 = 0
	while i < length {
		p!.pointee = 0
		p = p! + 1
		i += 1
	}
}

func clearInt(_ p: UnsafeMutablePointer<Int32>!, _ length: Int32) {
	var p = p
	var i: Int32 = 0
	while i < length {
		p!.pointee = 0
		p = p! + 1
		i += 1
	}
}

func clearFloat(_ p: UnsafeMutablePointer<Float>!, _ length: Int32) {
	var p = p
	var i: Int32 = 0
	while i < length {
		p!.pointee = 0.0
		p = p! + 1
		i += 1
	}
}

func clearChar(_ p: UnsafeMutablePointer<CChar>!, _ length: Int32) {
	var p = p
	var i: Int32 = 0
	while i < length {
		p!.pointee = 0
		p = p! + 1
		i += 1
	}
}
