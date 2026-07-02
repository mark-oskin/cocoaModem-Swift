//
//  ContestTypes.h
//  cocoaModem 2.0
//
//  C types shared between the Swift Contest tree and the remaining
//  Objective-C code (ContestManager).  These were originally defined in
//  Contest.h; they were extracted here during the Swift port of Contest so
//  that ContestManager.m (which still references ContestQSO*) and the Swift
//  side (ContestQSOObj / Contest / RTTYRoundupMults) can share the exact
//  same C struct layout.
//
//  Created during the Swift port (base type author: Kok Chen).
//

#ifndef _CONTESTTYPES_H_
	#define _CONTESTTYPES_H_

	#include "cocoaModemParams.h"
	#include "modemTypes.h"		//  DateTime

	#define MAXQ	8192

	typedef struct _ContestQSO ContestQSO ;
	typedef struct _Callsign Callsign ;

	struct _ContestQSO {
		Callsign *callsign ;
		char *exchange ;
		ContestQSO *next ;
		float frequency ;
		short rst ;
		short mode ;
		unsigned short qsoNumber ;
		DateTime time ;
	} ;

	struct _Callsign {
		char callsign[64] ;
		ContestQSO *link ;
		Callsign *next ;
	} ;

#endif
