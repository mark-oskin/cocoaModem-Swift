//
//  BonjourSocket.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/20/07.
//  Copyright 2007 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of BonjourSocket.m.
//

import Foundation

//  BonjourSocket stores the service name and socket address of a Bonjour port
//	Whenever it is called with a Unix sockaddr, it can call a delegate to inform the delgate that a new connection has been made.
//  Whenever it is called to disconnect, it can call a delegate to inform the delegate that an existing connection has been terminated.
//
//  BonjourSocket is used by BonjourService.

@objc(BonjourSocket)
class BonjourSocket: NSObject {

	private var serviceNameValue: String
	private var socketAddress = sockaddr_in()
	private var connected: Bool
	//  delegate is assigned, not retained (matches the original MRC `delegate = inDelegate`)
	private weak var delegate: AnyObject?

	@objc(initWithName:)
	init( name: String )
	{
		serviceNameValue = name
		connected = false
		delegate = nil
		super.init()
	}

	@objc(setDelegate:)
	func setDelegate( _ inDelegate: Any? )
	{
		delegate = inDelegate as AnyObject?
	}

	// delegate method
	@objc(soundFileStarting:)
	func soundFileStarting( _ filename: String )
	{
		let sel = #selector(BonjourSocket.soundFileStarting(_:))
		if let d = delegate as? NSObject, d.responds( to: sel ) { d.perform( sel, with: filename ) }
	}

	//  delegate method
	@objc(bonjourNetReceiveConnect:)
	func bonjourNetReceiveConnect( _ socket: BonjourSocket )
	{
		// used by delegate to receive a connection
	}

	@objc(bonjourNetReceiveDisconnect:)
	func bonjourNetReceiveDisconnect( _ socket: BonjourSocket )
	{
		// used by delegate to receive a disconnection
	}

	@objc(connectSocketAddr:)
	func connectSocketAddr( _ addr: UnsafeMutablePointer<sockaddr_in> )
	{
		socketAddress = addr.pointee
		connected = true
		let sel = #selector(BonjourSocket.bonjourNetReceiveConnect(_:))
		if let d = delegate as? NSObject, d.responds( to: sel ) { d.perform( sel, with: self ) }
	}

	@objc(disconnect)
	func disconnect()
	{
		connected = false
		let sel = #selector(BonjourSocket.bonjourNetReceiveDisconnect(_:))
		if let d = delegate as? NSObject, d.responds( to: sel ) { d.perform( sel, with: self ) }
	}

	@objc(serviceName)
	func serviceName() -> String
	{
		return serviceNameValue
	}

	@objc(ip)
	func ip() -> UnsafeMutablePointer<CChar>!
	{
		return inet_ntoa( socketAddress.sin_addr )
	}

	@objc(port)
	func port() -> Int32
	{
		return Int32( UInt16( bigEndian: socketAddress.sin_port ) )		//  ntohs
	}
}
