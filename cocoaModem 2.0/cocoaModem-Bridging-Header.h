//
//  cocoaModem-Bridging-Header.h
//  Objective-C declarations exposed to Swift.
//

#import "audioutils.h"		//  Application.swift initAudioUtils()
#import "RoundupStatelist.h"	//  StateList (RTTYRoundupMults.swift)
#import "ContestTypes.h"	//  ContestQSO/Callsign structs
#import "CMTappedPipe.h"	//  base of PSKMonitor/RTTYMonitor.swift
#import "CoreFilter.h"		//  CMFFT/CMFIR + FFT/FIR C funcs
#import "CoreModemTypes.h"	//  CMTonePair
#import "CoreModem.h"		//  extern mssin/lssin/mscos/lscos tables (CMNCO.swift)
#import "Modem.h"		//  Waterfall/many call back into Modem

//  --- still-ObjC base classes subclassed by converted Swift (remove each when it converts) ---
#import "ModemConfig.h"
#import "CMATC.h"
#import "RTTYBaudotDecoder.h"
#import "RTTYDemodulator.h"
#import "RTTYReceiver.h"
#import "RTTYTxConfig.h"
#import "CMToneReceiver.h"
#import "ContestInterface.h"
#import "WFRTTY.h"
#import "WFRTTYConfig.h"
#import "CMBaudotDecoder.h"
#import "CMFSKDemodulator.h"
#import "CWMatchedFilter.h"	//  CWPipeline.swift client type + CWPipelineTypes
#import "PSKDemodulator.h"	//  PSKHub.swift mainDemodulator

//  --- C-types / shared struct headers ---
#import "MFSKModes.h"
#import "PrivateNSFont.h"
#import "CMATCTypes.h"
#import "FAXFrame.h"
#import "AudioManagerTypes.h"
#import "PSKBrowserTypes.h"
#import "CMVaricodeTypes.h"	//  Encoding struct (CMVaricode.swift)
#import "CWPipelineTypes.h"	//  ElementType/MorseTiming (CWMatchedFilter.h)
#import "Plist.h"
#import "Boxcar.h"		//  BoxcarFilter C funcs (CWPipeline.swift)
#import "HellschreiberFont.h"	//  HellschreiberFontHeader (HellModulator.swift)

//  --- ObjC classes referenced by converted Swift ---
#import "ModemAudio.h"		//  AudioManager.swift
#import "PSK.h"			//  PSKControl/PSKHub/PSKTransmitControl.swift
#import "PSKReceiver.h"		//  PSKControl.swift
#import "PSKAuralMonitor.h"	//  PSKTransmitControl.swift
#import "LitePSKMatchedFilter.h"	//  LitePSKDemodulator.swift
#import "KeyerInterface.h"	//  obtainRouterPorts C funcs (Router/MicroKeyer.swift)
#import "ContestManager.h"	//  StdManager.swift
//  concrete modems StdManager.swift instantiates (all still ObjC in the CMPipe tree)
#import "RTTY.h"
#import "DualRTTY.h"
#import "MFSK.h"
#import "Hellschreiber.h"
#import "SITOR.h"
#import "ASCII.h"
#import "FAX.h"
#import "WBCW.h"
#import "LiteRTTY.h"
#import "LitePSK.h"
