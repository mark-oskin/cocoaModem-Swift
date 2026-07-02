//
//  cocoaModem-Bridging-Header.h
//  Objective-C declarations exposed to Swift.
//

#import "AppDelegate.h"		//  used by VoiceAssistTextField.swift
#import "Application.h"		//  used by ModemSleepManager.swift, VoiceAssistTextField.swift
#import "Messages.h"		//  used by MacroScripts.swift
#import "Preferences.h"		//  used by UserInfo.swift
#import "StripPhi.h"		//  base class of QSO.swift
#import "CMTappedPipe.h"	//  base class of PSKMonitor/RTTYMonitor.swift (Instrumentation)
#import "CoreFilter.h"		//  CMFFT/CMFIR + FFTSpectrum/CMPerformFFT/CMSinc/... (Instrumentation)
#import "CoreModemTypes.h"	//  CMTonePair (Instrumentation waterfalls/spectra/monitors)
#import "Modem.h"		//  Waterfall.swift calls back into Modem (clicked:/isActiveTab/...)

//  --- still-ObjC base classes subclassed by converted Swift (remove each when it converts) ---
#import "ModemConfig.h"
#import "CMATC.h"
#import "RTTYBaudotDecoder.h"
#import "RTTYDemodulator.h"
#import "RTTYModulator.h"
#import "RTTYReceiver.h"
#import "RTTYTxConfig.h"
#import "MacroSheet.h"
#import "MSKGenerator.h"
#import "CMToneReceiver.h"
#import "ContestInterface.h"
#import "WFRTTY.h"
#import "WFRTTYConfig.h"
#import "CMBaudotDecoder.h"
#import "CMFSKDemodulator.h"
