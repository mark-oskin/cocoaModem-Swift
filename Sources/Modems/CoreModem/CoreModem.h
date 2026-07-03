/*
 *  CoreModem.h
 *  CoreModem
 *
 *  Created by Kok Chen on 10/24/05.
 *
 */

#ifndef _COREMODEM_H_
	#define _COREMODEM_H_
	
	@class CMFSKDemodulator ;
	@class CMFSKMatchedFilter ;
	
	//  CMFilterBank / CMBandpassFilter are now Swift (cocoaModem-Swift.h).  Swift port batch A.
	@class CMFilterBank ;
	@class CMBandpassFilter ;

	@interface CoreModem : NSObject {
	}
	@end
	
	//  static sin/cos tables
	extern float *mssin, *lssin, *mscos, *lscos ;

#endif
