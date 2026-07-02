//
//  AudioManagerTypes.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/5/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port support header (extracted from AudioManager.h).
//
//  AudioManager.m was ported to Swift (Sources/Swift/Audio/AudioManager.swift).
//  Swift cannot import a C struct that contains Objective-C object pointers
//  (NSLock*, ModemAudio*) — the whole struct becomes invisible to Swift — so the
//  RegisteredAudioDevice record below carries those slots as `void *` (identical
//  memory layout; the Swift code round-trips them through Unmanaged, preserving
//  the original MRC "unretained pointer" semantics).  External Objective-C code
//  only ever nil-checks the RegisteredAudioDevice* returned by -audioDeviceForID:
//  and never dereferences it, so the field retyping is invisible outside AudioManager.
//
//  The pre-10.6 CoreAudio calls that AudioManager uses (AudioDeviceGetProperty,
//  AudioDeviceAddIOProc, AudioDeviceAddPropertyListener, …) are marked
//  *unavailable in Swift* (not merely deprecated), so they cannot be called from
//  Swift at all.  The static-inline cm_* shims below re-expose them: Clang compiles
//  the bodies (where the calls are only deprecated) and Swift imports the shims.
//  Behaviour is identical to the original C calls.
//

#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

#define	MAXSTREAMS	16
#define	MAXCHANNELS	16

#define	NODBVALUE	100.0

@class ModemAudio ;

typedef struct {
	AudioValueRange dbRange ;
} DeviceChannel ;

typedef struct {
	int channels ;
	Boolean hasMasterControl ;
	DeviceChannel channelInfo[MAXCHANNELS] ;
} DeviceStream ;

//	Each deviceID has its own IOProc and a list of input and output DeviceStream (see above).
//	NOTE: the ModemAudio* / NSLock* slots of the original struct are carried as void*
//	here (see file comment) so that Swift can import the struct.  Layout is unchanged.
typedef struct {
	AudioDeviceID deviceID ;

	//  actively sampling clients
	int activeInputClients ;
	void *activeInputModemAudio[256] ;		//  ModemAudio* (unretained)
	int activeOutputClients ;
	void *activeOutputModemAudio[256] ;		//  ModemAudio* (unretained)

	//  all clients that need deviceListener
	int inputClients ;
	void *inputModemAudio[256] ;			//  ModemAudio* (unretained)
	int outputClients ;
	void *outputModemAudio[256] ;			//  ModemAudio* (unretained)

	//  stream info for deviceID
	int inputStreams ;
	DeviceStream inputStream[MAXSTREAMS];
	int outputStreams ;
	DeviceStream outputStream[MAXSTREAMS] ;

	void *lock ;							//  NSLock* (retained; released when the record is freed)
	void *propertyListenerProc ;			//  non-nil sentinel: property listener installed

} RegisteredAudioDevice ;


//  ---------------------------------------------------------------------------
//  Shims over the pre-10.6 CoreAudio API (unavailable in Swift; see file comment).
//  These wrap the exact same calls the Objective-C AudioManager made.
//  ---------------------------------------------------------------------------

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static inline OSStatus cm_AudioDeviceGetPropertyInfo( AudioDeviceID inDevice, UInt32 inChannel, Boolean isInput, AudioDevicePropertyID inPropertyID, UInt32* outSize )
{
	return AudioDeviceGetPropertyInfo( inDevice, inChannel, isInput, inPropertyID, outSize, NULL ) ;
}

static inline OSStatus cm_AudioDeviceGetProperty( AudioDeviceID inDevice, UInt32 inChannel, Boolean isInput, AudioDevicePropertyID inPropertyID, UInt32* ioPropertyDataSize, void* outPropertyData )
{
	return AudioDeviceGetProperty( inDevice, inChannel, isInput, inPropertyID, ioPropertyDataSize, outPropertyData ) ;
}

static inline OSStatus cm_AudioDeviceAddIOProc( AudioDeviceID inDevice, AudioDeviceIOProc inProc, void* inClientData )
{
	return AudioDeviceAddIOProc( inDevice, inProc, inClientData ) ;
}

static inline OSStatus cm_AudioDeviceRemoveIOProc( AudioDeviceID inDevice, AudioDeviceIOProc inProc )
{
	return AudioDeviceRemoveIOProc( inDevice, inProc ) ;
}

static inline OSStatus cm_AudioDeviceStart( AudioDeviceID inDevice, AudioDeviceIOProc inProc )
{
	return AudioDeviceStart( inDevice, inProc ) ;
}

static inline OSStatus cm_AudioDeviceStop( AudioDeviceID inDevice, AudioDeviceIOProc inProc )
{
	return AudioDeviceStop( inDevice, inProc ) ;
}

//  The original always registered/removed the property listener with the master
//  element (0) and the section/property wildcards; those constants are baked in
//  here so the exact wildcard values (kAudioPropertyWildcardSection == 0xFF, which
//  CoreAudio treats as a sentinel) reach the API unchanged.
static inline OSStatus cm_AudioDeviceAddWildcardListener( AudioDeviceID inDevice, AudioDevicePropertyListenerProc inProc, void* inClientData )
{
	return AudioDeviceAddPropertyListener( inDevice, /*master*/0, kAudioPropertyWildcardSection, kAudioPropertyWildcardPropertyID, inProc, inClientData ) ;
}

static inline OSStatus cm_AudioDeviceRemoveWildcardListener( AudioDeviceID inDevice, AudioDevicePropertyListenerProc inProc )
{
	return AudioDeviceRemovePropertyListener( inDevice, /*master*/0, kAudioPropertyWildcardSection, kAudioPropertyWildcardPropertyID, inProc ) ;
}

#pragma clang diagnostic pop
