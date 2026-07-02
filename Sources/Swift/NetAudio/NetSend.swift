//
//  NetSend.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/25/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of NetSend.m.
//
//  The way the standalone AUNetSend works is this:
//	An NSTimer process is used to call the output renderer of the AUNetSend component.
//	This in turn pulls the data from the input renderer, which is trapped by the input render
//	callback.  The input render callback calls the client's needNetSendSamples method to fill
//	the buffers.
//

import Cocoa
import AudioToolbox
import AudioUnit

//  Callback from Core Audio to get input audio waveform data for the AUNetSend component.
//
//  A top-level function captures no context, so it can be used directly as the C
//  AURenderCallback (inputProc).  The refcon is an Unmanaged.passUnretained pointer
//  to the NetAudioStruct owned by the NetSend instance.
private func netsendRenderer( _ ref: UnsafeMutableRawPointer,
							  _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
							  _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
							  _ inBusNumber: UInt32,
							  _ frames: UInt32,
							  _ ioData: UnsafeMutablePointer<AudioBufferList>? ) -> OSStatus
{
	let ns = Unmanaged<NetAudioStruct>.fromOpaque( ref ).takeUnretainedValue()
	let ourself: AnyObject? = ns.netSendObj

	guard let ioData = ioData else { return noErr }
	let abl = UnsafeMutableAudioBufferListPointer( ioData )
	guard let lraw = abl[0].mData, let rraw = abl[1].mData else { return noErr }
	let lbuf = lraw.assumingMemoryBound( to: Float.self )
	let rbuf = rraw.assumingMemoryBound( to: Float.self )
	let nframes = Int( frames )

	let sel = #selector( NetSend.netSend(_:needSamples:left:right:) )
	if let d = ns.delegate as? NSObject, d.responds( to: sel ) {
		//  call the delegate with the (float*) buffers -performSelector: cannot carry
		typealias Fn = @convention(c) ( AnyObject, Selector, AnyObject?, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float> ) -> Void
		let fn = unsafeBitCast( d.method( for: sel ), to: Fn.self )
		fn( d, sel, ourself, Int32( frames ), lbuf, rbuf )

		switch ns.runState {
		case .running:
			return noErr
		case .started:
			//  taper data on using raised cosine of 11ms long
			ns.runState = .running
			let n = nframes > 512 ? nframes : 512
			for i in 0..<n {
				let scale: Float = i < 512 ? ns.raisedCosine[i] : 0
				lbuf[i] *= scale
				rbuf[i] *= scale
			}
			return noErr
		case .stopped:
			//  taper data off using raised cosine of 11ms long
			ns.runState = .idle
			let n = nframes > 512 ? nframes : 512
			var i = 0
			while i < n {
				let scale: Float = i < 512 ? ( 1.0 - ns.raisedCosine[i] ) : 0
				lbuf[i] *= scale
				rbuf[i] *= scale
				i += 1
			}
			while i < nframes { lbuf[i] = 0.0; rbuf[i] = 0.0; i += 1 }
			return noErr
		case .idle:
			for i in 0..<nframes { lbuf[i] = 0.0; rbuf[i] = 0.0 }
			return noErr
		}
	}
	//  no delegate
	switch ns.runState {
	case .running, .started:
		ns.runState = .running
	case .stopped, .idle:
		ns.runState = .idle
	}
	for i in 0..<nframes { lbuf[i] = 0.0; rbuf[i] = 0.0 }
	return noErr
}

@objc(NetSend)
class NetSend: NetAudio {

	//  ---- ivars (former Obj-C instance variables) ------------------------
	private var netSendAudioUnit: AudioUnit?
	private var password: String?
	private var port: UInt32 = 52800

	//  ---- init ------------------------------------------------------------

	@objc(initWithService:delegate:samplesPerBuffer:)
	override init?( service: String?, delegate inDelegate: Any?, samplesPerBuffer size: Int32 )
	{
		super.init()
		//  NOTE: the original wrote `netAudioStruct.runState == kNetAudioIdle ;` — a
		//  comparison, not an assignment, so it was a runtime no-op.  Mirrored as such.
		_ = ( netAudioStruct.runState == .idle )
		if setupWithService( service, delegate: inDelegate, samplesPerBuffer: size ) == false { return nil }
	}

	//  ---- stream / property helpers --------------------------------------

	//  set up stream information, an AudioStreamBasicDescription
	@objc(setupStreamFormat:)
	func setupStreamFormat( _ unit: AudioUnit ) -> Bool
	{
		var streamDescription = AudioStreamBasicDescription()			//  zeroed (was memset 0)
		var propertySize = UInt32( MemoryLayout<AudioStreamBasicDescription>.size )
		var status = AudioUnitGetProperty( unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDescription, &propertySize )
		if status != 0 { return false }
		//  set to our parameters
		streamDescription.mBitsPerChannel = 32
		streamDescription.mFramesPerPacket = 1
		streamDescription.mBytesPerPacket = 4
		streamDescription.mBytesPerFrame = 4
		streamDescription.mSampleRate = Float64( samplingRate )
		streamDescription.mChannelsPerFrame = channels
		status = AudioUnitSetProperty( unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDescription, propertySize )
		return status == noErr
	}

	//  private API
	@objc(setCurrentServiceName)
	func setCurrentServiceName() -> Bool
	{
		guard let unit = netSendAudioUnit else { return false }
		var cfName = ( serviceNameValue ?? "" ) as CFString
		let status = withUnsafePointer( to: &cfName ) {
			AudioUnitSetProperty( unit, kAUNetSendProperty_ServiceName, kAudioUnitScope_Global, 0, $0, UInt32( MemoryLayout<CFString>.size ) )
		}
		return status == noErr
	}

	//  private API
	//  note: cannot clear password
	@objc(setCurrentPassword)
	func setCurrentPassword() -> Bool
	{
		guard let unit = netSendAudioUnit else { return false }
		let name = ( password == nil ) ? "" : password!
		var cfName = name as CFString
		let status = withUnsafePointer( to: &cfName ) {
			AudioUnitSetProperty( unit, kAUNetSendProperty_Password, kAudioUnitScope_Global, 0, $0, UInt32( MemoryLayout<CFString>.size ) )
		}
		return status == noErr
	}

	//  private API
	@objc(setCurrentPortNumber)
	func setCurrentPortNumber() -> Bool
	{
		guard let unit = netSendAudioUnit else { return false }
		var p = port
		let status = AudioUnitSetProperty( unit, kAUNetSendProperty_PortNum, kAudioUnitScope_Global, 0, &p, UInt32( MemoryLayout<UInt32>.size ) )
		return status == noErr
	}

	//  set the Bonjour service name for the AUNetSend component
	@objc(setServiceName:)
	override func setServiceName( _ name: String? ) -> Bool
	{
		guard let name = name, name.count >= 1 else { return false }

		if let sv = serviceNameValue, name == sv { return true }

		serviceNameValue = name
		return setCurrentServiceName()
	}

	//  set password for AUNetSend component
	@objc(setPassword:)
	override func setPassword( _ name: String? ) -> Bool
	{
		if password == nil && name == nil { return true }
		if let p = password, let n = name, n == p { return true }

		password = ( name == nil ) ? nil : name
		return setCurrentPassword()
	}

	//  set the port number for the AUNetSend component
	@objc(setPortNumber:)
	func setPortNumber( _ number: Int32 ) -> Bool
	{
		if number == Int32( bitPattern: port ) { return true }

		port = UInt32( bitPattern: number )
		return setCurrentPortNumber()
	}

	//  set up the format (linear 32 bit PCM) and Bonjour service name for the AUNetSend unit
	@objc(setupAUNetSendService)
	func setupAUNetSendService() -> Bool
	{
		guard let unit = netSendAudioUnit else { return false }
		var format = UInt32( kAUNetSendPresetFormat_PCMFloat32 )
		let status = AudioUnitSetProperty( unit, kAUNetSendProperty_TransmissionFormatIndex, kAudioUnitScope_Global, 0, &format, UInt32( MemoryLayout<UInt32>.size ) )
		if status != noErr { return false }			//  (original returned the OSStatus here; result is discarded)

		_ = setCurrentPortNumber()
		_ = setCurrentServiceName()
		_ = setCurrentPassword()

		return setupStreamFormat( unit )
	}

	@objc(setupCallback)
	func setupCallback() -> Bool
	{
		guard let unit = netSendAudioUnit else { return false }
		var callback = AURenderCallbackStruct()
		//  setup input callback, passing the NetAudioStruct as the refcon
		callback.inputProc = netsendRenderer
		callback.inputProcRefCon = Unmanaged.passUnretained( netAudioStruct ).toOpaque()

		let status = AudioUnitSetProperty( unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32( MemoryLayout<AURenderCallbackStruct>.size ) )
		return status == noErr
	}

	//  Set up an AUNetSend component and returns true if it is set up successfully.
	//  This is a private API.
	@objc(setupNetSendUnit)
	func setupNetSendUnit() -> Bool
	{
		//  Carbon Component Manager -> modern AudioComponent APIs
		var desc = AudioComponentDescription()
		desc.componentType = kAudioUnitType_Effect
		desc.componentSubType = kAudioUnitSubType_NetSend
		desc.componentManufacturer = kAudioUnitManufacturer_Apple
		desc.componentFlags = 0
		desc.componentFlagsMask = 0
		guard let component = AudioComponentFindNext( nil, &desc ) else { return false }
		netSendAudioUnit = nil
		var unit: AudioUnit? = nil
		let status = AudioComponentInstanceNew( component, &unit )
		if status != 0 || unit == nil { return false }
		netSendAudioUnit = unit

		if AudioUnitInitialize( unit! ) != noErr { return false }

		_ = setupAUNetSendService()
		_ = setupCallback()

		return true
	}

	@objc(setupWithService:delegate:samplesPerBuffer:)
	func setupWithService( _ service: String?, delegate inDelegate: Any?, samplesPerBuffer size: Int32 ) -> Bool
	{
		isReceive = false
		netAudioStruct.netSendObj = self
		netAudioStruct.delegate = inDelegate as AnyObject?

		for i in 0..<Int( channels ) { dataBuffer[i] = nil }
		setBufferSize( size )

		serviceNameValue = service
		password = nil
		port = 52800

		//  initialize time stamp
		timeStamp.mFlags = .sampleTimeValid
		timeStamp.mSampleTime = 0
		if setupNetSendUnit() == false {
			freeBuffers()
			return false
		}
		return true
	}

	//  ---- run loop --------------------------------------------------------

	@objc(tick:)
	func tick( _ timer: Timer )
	{
		if netAudioStruct.runState == .stopped || netAudioStruct.runState == .idle {
			timer.invalidate()
			if netAudioStruct.runState == .idle { return }
		}
		if let unit = netSendAudioUnit, tickLock.try() {
			//  one extra call with kNetAudioStopped
			var actionFlags: AudioUnitRenderActionFlags = []
			_ = AudioUnitRender( unit, &actionFlags, &timeStamp, 0, samplesPerBuffer, bufferList.unsafeMutablePointer )
			timeStamp.mSampleTime += Double( samplesPerBuffer )
			tickLock.unlock()
		}
	}

	@objc(runThread)
	override func runThread() -> Bool
	{
		_ = Thread.setThreadPriority( 1.0 )
		//  start sampling if there is a delegate and an AUNetSend has been successfully set up, and if we are not already sampling
		if netAudioStruct.delegate == nil || netSendAudioUnit == nil || runTimer != nil { return false }
		runTimer = Timer.scheduledTimer( timeInterval: Double( samplesPerBuffer )/Double( samplingRate ), target: self, selector: #selector(tick(_:)), userInfo: self, repeats: true )
		netAudioStruct.runState = .started
		let runLoop = RunLoop.current
		//  thread will stay running in the run loop until the timer is stopped in the tick routine
		while netAudioStruct.runState != .idle && runLoop.run( mode: .default, before: Date.distantFuture ) {}
		runTimer = nil
		_ = Thread.setThreadPriority( 0.25 )
		return false
	}

	@objc(startSampling)
	func startSampling() -> Bool
	{
		timerThreadLock.unlock( withCondition: kCommandAvailable )
		return true
	}

	@objc(stopSampling)
	func stopSampling()
	{
		//  NOTE: the original wrote `netAudioStruct.runState == kNetAudioStopped ;` — a
		//  comparison, not an assignment, so -stopSampling was a runtime no-op.
		//  Mirrored as a no-op to preserve behaviour byte-for-byte.
		_ = ( netAudioStruct.runState == .stopped )
	}

	//  ---- delegate / accessors -------------------------------------------

	@objc(setDelegate:)
	override func setDelegate( _ delegate: Any? )
	{
		netAudioStruct.delegate = delegate as AnyObject?
		_ = setupCallback()
	}

	@objc(delegate)
	override func delegate() -> Any?
	{
		return netAudioStruct.delegate
	}

	//  ---- delegate method stub (empty, overridable) ----------------------

	@objc(netSend:needSamples:left:right:)
	func netSend( _ aNetSend: NetSend, needSamples samplesPerBuffer: Int32, left leftBuffer: UnsafeMutablePointer<Float>, right rightBuffer: UnsafeMutablePointer<Float> )
	{
	}
}
