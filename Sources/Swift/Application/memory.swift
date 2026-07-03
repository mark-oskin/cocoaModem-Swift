// Swift port of memory.c
//
//  memory.c
//  cocoaModem 2.0
//
//  Created by Kok Chen on 9/30/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.

import Foundation

func cmFree(_ ptr: UnsafeMutableRawPointer!) {
	print("cmFree callled -------")
	//  free( ptr ) ;
}
