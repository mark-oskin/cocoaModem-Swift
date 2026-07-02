//
//  FAXFrame.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/24/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#define	MAXFAXHEIGHT	3200
#define	MAXBACKING		((MAXFAXHEIGHT+64)*2000)			// allow 600 scanline headroom and 2000 samples wide
#define BACKGROUND		112									//  gary background value


//  backing store parameters
typedef struct {
	int origin ;					//  point to origin in backing[], this number is always less than MAXBACKING
	int rows ;
	float correction ;				//  fractional correction of frame
	int input ;						//  next input location.  offset from frameOrigin, this number can be greater than MAXBACKING
	int mark ;						//  location to process data, offset from frameOrigin, this number can be greater than MAXBACKING
	int horizontalOffset ;	
	unsigned char *backing ;
	unsigned char *intensity ;	
	Boolean halfSize ;
	int displayRow, skipRow ;
} BackingFrame ;


//  The FAXFrame class itself was ported to Swift (see
//  Sources/Swift/Modems/HF-FAX/FAXFrame.swift and cocoaModem-Swift.h).  This
//  header now only publishes the shared C types (BackingFrame + macros above)
//  that the Swift class and the Objective-C FAXView / FAXDisplay all consume.
