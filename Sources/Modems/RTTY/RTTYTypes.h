/*
 *  RTTYTypes.h
 *  cocoaModem 2.0
 *
 *  Created by Kok Chen on 1/6/06.
 */

#ifndef _RTTYTYPES_H_
	#define _RTTYTYPES_H_

	typedef struct {
		int channel ;					// LEFTCHANNEL
		__unsafe_unretained NSString *inputDevice ;			// kRTTYInputDevice
		__unsafe_unretained NSString *outputDevice ;		// kRTTYOutputDevice
		__unsafe_unretained NSString *outputLevel ;			// kRTTYOutputLevel
		__unsafe_unretained NSString *outputAttenuator ;	// kRTTYOutputAttenuator
		__unsafe_unretained NSString *tone ;				// kRTTYTone
		__unsafe_unretained NSString *mark ;				// kRTTYMark
		__unsafe_unretained NSString *space ;				// kRTTYSpace
		__unsafe_unretained NSString *baud ;				// kRTTYBaud
		__unsafe_unretained NSString *controlWindow ;		// nil, or kDualRTTYMainControlWindow
		__unsafe_unretained NSString *squelch ;				// kRTTYSquelch
		__unsafe_unretained NSString *active ;				// kRTTYActive
		__unsafe_unretained NSString *stopBits ;			// kRTTYStopBits
		__unsafe_unretained NSString *sideband ;			// kRTTYMode
		__unsafe_unretained NSString *rxPolarity ;			// kRTTYRxPolarity
		__unsafe_unretained NSString *txPolarity ;			// kRTTYTxPolarity
		__unsafe_unretained NSString *prefs ;				// kRTTYPrefs
		__unsafe_unretained NSString *textColor ;			// kRTTYTextColor
		__unsafe_unretained NSString *sentColor ;			// kRTTYSentColor
		__unsafe_unretained NSString *backgroundColor ;		// kRTTYBackgroundColor		
		__unsafe_unretained NSString *plotColor ;			// kRTTYPlotColor	
		__unsafe_unretained NSString *vfoOffset ;			// nil, or kWFRTTYOffset
		__unsafe_unretained NSString *fskSelection ;		// nil, or kRTTYFSKSelection
		Boolean  usesRTTYAuralMonitor ;
		__unsafe_unretained NSString *auralMonitor ;		// nil, or name of sub dictionary
	} RTTYConfigSet ;
	
#endif

