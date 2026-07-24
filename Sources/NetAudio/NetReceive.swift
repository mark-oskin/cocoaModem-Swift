//
//  NetReceive.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/23/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of NetReceive.m.
//
//  This is a Cocoa encapsulation for the AUNetReceive audio unit.
//  It uses Bonjour (via the Swift BonjourService / BonjourSocket) to connect to
//  an AUNetSend (_apple-ausend._tcp) service.
//

import Cocoa
import AudioToolbox
import AudioUnit

//  Set up the host name and port for the AUNetReceive unit.
//  Also set kAUNetSendProperty_Disconnect [sic] to false, per Bill Stewart @ Apple, to autoconnect.
//  If port == 0, use the default AUNetSend host name (local.:52800).
private func setupService( _ unit: AudioUnit, _ ip: UnsafePointer<CChar>, _ port: Int32 ) -> OSStatus
{
	var status: OSStatus

	if port != 0 {
		let name = "\(String(cString: ip)):\(port)"
		var cfName = name as CFString
		status = withUnsafePointer( to: &cfName ) {
			AudioUnitSetProperty( unit, kAUNetReceiveProperty_Hostname, kAudioUnitScope_Global, 0, $0, UInt32( MemoryLayout<CFString>.size ) )
		}
		if status != noErr { return status }
	}
	var autoconnect: UInt32 = 0
	return AudioUnitSetProperty( unit, kAUNetSendProperty_Disconnect, kAudioUnitScope_Global, 0, &autoconnect, UInt32( MemoryLayout<UInt32>.size ) )
}

@objc(NetReceive)
class NetReceive: NetAudio {

	//  ---- ivars (former Obj-C instance variables) ------------------------
	private var netReceiveAudioUnit: AudioUnit?
	private var bonjour: BonjourService?
	private var socket: BonjourSocket?
	//  CallbackInfo in the original was unused beyond declaration; omitted.

	//  a stable empty C string returned by -ip when there is no socket (the
	//  original returned the "" string literal, which lives for the app)
	private static let emptyString: UnsafePointer<CChar> = {
		let p = UnsafeMutablePointer<CChar>.allocate( capacity: 1 )
		p[0] = 0
		return UnsafePointer( p )
	}()

	//  ---- init ------------------------------------------------------------

	@objc(initWithService:delegate:samplesPerBuffer:)
	override init?( service: String?, delegate inDelegate: Any?, samplesPerBuffer size: Int32 )
	{
		super.init()
		if setupWithService( service, delegate: inDelegate, samplesPerBuffer: size, useBonjour: true ) == false { return nil }
	}

	@objc(initWithAddress:port:delegate:samplesPerBuffer:)
	init?( address ip: UnsafePointer<CChar>, port: Int32, delegate inDelegate: Any?, samplesPerBuffer size: Int32 )
	{
		super.init()
		//  note: the original ignores `size` here and uses 512
		if setupWithService( "AUNetSend", delegate: inDelegate, samplesPerBuffer: 512, useBonjour: false ) == false { return nil }
		guard let unit = netReceiveAudioUnit else { return nil }
		if setupService( unit, ip, port ) != noErr { return nil }
		let sel = #selector( NetReceive.netReceive(_:addressChanged:port:) )
		if let d = netAudioStruct.delegate as? NSObject, d.responds( to: sel ) {
			callAddressChanged( d, sel, address: ip, port: port )
		}
	}

	//  ---- private setup ---------------------------------------------------

	//  private API
	@objc(serviceChanged)
	func serviceChanged() -> Bool
	{
		//  drop the previous BonjourService (ARC releases it on reassignment)
		if let unit = netReceiveAudioUnit { _ = setupService( unit, "0.0.0.0", -1 ) }
		//  create new BonjourService
		bonjour = BonjourService()
		guard let bonjour = bonjour else { return false }
		socket = bonjour.registerService( serviceNameValue ?? "" )
		socket?.setDelegate( self )
		return true
	}

	@objc(setServiceName:)
	override func setServiceName( _ name: String? ) -> Bool
	{
		if runTimer != nil {
			//  first, stop any sampling process
			runTimer!.invalidate()
			runTimer = nil
			return false
		}
		serviceNameValue = ( name != nil ) ? name : "AUNetSend"
		return serviceChanged()
	}

	@objc(setPassword:)
	override func setPassword( _ password: String? ) -> Bool
	{
		guard let unit = netReceiveAudioUnit else { return false }
		let name = ( password == nil ) ? "" : password!
		var cfName = name as CFString
		let status = withUnsafePointer( to: &cfName ) {
			AudioUnitSetProperty( unit, kAUNetReceiveProperty_Password, kAudioUnitScope_Global, 0, $0, UInt32( MemoryLayout<CFString>.size ) )
		}
		return status == noErr
	}

	@objc(setAddress:port:)
	func setAddress( _ ip: UnsafePointer<CChar>, port: Int32 ) -> Bool
	{
		guard let unit = netReceiveAudioUnit else { return false }
		if setupService( unit, ip, port ) != noErr { return false }
		let sel = #selector( NetReceive.netReceive(_:addressChanged:port:) )
		if let d = netAudioStruct.delegate as? NSObject, d.responds( to: sel ) {
			callAddressChanged( d, sel, address: ip, port: port )
		}
		return true
	}

	//  This is the timer process where we ask the NetReceive audio unit for data
	@objc(tick:)
	func tick( _ timer: Timer )
	{
		if netAudioStruct.runState != .running {
			timer.invalidate()
			return
		}
		if let unit = netReceiveAudioUnit, tickLock.try() {
			var actionFlags: AudioUnitRenderActionFlags = []
			_ = AudioUnitRender( unit, &actionFlags, &timeStamp, 0, samplesPerBuffer, bufferList.unsafeMutablePointer )
			timeStamp.mSampleTime += Double( samplesPerBuffer )
			//  send data to delegate
			let sel = #selector( NetReceive.netReceive(_:newSamples:left:right:) )
			if let d = netAudioStruct.delegate as? NSObject, d.responds( to: sel ),
			   let left = dataBuffer[0], let right = dataBuffer[1] {
				typealias Fn = @convention(c) ( AnyObject, Selector, NetReceive, Int32, UnsafePointer<Float>, UnsafePointer<Float> ) -> Void
				let fn = unsafeBitCast( d.method( for: sel ), to: Fn.self )
				fn( d, sel, self, Int32( samplesPerBuffer ), UnsafePointer( left ), UnsafePointer( right ) )
			}
			tickLock.unlock()
		}
	}

	@objc(runThread)
	override func runThread() -> Bool
	{
		_ = Thread.setThreadPriority( 1.0 )
		//  start sampling if there is a delegate and an AUNetReceive has been successfully set up, and if we are not already sampling
		if netAudioStruct.delegate == nil || netReceiveAudioUnit == nil || runTimer != nil { return false }
		runTimer = Timer.scheduledTimer( timeInterval: Double( samplesPerBuffer )/Double( samplingRate ), target: self, selector: #selector(tick(_:)), userInfo: self, repeats: true )
		netAudioStruct.runState = .running
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
		//  the tick: timer routine will catch this flag and stop the timer.
		netAudioStruct.runState = .idle
	}

	//  Set up an AUNetReceive component and returns true if it is set up successfully.
	//  This is a private API.
	@objc(setupNetReceiveUnit:)
	func setupNetReceiveUnit( _ useBonjour: Bool ) -> Bool
	{
		//  Carbon Component Manager -> modern AudioComponent APIs
		var desc = AudioComponentDescription()
		desc.componentType = kAudioUnitType_Generator
		desc.componentSubType = kAudioUnitSubType_NetReceive
		desc.componentManufacturer = kAudioUnitManufacturer_Apple
		desc.componentFlags = 0
		desc.componentFlagsMask = 0
		guard let component = AudioComponentFindNext( nil, &desc ) else { return false }
		netReceiveAudioUnit = nil
		var unit: AudioUnit? = nil
		let status = AudioComponentInstanceNew( component, &unit )
		if status != 0 || unit == nil { return false }
		netReceiveAudioUnit = unit

		if AudioUnitInitialize( unit! ) != noErr { return false }

		Thread.sleep( until: Date( timeIntervalSinceNow: 0.05 ) )		//  sleep for system to finish setting up before checking Bonjour
		if useBonjour { _ = serviceChanged() }

		return true
	}

	//  private API for -init and -initWithService
	@objc(setupWithService:delegate:samplesPerBuffer:useBonjour:)
	func setupWithService( _ service: String?, delegate inDelegate: Any?, samplesPerBuffer size: Int32, useBonjour: Bool ) -> Bool
	{
		isReceive = true
		bonjour = nil
		socket = nil
		netReceiveAudioUnit = nil
		netAudioStruct.delegate = inDelegate as AnyObject?

		for i in 0..<Int( channels ) { dataBuffer[i] = nil }
		setBufferSize( size )
		serviceNameValue = ( service != nil ) ? service : "AUNetSend"
		//  initialize time stamp
		timeStamp.mFlags = .sampleTimeValid
		timeStamp.mSampleTime = 0
		if setupNetReceiveUnit( useBonjour ) == false {
			freeBuffers()
			return false
		}
		return true
	}

	//  ---- BonjourSocket delegate -----------------------------------------

	//  Found the Bonjour port that corresponds to the AUNetReceive component.
	//  Fetch the IP and port number and set the AUNetReceive hostname.
	@objc(bonjourNetReceiveConnect:)
	func bonjourNetReceiveConnect( _ inSocket: BonjourSocket )
	{
		if let unit = netReceiveAudioUnit { _ = setupService( unit, inSocket.ip(), inSocket.port() ) }
		let sel = #selector( NetReceive.netReceive(_:addressChanged:port:) )
		if let d = netAudioStruct.delegate as? NSObject, d.responds( to: sel ) {
			//  (faithful to the original: ip comes from inSocket, port from the ivar `socket`)
			callAddressChanged( d, sel, address: inSocket.ip(), port: socket?.port() ?? 0 )
		}
	}

	//  Bonjour port disconnected.
	@objc(bonjourNetReceiveDisconnect:)
	func bonjourNetReceiveDisconnect( _ inSocket: BonjourSocket )
	{
		stopSampling()
		let sel = #selector( NetReceive.netReceive(_:disconnectedFromAddress:port:) )
		if let d = netAudioStruct.delegate as? NSObject, d.responds( to: sel ) {
			callAddressChanged( d, sel, address: inSocket.ip(), port: socket?.port() ?? 0 )
		}
	}

	//  helper: invoke a delegate selector of the form (NetReceive, const char*, int)
	//  exactly like the original -respondsToSelector: guarded call, but with the C
	//  pointer/int arguments that -performSelector: cannot carry.
	private func callAddressChanged( _ d: NSObject, _ sel: Selector, address: UnsafePointer<CChar>, port: Int32 )
	{
		typealias Fn = @convention(c) ( AnyObject, Selector, NetReceive, UnsafePointer<CChar>, Int32 ) -> Void
		let fn = unsafeBitCast( d.method( for: sel ), to: Fn.self )
		fn( d, sel, self, address, port )
	}

	@objc(ip)
	func ip() -> UnsafePointer<CChar>!
	{
		if let socket = socket { return UnsafePointer( socket.ip() ) }
		return NetReceive.emptyString
	}

	@objc(port)
	func port() -> Int32
	{
		if let socket = socket { return socket.port() }
		return 0
	}

	//  ---- delegate method stubs (empty, overridable) ---------------------

	@objc(netReceive:newSamples:left:right:)
	func netReceive( _ aNetReceive: NetReceive, newSamples samplesPerBuffer: Int32, left leftBuffer: UnsafePointer<Float>, right rightBuffer: UnsafePointer<Float> )
	{
	}

	@objc(netReceive:addressChanged:port:)
	func netReceive( _ aNetReceive: NetReceive, addressChanged address: UnsafePointer<CChar>, port: Int32 )
	{
	}

	@objc(netReceive:disconnectedFromAddress:port:)
	func netReceive( _ aNetReceive: NetReceive, disconnectedFromAddress address: UnsafePointer<CChar>, port: Int32 )
	{
	}
}
