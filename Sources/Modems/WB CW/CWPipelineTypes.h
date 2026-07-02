//
//  CWPipelineTypes.h
//  cocoaModem 2.0
//
//  C types shared between the Swift CW pipeline tree and the remaining
//  Objective-C code (CWMatchedFilter).  These were originally defined in
//  CWPipeline.h; they were extracted here during the Swift port of CWPipeline /
//  CWSpeedPipeline so that CWMatchedFilter.m (which still references
//  ElementType* / MorseTiming) and the Swift side (CWPipeline / CWSpeedPipeline)
//  can share the exact same C struct layout and macros.
//
//  Created during the Swift port (base type author: Kok Chen, 12/25/06).
//

#ifndef _CWPIPELINETYPES_H_
	#define _CWPIPELINETYPES_H_

	#import <Cocoa/Cocoa.h>		//  for Boolean (matches the original CWPipeline.h)

	typedef struct {
		int state ;
		int interval ;
		float max ;
		float min ;
		Boolean valid ;
	} ElementType ;

	typedef struct {
		float interElement ;
		float interSymbol ;
		float dit ;
		float dash ;
		float speed ;
	} MorseTiming ;

	#define	RINGMASK		0xfff					//  4096 elements (0.75 ms per element)
	#define	RINGSIZE		(RINGMASK+1)

	#define WINDOW			60						//  must be less than one buffer (64)
	#define	RINGSTART		(RINGSIZE-WINDOW)

	#define	FILTERLENGTH	1024					//  all filters must use the same length to align the epoch

	#define	dataThreshold	0.5

#endif
