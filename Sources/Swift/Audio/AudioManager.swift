//
//  AudioManager.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/5/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of AudioManager.m.
//
//  The RegisteredAudioDevice record and the cm_* CoreAudio shims live in
//  AudioManagerTypes.h (see that file for why: Swift can neither import a C
//  struct holding Objective-C object pointers nor call the pre-10.6 CoreAudio
//  API directly).  The device records are still malloc'd C structs, freed
//  explicitly in deinit (ARC does not manage them), exactly as the original did.
//

import Foundation
import CoreAudio

//  AudioDeviceStart and AudioDeviceStop does not allow the same AudioDeviceIOProc to be used more than once per AudioDeviceID.
//	Different modeminterfaces that uses the same device can therefore not subclass off the same base class that uses the same AudioDeviceIOProc.
//	AudioManager handles all AudioDeviceIOProc callbacks and issue AudioDeviceStart/AudioDeviceStop and demux the data from the different modems.
//	AudioManager also handles system device changes and forward the information to the clients of a device.

//  'vmvc' == kAudioHardwareServiceDeviceProperty_VirtualMasterVolume (AudioToolbox/AudioServices.h)
private let kVirtualMasterVolume: AudioDevicePropertyID = 0x766D7663		//  'vmvc'

//  --- field offsets used to reach the fixed C arrays inside the malloc'd record
//  without tripping Swift's exclusivity checker (the arrays import as tuples) ---
private let offActiveInputArray  = MemoryLayout<RegisteredAudioDevice>.offset(of: \.activeInputModemAudio)!
private let offActiveOutputArray = MemoryLayout<RegisteredAudioDevice>.offset(of: \.activeOutputModemAudio)!
private let offInputArray        = MemoryLayout<RegisteredAudioDevice>.offset(of: \.inputModemAudio)!
private let offOutputArray       = MemoryLayout<RegisteredAudioDevice>.offset(of: \.outputModemAudio)!
private let offActiveInputCount  = MemoryLayout<RegisteredAudioDevice>.offset(of: \.activeInputClients)!
private let offActiveOutputCount = MemoryLayout<RegisteredAudioDevice>.offset(of: \.activeOutputClients)!
private let offInputCount        = MemoryLayout<RegisteredAudioDevice>.offset(of: \.inputClients)!
private let offOutputCount       = MemoryLayout<RegisteredAudioDevice>.offset(of: \.outputClients)!
private let offInputStreamArray  = MemoryLayout<RegisteredAudioDevice>.offset(of: \.inputStream)!
private let offOutputStreamArray = MemoryLayout<RegisteredAudioDevice>.offset(of: \.outputStream)!

private func rawArray(_ dev: UnsafeMutablePointer<RegisteredAudioDevice>, _ offset: Int) -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
	return (UnsafeMutableRawPointer(dev) + offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
}
private func countPtr(_ dev: UnsafeMutablePointer<RegisteredAudioDevice>, _ offset: Int) -> UnsafeMutablePointer<Int32> {
	return (UnsafeMutableRawPointer(dev) + offset).assumingMemoryBound(to: Int32.self)
}
private func streamArray(_ dev: UnsafeMutablePointer<RegisteredAudioDevice>, _ offset: Int) -> UnsafeMutablePointer<DeviceStream> {
	return (UnsafeMutableRawPointer(dev) + offset).assumingMemoryBound(to: DeviceStream.self)
}

//	A Core Audio input request comes to this (deviceInputProc) callback.
//	This then calls the modemSource(s) that are linked to the deviceID
private func deviceInputProc( _ devID: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>, _ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>, _ unused: UnsafeMutablePointer<AudioBufferList>, _ inOutputTime: UnsafePointer<AudioTimeStamp>, _ user: UnsafeMutableRawPointer? ) -> OSStatus
{
	autoreleasepool {
		guard let user = user else { return }
		let manager = Unmanaged<AudioManager>.fromOpaque( user ).takeUnretainedValue()
		guard let audioDevice = manager.audioDevice( forID: devID ) else { return }

		//  lock and copy current ModemSources registered to receive data from the DeviceID
		let lock = Unmanaged<NSLock>.fromOpaque( audioDevice.pointee.lock ).takeUnretainedValue()
		lock.lock()
		let activeClients = Int( audioDevice.pointee.activeInputClients )
		let clientList = rawArray( audioDevice, offActiveInputArray )
		var activeModemAudio = [ModemAudio]()
		activeModemAudio.reserveCapacity( activeClients )
		for i in 0..<activeClients {
			activeModemAudio.append( Unmanaged<ModemAudio>.fromOpaque( clientList[i]! ).takeUnretainedValue() )
		}
		lock.unlock()

		//  now submit data to the list of ModemSources (ModemAudio)
		for client in activeModemAudio {
			client.inputArrived( from: devID, bufferList: input )
		}
	}
	return 0
}

//	A Core Audio output request comes to this (deviceOutputProc) callback.
private func deviceOutputProc( _ devID: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>, _ unused: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>, _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>, _ user: UnsafeMutableRawPointer? ) -> OSStatus
{
	autoreleasepool {
		guard let user = user else { return }
		let manager = Unmanaged<AudioManager>.fromOpaque( user ).takeUnretainedValue()
		guard let audioDevice = manager.audioDevice( forID: devID ) else { return }

		//  lock and copy current ModemSources registered to receive data from the DeviceID
		let lock = Unmanaged<NSLock>.fromOpaque( audioDevice.pointee.lock ).takeUnretainedValue()
		lock.lock()
		let activeClients = Int( audioDevice.pointee.activeOutputClients )
		let clientList = rawArray( audioDevice, offActiveOutputArray )
		var activeModemAudio = [ModemAudio]()
		activeModemAudio.reserveCapacity( activeClients )
		for i in 0..<activeClients {
			activeModemAudio.append( Unmanaged<ModemAudio>.fromOpaque( clientList[i]! ).takeUnretainedValue() )
		}
		lock.unlock()

		//  now fetch (accumulate) data from the list of ModemSources (ModemAudio)
		for (i, client) in activeModemAudio.enumerated() {
			client.accumulateOutput( for: devID, bufferList: output, accumulate: ( i != 0 ) )
		}
	}
	return 0
}

//  AudioDeviceListenerProc for all registered devices end up here
private func deviceListenerProc( _ inDeviceID: AudioDeviceID, _ channel: UInt32, _ isInput: DarwinBoolean, _ property: AudioDevicePropertyID, _ selfp: UnsafeMutableRawPointer? ) -> OSStatus
{
	if property == 0 { return 0 }
	guard let selfp = selfp else { return 0 }
	let manager = Unmanaged<AudioManager>.fromOpaque( selfp ).takeUnretainedValue()
	let input = isInput.boolValue

	//  NOTE: when device sampling rate changes, the following can return (in this order)
	//	kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat,
	//	kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyLatency,
	//	kAudioDevicePropertySafetyOffset, kAudioDevicePropertyDeviceIsRunningSomewhere.
	//  (See AudioManager.m for the full annotated list of properties observed for
	//   volume / source / bits/channels / mute / sampling-start-stop transitions.)

	switch property {
	case kAudioDevicePropertyMute:
		manager.muted( inDeviceID, isInput: input )
		return 0
	case kAudioDevicePropertyDataSource:
		manager.sourceChanged( inDeviceID, isInput: input )
		return 0
	case kAudioDevicePropertyNominalSampleRate:
		manager.samplingRateChanged( inDeviceID, isInput: input )
		return 0
	case kAudioDevicePropertyVolumeDecibels, kVirtualMasterVolume:
		manager.audioLevelChanged( inDeviceID, isInput: input )
		return 0
	default:
		break
	}
	return 0
}

@objc(AudioManager)
class AudioManager: NSObject {

	private var registeredAudioDevices = 0
	private var registeredAudioDevice = [UnsafeMutablePointer<RegisteredAudioDevice>?]( repeating: nil, count: 256 )
	private var cachedDevice = [UnsafeMutablePointer<RegisteredAudioDevice>?]( repeating: nil, count: 2048 )

	override init()
	{
		super.init()
		registeredAudioDevices = 0
		//  cachedDevice already initialised to nil (matches the -init loop)
	}

	deinit
	{
		for i in 0..<registeredAudioDevices {
			guard let cachedAudioDevice = registeredAudioDevice[i] else { continue }
			if cachedAudioDevice.pointee.activeInputClients > 0 { _ = cm_AudioDeviceStop( cachedAudioDevice.pointee.deviceID, deviceInputProc ) }
			if cachedAudioDevice.pointee.activeOutputClients > 0 { _ = cm_AudioDeviceStop( cachedAudioDevice.pointee.deviceID, deviceOutputProc ) }
			_ = cm_AudioDeviceRemoveIOProc( cachedAudioDevice.pointee.deviceID, deviceInputProc )
			_ = cm_AudioDeviceRemoveIOProc( cachedAudioDevice.pointee.deviceID, deviceOutputProc )
			if cachedAudioDevice.pointee.propertyListenerProc != nil { removePropertyListener( for: cachedAudioDevice ) }
			if let lock = cachedAudioDevice.pointee.lock { Unmanaged<NSLock>.fromOpaque( lock ).release() }
			free( cachedAudioDevice )
		}
	}

	//	Return RegisteredAudioDevice of AudioDeviceID, or nil, if device not registered.
	@objc(audioDeviceForID:)
	func audioDevice( forID devID: AudioDeviceID ) -> UnsafeMutablePointer<RegisteredAudioDevice>?
	{
		if devID < 2048, let cached = cachedDevice[Int(devID)], cached.pointee.deviceID == devID { return cached }

		// out of cache range, check each registered deviceID
		for i in 0..<registeredAudioDevices {
			if let dev = registeredAudioDevice[i], dev.pointee.deviceID == devID { return dev }
		}
		return nil
	}

	//	(Private API)
	private func removePropertyListener( for audioDevice: UnsafeMutablePointer<RegisteredAudioDevice>? )
	{
		guard let audioDevice = audioDevice else { return }

		_ = cm_AudioDeviceRemoveWildcardListener( audioDevice.pointee.deviceID, deviceListenerProc )
		audioDevice.pointee.propertyListenerProc = nil
	}

	//	(Private API)
	private func addPropertyListener( for audioDevice: UnsafeMutablePointer<RegisteredAudioDevice>? )
	{
		guard let audioDevice = audioDevice else { return }

		if audioDevice.pointee.propertyListenerProc != nil { removePropertyListener( for: audioDevice ) }

		_ = cm_AudioDeviceAddWildcardListener( audioDevice.pointee.deviceID, deviceListenerProc, Unmanaged.passUnretained( self ).toOpaque() )
		audioDevice.pointee.propertyListenerProc = unsafeBitCast( deviceListenerProc as AudioDevicePropertyListenerProc, to: UnsafeMutableRawPointer.self )
	}

	//	(Private API)
	private func addClient( _ client: ModemAudio, toDevice dev: UnsafeMutablePointer<RegisteredAudioDevice>, list: UnsafeMutablePointer<UnsafeMutableRawPointer?>, listSize count: UnsafeMutablePointer<Int32> )
	{
		let inCount = Int( count.pointee )
		if inCount >= 256 {
			NSLog( "AudioManager -addClient: too many clients?" )
			return
		}

		//  check if client is already in the list
		let clientPtr = Unmanaged.passUnretained( client ).toOpaque()
		for i in 0..<inCount {
			if list[i] == clientPtr {
				NSLog( "AudioManager -addClient: client already active?" )
				return
			}
		}
		let lock = Unmanaged<NSLock>.fromOpaque( dev.pointee.lock ).takeUnretainedValue()
		lock.lock()
		list[inCount] = clientPtr
		count.pointee = Int32( inCount + 1 )
		lock.unlock()
	}

	//	(Private API)
	private func removeClient( _ client: ModemAudio, fromDevice dev: UnsafeMutablePointer<RegisteredAudioDevice>, list: UnsafeMutablePointer<UnsafeMutableRawPointer?>, listSize count: UnsafeMutablePointer<Int32> )
	{
		var inCount = Int( count.pointee )
		let clientPtr = Unmanaged.passUnretained( client ).toOpaque()
		//  look for the client in the active list
		for i in 0..<inCount {
			if list[i] == clientPtr {
				//  found the entry to remove
				let lock = Unmanaged<NSLock>.fromOpaque( dev.pointee.lock ).takeUnretainedValue()
				lock.lock()
				inCount -= 1
				count.pointee = ( inCount < 0 ) ? 0 : Int32( inCount )
				for j in i..<inCount { list[j] = list[j+1] }
				lock.unlock()
				return
			}
		}
		NSLog( "AudioManager -removeInputClient: client not found in active list?" )
	}

	private func getDeviceInfo( _ devID: AudioDeviceID, streams: UnsafeMutablePointer<DeviceStream>, isInput: Bool ) -> Int32
	{
		var n: Int32 = 0
		var datasize: UInt32 = 0

		var status = cm_AudioDeviceGetPropertyInfo( devID, 0, isInput, kAudioDevicePropertyStreamConfiguration, &datasize )
		if status == 0 && datasize == UInt32( MemoryLayout<AudioBufferList>.size ) {
			var audioBufferList = AudioBufferList()
			status = cm_AudioDeviceGetProperty( devID, 0, isInput, kAudioDevicePropertyStreamConfiguration, &datasize, &audioBufferList )
			if status == 0 {
				//  limit to MAXSTREAMS
				n = Int32( audioBufferList.mNumberBuffers )
				if n > 16 { n = Int32( MAXSTREAMS ) }
				for i in 0..<Int(n) {
					let stream = streams + i
					var m = withUnsafePointer( to: &audioBufferList.mBuffers ) {
						$0.withMemoryRebound( to: AudioBuffer.self, capacity: Int(n) ) { Int( $0[i].mNumberChannels ) }
					}
					if m > Int(MAXCHANNELS) { m = Int(MAXCHANNELS) }
					stream.pointee.channels = Int32( m )
					//  first check if there is a master control
					datasize = UInt32( MemoryLayout<AudioValueRange>.size )
					withUnsafeMutablePointer( to: &stream.pointee.channelInfo ) {
						$0.withMemoryRebound( to: DeviceChannel.self, capacity: Int(MAXCHANNELS) ) { channelInfo in
							status = cm_AudioDeviceGetProperty( devID, 0, isInput, kAudioDevicePropertyVolumeRangeDecibels, &datasize, &channelInfo[0].dbRange )
							stream.pointee.hasMasterControl = DarwinBoolean( status == 0 )

							if stream.pointee.hasMasterControl.boolValue == false {
								for j in 0..<m {
									datasize = UInt32( MemoryLayout<AudioValueRange>.size )
									status = cm_AudioDeviceGetProperty( devID, UInt32( j+1 ), isInput, kAudioDevicePropertyVolumeRangeDecibels, &datasize, &channelInfo[j].dbRange )
									if status != 0 {
										channelInfo[j].dbRange.mMinimum = 0.0
										channelInfo[j].dbRange.mMaximum = 0.0
									}
								}
							}
						}
					}
				}
			}
		}
		return n
	}

	private func registeredAudioDevice( forID devID: AudioDeviceID ) -> UnsafeMutablePointer<RegisteredAudioDevice>
	{
		if let audioDevice = audioDevice( forID: devID ) { return audioDevice }

		//  device not yet registered, create a RegisteredAudioDevice struct
		let audioDevice = UnsafeMutablePointer<RegisteredAudioDevice>( OpaquePointer( malloc( MemoryLayout<RegisteredAudioDevice>.stride )! ) )
		audioDevice.pointee.deviceID = devID
		audioDevice.pointee.inputClients = 0
		audioDevice.pointee.outputClients = 0
		audioDevice.pointee.activeInputClients = 0
		audioDevice.pointee.activeOutputClients = 0
		audioDevice.pointee.lock = Unmanaged.passRetained( NSLock() ).toOpaque()
		audioDevice.pointee.propertyListenerProc = nil
		addPropertyListener( for: audioDevice )

		audioDevice.pointee.inputStreams = getDeviceInfo( devID, streams: streamArray( audioDevice, offInputStreamArray ), isInput: true )

		audioDevice.pointee.outputStreams = getDeviceInfo( devID, streams: streamArray( audioDevice, offOutputStreamArray ), isInput: false )

		registeredAudioDevice[registeredAudioDevices] = audioDevice
		registeredAudioDevices += 1
		if devID < 2048 { cachedDevice[Int(devID)] = audioDevice }
		//  now add CoreAudio procs for this device
		_ = cm_AudioDeviceAddIOProc( devID, deviceInputProc, Unmanaged.passUnretained( self ).toOpaque() )
		_ = cm_AudioDeviceAddIOProc( devID, deviceOutputProc, Unmanaged.passUnretained( self ).toOpaque() )

		return audioDevice
	}

	@objc(sliderValueForDeviceID:isInput:channel:)
	func sliderValue( forDeviceID devID: AudioDeviceID, isInput: Bool, channel: Int32 ) -> Float
	{
		guard let audioDevice = audioDevice( forID: devID ) else { return Float( NODBVALUE ) }

		//  device had been in use, fetch the kAudioDevicePropertyVolumeDecibels

		let streams: Int32
		let stream: UnsafeMutablePointer<DeviceStream>
		if isInput == true {
			streams = audioDevice.pointee.inputStreams
			stream = streamArray( audioDevice, offInputStreamArray )
		}
		else {
			streams = audioDevice.pointee.outputStreams
			stream = streamArray( audioDevice, offOutputStreamArray )
		}
		if streams <= 0 { return Float( NODBVALUE ) }

		//  use stream[0] for now
		var db: Float32 = 0
		var datasize = UInt32( MemoryLayout<Float32>.size )
		let status: OSStatus
		if stream.pointee.hasMasterControl.boolValue {
			status = cm_AudioDeviceGetProperty( devID, 0, isInput, kAudioDevicePropertyVolumeDecibels, &datasize, &db )
		}
		else {
			status = cm_AudioDeviceGetProperty( devID, UInt32( channel+1 ), isInput, kAudioDevicePropertyVolumeDecibels, &datasize, &db )
		}
		if status != noErr { return Float( NODBVALUE ) }
		return db
	}

	@objc(audioDeviceRegister:modemAudio:)
	func audioDeviceRegister( _ devID: AudioDeviceID, modemAudio client: ModemAudio )
	{
		let isInputClient = client.isInput()
		let dev = registeredAudioDevice( forID: devID )

		if isInputClient == true {
			addClient( client, toDevice: dev, list: rawArray( dev, offInputArray ), listSize: countPtr( dev, offInputCount ) )
		}
		else {
			addClient( client, toDevice: dev, list: rawArray( dev, offOutputArray ), listSize: countPtr( dev, offOutputCount ) )
		}
	}

	@objc(audioDeviceUnregister:modemAudio:)
	func audioDeviceUnregister( _ devID: AudioDeviceID, modemAudio client: ModemAudio )
	{
		let isInputClient = client.isInput()
		let dev = registeredAudioDevice( forID: devID )

		if isInputClient {
			removeClient( client, fromDevice: dev, list: rawArray( dev, offInputArray ), listSize: countPtr( dev, offInputCount ) )
		}
		else {
			removeClient( client, fromDevice: dev, list: rawArray( dev, offOutputArray ), listSize: countPtr( dev, offOutputCount ) )
		}
	}

	@objc(audioDeviceStart:modemAudio:)
	func audioDeviceStart( _ devID: AudioDeviceID, modemAudio client: ModemAudio ) -> OSStatus
	{
		let isInputClient = client.isInput()
		let dev = registeredAudioDevice( forID: devID )
		let status: OSStatus

		if isInputClient == true {
			let isRunning = ( dev.pointee.activeInputClients > 0 )
			addClient( client, toDevice: dev, list: rawArray( dev, offActiveInputArray ), listSize: countPtr( dev, offActiveInputCount ) )
			//  return if device is already running
			if isRunning { return 0 }
			status = cm_AudioDeviceStart( dev.pointee.deviceID, deviceInputProc )
		}
		else {
			let isRunning = ( dev.pointee.activeOutputClients > 0 )
			addClient( client, toDevice: dev, list: rawArray( dev, offActiveOutputArray ), listSize: countPtr( dev, offActiveOutputCount ) )
			//  return if device is already running
			if isRunning { return 0 }
			status = cm_AudioDeviceStart( dev.pointee.deviceID, deviceOutputProc )
		}
		return status
	}

	@objc(audioDeviceStop:modemAudio:)
	func audioDeviceStop( _ devID: AudioDeviceID, modemAudio client: ModemAudio ) -> OSStatus
	{
		let isInputClient = client.isInput()
		let dev = registeredAudioDevice( forID: devID )
		let status: OSStatus

		if isInputClient {
			let isRunning = ( dev.pointee.activeInputClients > 0 )
			removeClient( client, fromDevice: dev, list: rawArray( dev, offActiveInputArray ), listSize: countPtr( dev, offActiveInputCount ) )
			//  after removal, do we still have active devices?
			//	if so, or it was already stopped, just return
			if dev.pointee.activeInputClients > 0 || isRunning == false { return 0 }
			//  otherwise, stop the device
			status = cm_AudioDeviceStop( dev.pointee.deviceID, deviceInputProc )
		}
		else {
			let isRunning = ( dev.pointee.activeOutputClients > 0 )
			removeClient( client, fromDevice: dev, list: rawArray( dev, offActiveOutputArray ), listSize: countPtr( dev, offActiveOutputCount ) )
			//  after removal, do we still have active devices?
			//	if so, or it was already stopped, just return
			if dev.pointee.activeOutputClients > 0 || isRunning == false { return 0 }
			status = cm_AudioDeviceStop( dev.pointee.deviceID, deviceOutputProc )
		}
		return status
	}

	@objc(putCodecsToSleep)
	func putCodecsToSleep()
	{
		//  check list of sound cards and stop any one that is running
		for i in 0..<registeredAudioDevices {
			guard let cachedID = registeredAudioDevice[i] else { continue }
			if cachedID.pointee.activeInputClients > 0 { _ = cm_AudioDeviceStop( cachedID.pointee.deviceID, deviceInputProc ) }
			if cachedID.pointee.activeOutputClients > 0 { _ = cm_AudioDeviceStop( cachedID.pointee.deviceID, deviceOutputProc ) }
		}
	}

	@objc(wakeCodecsUp)
	func wakeCodecsUp()
	{
		//  check list of sound cards and start any one that should be running
		for i in 0..<registeredAudioDevices {
			guard let cachedID = registeredAudioDevice[i] else { continue }
			if cachedID.pointee.activeInputClients > 0 { _ = cm_AudioDeviceStart( cachedID.pointee.deviceID, deviceInputProc ) }
			if cachedID.pointee.activeOutputClients > 0 { _ = cm_AudioDeviceStart( cachedID.pointee.deviceID, deviceOutputProc ) }
		}
	}

	//  get all modems that are registered even if they are not active
	private func getRegisteredModemAudioList( _ deviceID: AudioDeviceID, isInput: Bool ) -> [ModemAudio]
	{
		guard let audioDevice = audioDevice( forID: deviceID ) else { return [] }		//  no one has the deviceID registered

		let n: Int
		let list: UnsafeMutablePointer<UnsafeMutableRawPointer?>
		if isInput {
			n = Int( audioDevice.pointee.inputClients )
			list = rawArray( audioDevice, offInputArray )
		}
		else {
			n = Int( audioDevice.pointee.outputClients )
			list = rawArray( audioDevice, offOutputArray )
		}
		var result = [ModemAudio]()
		result.reserveCapacity( n )
		for i in 0..<n { result.append( Unmanaged<ModemAudio>.fromOpaque( list[i]! ).takeUnretainedValue() ) }
		return result
	}

	private func getModemAudioList( _ deviceID: AudioDeviceID, isInput: Bool ) -> [ModemAudio]
	{
		guard let audioDevice = audioDevice( forID: deviceID ) else { return [] }		//  no one has the deviceID registered

		let n: Int
		let list: UnsafeMutablePointer<UnsafeMutableRawPointer?>
		if isInput {
			n = Int( audioDevice.pointee.activeInputClients )
			list = rawArray( audioDevice, offActiveInputArray )
		}
		else {
			n = Int( audioDevice.pointee.activeOutputClients )
			list = rawArray( audioDevice, offActiveOutputArray )
		}
		var result = [ModemAudio]()
		result.reserveCapacity( n )
		for i in 0..<n { result.append( Unmanaged<ModemAudio>.fromOpaque( list[i]! ).takeUnretainedValue() ) }
		return result
	}

	//	(Private API)
	fileprivate func muted( _ deviceID: AudioDeviceID, isInput: Bool )
	{
		let list = getModemAudioList( deviceID, isInput: isInput )
		if list.count > 0 {
			_ = Messages.alert( withMessageText: "Warning: Another application has muted a sound card used by cocoaModem", informativeText: "" )
		}
	}

	//	(Private API)
	fileprivate func sourceChanged( _ deviceID: AudioDeviceID, isInput: Bool )
	{
		//  ask all ModemAudio with this AudioDeviceID to update their sources
		for client in getRegisteredModemAudioList( deviceID, isInput: isInput ) { client.fetchSourceFromCoreAudio() }
	}

	//	(Private API)
	fileprivate func samplingRateChanged( _ deviceID: AudioDeviceID, isInput: Bool )
	{
		//  ask all ModemAudio with this AudioDeviceID to update their sources
		for client in getRegisteredModemAudioList( deviceID, isInput: isInput ) { client.fetchSamplingRateFromCoreAudio() }
	}

	//	(Private API)
	fileprivate func audioLevelChanged( _ deviceID: AudioDeviceID, isInput: Bool )
	{
		//  ask all ModemAudio with this AudioDeviceID to update their sources
		for client in getRegisteredModemAudioList( deviceID, isInput: isInput ) { client.fetchDeviceLevelFromCoreAudio() }
	}
}
