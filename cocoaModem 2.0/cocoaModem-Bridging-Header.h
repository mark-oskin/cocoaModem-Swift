//
//  cocoaModem-Bridging-Header.h
//  Objective-C declarations exposed to Swift.
//
//  After the full Swift migration, almost every class is Swift; this exposes
//  only the remaining C-type / C-function headers and //  remaining C interop shims (AudioManagerTypes cm_* CoreAudio shims + shared C value-type headers).
//

#import "CoreFilter.h"		//  CMFFT/CMFIR C structs + FFT/FIR C functions
#import "CoreModemTypes.h"	//  CMTonePair / CMDataStream / CMDDA / ...

//  --- C-type / shared-struct headers ---
#import "RoundupStatelist.h"	//  StateList
#import "ContestTypes.h"	//  ContestQSO / Callsign
#import "MFSKModes.h"		//  DOMINOEX*/MFSK16 tags
#import "PrivateNSFont.h"	//  NSFont _defaultGlyphForChar:
#import "CMATCTypes.h"		//  CMATCPair / RTTYByte
#import "TextAttribute.h"	//  TextAttribute (Modem.swift)
#import "FAXFrame.h"		//  BackingFrame struct
#import "AudioManagerTypes.h"	//  RegisteredAudioDevice + CoreAudio shims
#import "AudioDeviceTypes.h"	//  AudioSoundFile (AIFFSource.swift)
#import "PSKBrowserTypes.h"	//  Slot / Row
#import "CMVaricodeTypes.h"	//  Encoding
#import "CWPipelineTypes.h"	//  ElementType / MorseTiming
#import "RTTYTypes.h"		//  RTTYConfigSet struct (RTTY config Swift classes)
#import "Plist.h"		//  plist key macros
