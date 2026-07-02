//
//  TextAttribute.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on Sun Apr 04 2004 (as part of AYTextView.h).
//
//  Swift port:  the C TextAttribute struct (and TEXTRINGMASK) were factored
//  out of AYTextView.h so they remain available to the many Obj-C modems that
//  use them, and to AYTextView.swift, now that AYTextView.h is retired.
//

#ifndef _TEXTATTRIBUTE_H_
	#define _TEXTATTRIBUTE_H_

	#import <Cocoa/Cocoa.h>

	#define	TEXTRINGMASK	0x3ff

	//  __unsafe_unretained so the struct stays a plain C aggregate (matching the
	//  original MRC semantics) and remains importable by Swift; AYTextView.swift
	//  manages the retain/release of these fields explicitly via Unmanaged.
	typedef struct {
		__unsafe_unretained NSFont *font ;
		__unsafe_unretained NSColor *textColor ;
		__unsafe_unretained NSDictionary *dictionary ;
	} TextAttribute ;

#endif
