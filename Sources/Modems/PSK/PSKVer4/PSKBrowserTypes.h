//
//  PSKBrowserTypes.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/20/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Shared C struct definitions (Slot, Row) extracted from PSKBrowserTable.h
//  so they remain available to both PSKBrowserHub.m and the Swift port of
//  PSKBrowserTable (PSKBrowserTable.swift, via the bridging header).
//

#ifndef _PSKBROWSERTYPES_H_
	#define _PSKBROWSERTYPES_H_

	#import <Cocoa/Cocoa.h>

	typedef struct {
		int row ;
		float frequency ;
		Boolean active ;
		int spaces ;
		unichar message[1025] ;
		int length ;
	} Slot ;

	typedef struct {
		int slot ;
		Boolean dirty ;
		int refreshedCount ;
		int refreshNeeded ;
	} Row ;

#endif
