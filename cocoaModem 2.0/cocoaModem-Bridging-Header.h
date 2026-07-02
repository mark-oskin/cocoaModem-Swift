//
//  cocoaModem-Bridging-Header.h
//  Objective-C declarations exposed to Swift.
//

#import "Preferences.h"		//  used by UserInfo.swift
#import "StdManager.h"		//  Application.swift stdManager outlet
#import "Config.h"		//  Application.swift config ivar
#import "NetReceive.h"		//  Application.swift NetAudio port construction
#import "NetSend.h"		//  Application.swift NetAudio port construction
#import "audioutils.h"		//  Application.swift initAudioUtils()
#import "Contest.h"		//  ContestQSO/Callsign/band()/... (Contest model Swift classes)
#import "RoundupStatelist.h"	//  StateList (RTTYRoundupMults.swift)
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
#import "ModemManager.h"		//  SynchAM.swift init(into:nib:manager:)
#import "MFSKModes.h"		//  DOMINOEX*/MFSK16 tags (ScrollingField.swift)
#import "PrivateNSFont.h"	//  NSFont _defaultGlyphForChar: (ScrollingField.swift)
#import "CMATCTypes.h"		//  CMATCPair/RTTYByte (AnalyzeScope/RTTYDecoder.swift)
#import "FAXFrame.h"		//  BackingFrame struct (FAXFrame.swift)

//  --- Wave 4 (Audio / PSK / serial-PTT) ---
#import "AudioManagerTypes.h"	//  RegisteredAudioDevice + CoreAudio shims (AudioManager.swift)
#import "ModemAudio.h"		//  AudioManager.swift calls ModemAudio
#import "PSK.h"			//  PSKControl.swift
#import "PSKReceiver.h"		//  PSKControl.swift (delayedRelease ivar moved to .m)
#import "PSKBrowserHub.h"	//  PSKBrowserTable/LitePSKDemodulator.swift
#import "PSKBrowserTypes.h"	//  Slot/Row (PSKBrowserTable.swift)
#import "VCO8k.h"		//  LitePSKDemodulator.swift
#import "LitePSKMatchedFilter.h"	//  LitePSKDemodulator.swift
#import "CMVaricode.h"		//  LitePSKDemodulator.swift
#import "Plist.h"		//  plist key macros (PSKBrowserTable.swift)
#import "FSKHub.h"		//  PTT/FSK/DigitalInterfaces.swift (pulls PTTHub/KeyerInterface/obtainRouterPorts)
#import "VOXInterface.h"		//  DigitalInterfaces.swift
#import "CocoaPTTInterface.h"	//  DigitalInterfaces.swift
#import "UserPTTInterface.h"	//  DigitalInterfaces.swift
#import "MacLoggerDX.h"		//  DigitalInterfaces.swift
