//
//  CoreFilter.h
//  Filter (CoreModem)
//
//  Created by Kok Chen on 11/11/05.

#ifndef _COREFILTER_H_
	#define _COREFILTER_H_

	#import "CoreFilterTypes.h"
	//  CMPipe / CMTappedPipe are now Swift (cocoaModem-Swift.h); forward-declare
	//  here so this umbrella still type-checks for pointer use.  Swift port batch A.
	@class CMPipe ;
	@class CMTappedPipe ;
	#import "CMFIR.h"
	#import "CMIIR.h"
	#import "CMFFT.h"
	#import "CMDSPWindow.h"
	#import "CMComplexFIR.h"

#endif
