//
//  CMVaricodeTypes.h
//  CoreModem
//
//  Created by Kok Chen on 11/02/05.
//
//  C type shared between the Swift CMVaricode and the remaining Objective-C
//  code (PSKModulator, ...).  The Encoding struct was originally defined in
//  CMVaricode.h; it was extracted here during the Swift port of CMVaricode so
//  that Objective-C callers (which use `[varicode encode:]->bits` /
//  `->length`) and the Swift CMVaricode can share the exact same C struct
//  layout.  (Swift structs are not visible to Objective-C.)
//

#ifndef _CMVARICODETYPES_H_
	#define _CMVARICODETYPES_H_

	typedef struct {
		char bits[16] ;
		int length ;
	} Encoding ;

#endif
