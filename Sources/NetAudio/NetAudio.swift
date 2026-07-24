//
//  NetAudio.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/31/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of NetAudio.m.
//
//  NetAudio is the (abstract) base of the AUNetReceive / AUNetSend wrappers.
//  NetReceive and NetSend are the concrete subclasses.
//

import Cocoa
import AudioToolbox
import AudioUnit

//  ---- run-state machine (was the NetAudioRunState C enum) ------------------
enum NetAudioRunState: Int32 {
	case idle = 0			//  kNetAudioIdle
	case started			//  kNetAudioStarted
	case running			//  kNetAudioRunning
	case stopped			//  kNetAudioStopped
}

//  ---- NSConditionLock conditions (was the LockCondition C enum) ------------
let kWaitForCommand   = 0
let kCommandAvailable = 1

//  ---- NetAudioStruct -------------------------------------------------------
//  The original was a plain C struct held inline in the object and handed to the
//  AUNetSend render callback by pointer (as inputProcRefCon).  In Swift it is a
//  reference type; a NetAudio instance owns it strongly, so we can pass an
//  Unmanaged.passUnretained(...) opaque pointer to the C render callback and the
//  box is guaranteed to outlive the audio unit.
//
//  netSendObj / delegate are held non-retaining (the original stored plain `id`
//  by assignment) -> modelled as `weak` to avoid retain cycles.
final class NetAudioStruct {
	weak var netSendObj: NetAudio?
	weak var delegate: AnyObject?
	var runState: NetAudioRunState = .idle
	var raisedCosine = [Float]( repeating: 0, count: 512 )
}

@objc(NetAudio)
class NetAudio: NSObject {

	//  ---- ivars (former Obj-C instance variables) ------------------------
	//  base ivars accessed by the NetReceive / NetSend subclasses -> internal
	internal var isReceive: Bool = false				//  direction true for NetReceive, false for NetSend
	internal var serviceNameValue: String?				//  (was the `serviceName` ivar; -serviceName is a method)
	internal var netAudioStruct = NetAudioStruct()

	//  Timer thread
	internal var timerThreadLock: NSConditionLock!
	private var timerThread: Thread?					//  declared in the original, never assigned

	//  sampling process
	internal var tickLock: NSLock!
	internal var runTimer: Timer?

	//  device parameters
	internal var channels: UInt32 = 2					//  stereo = 2
	internal var samplesPerBuffer: UInt32 = 0			//  typically 512
	internal var samplingRate: Float = 44100.0			//  typically 44100.0

	//  AudioUnit buffers.
	//  The original kept `AudioBufferList bufferList; AudioBuffer audioBuffer[2];`
	//  as adjacent ivars and wrote bufferList.mBuffers[1] past the 1-element inline
	//  array (an in-place overallocation hack).  Here we allocate a correctly sized
	//  AudioBufferList (maximumBuffers: channels) which is the modern, safe
	//  equivalent and folds in the audioBuffer[2] scratch.
	internal var bufferList: UnsafeMutableAudioBufferListPointer!
	internal var dataBuffer: [UnsafeMutablePointer<Float>?] = [ nil, nil ]
	internal var timeStamp = AudioTimeStamp()

	//  ---- init / deinit ---------------------------------------------------

	override init()
	{
		super.init()
		runTimer = nil
		tickLock = NSLock()
		serviceNameValue = nil

		channels = 2
		samplingRate = 44100.0
		netAudioStruct.delegate = nil
		netAudioStruct.runState = .idle

		for i in 0..<512 {
			netAudioStruct.raisedCosine[i] = Float( ( 1 - cos( Double(i)*3.1415926535/512.0 ) )*0.5 )
		}
		timerThreadLock = NSConditionLock( condition: kWaitForCommand )
		Thread.detachNewThreadSelector( #selector(timerThread(_:)), toTarget: self, with: self )
	}

	//  The base -initWithService returned nil in the original; the concrete work is
	//  done by the NetReceive / NetSend overrides.
	@objc(initWithService:delegate:samplesPerBuffer:)
	init?( service: String?, delegate inDelegate: Any?, samplesPerBuffer size: Int32 )
	{
		super.init()
		return nil
	}

	deinit
	{
		if runTimer != nil {
			netAudioStruct.runState = .idle
		}
		freeBuffers()
		//  free the AudioBufferList we allocated in -setBufferSize (the original's
		//  inline ivar needed no free; our heap allocation does).
		if bufferList != nil {
			free( bufferList.unsafeMutablePointer )
		}
	}

	//  ---- thread ----------------------------------------------------------

	//  return true to quit thread
	@objc(runThread)
	func runThread() -> Bool
	{
		//  override in subclasses to do something.
		return true
	}

	//  timer thread
	@objc(timerThread:)
	func timerThread( _ ourself: Any? )
	{
		autoreleasepool {
			RunLoop.current.run()

			while true {
				timerThreadLock.lock( whenCondition: kCommandAvailable )
				timerThreadLock.unlock( withCondition: kWaitForCommand )
				if runThread() { break }
			}
		}
	}

	//  ---- buffers ---------------------------------------------------------

	//  set/reset buffer size
	@objc(setBufferSize:)
	func setBufferSize( _ size: Int32 )
	{
		if runTimer != nil {
			//  first, stop any sampling process
			runTimer!.invalidate()
			runTimer = nil
		}
		samplesPerBuffer = UInt32( size )
		let bufSize = Int( samplesPerBuffer )*MemoryLayout<Float>.size

		if bufferList == nil {
			bufferList = AudioBufferList.allocate( maximumBuffers: Int( channels ) )
		}
		bufferList.count = Int( channels )				//  mNumberBuffers = channels

		for i in 0..<Int( channels ) {
			if let db = dataBuffer[i] { free( db ) }
			let db = malloc( bufSize )!.assumingMemoryBound( to: Float.self )
			dataBuffer[i] = db
			bufferList[i] = AudioBuffer( mNumberChannels: 1,
										 mDataByteSize: UInt32( bufSize ),
										 mData: UnsafeMutableRawPointer( db ) )
		}
	}

	@objc(freeBuffers)
	func freeBuffers()
	{
		for i in 0..<Int( channels ) {
			if let db = dataBuffer[i] {
				free( db )
				dataBuffer[i] = nil			//  nil out (the original left dangling pointers)
			}
		}
	}

	//  ---- delegate / accessors -------------------------------------------

	@objc(setDelegate:)
	func setDelegate( _ inDelegate: Any? )
	{
		netAudioStruct.delegate = inDelegate as AnyObject?
	}

	@objc(delegate)
	func delegate() -> Any?
	{
		return netAudioStruct.delegate
	}

	@objc(setServiceName:)
	func setServiceName( _ name: String? ) -> Bool
	{
		return false
	}

	@objc(serviceName)
	func serviceName() -> String?
	{
		return serviceNameValue
	}

	@objc(setPassword:)
	func setPassword( _ password: String? ) -> Bool
	{
		return false
	}

	@objc(isNetReceive)
	func isNetReceive() -> Bool
	{
		return isReceive
	}
}
