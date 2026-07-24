//
//  BonjourService.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/19/07.
//  Copyright 2007 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of BonjourService.m.
//

import Foundation

//  BonjourService sets up an NetServiceBrowser to watch for AUNetSend SERVICETYPE ("_apple-ausend._tcp.") sockets.
//
//  BonjourService accepts a list of service names to monitor.  A client makes a request to BonjourService using the
//	-registerService: method.  BonjourService will return a BonjourSocket for each service name is registered.
//
//  Whenever BonjourService detects a connection, it will check the connection against the list that it was asked to monitor.
//	If the socket is one of the BonjourSocket it is monitoring, BonjourService passes the Unix sockaddr to the target BonjourSocket.
//
//  Each BonjourSocket can accept a delegate (different instances of BonjourSocket can have its own delegate).  Whenever a
//  BonjourSocket receives sockaddr indicating a new connection, it can call the delegate with the -bonjourNetReceiveConnect: method.
//
//  When BonjourService detects a disconnect on one of the sockets it is monitoring, it passes the disconnection information
//	to the BonjourSocket and in turn BonjourSocket can inform its delegate.
//
//	Note that each BonjourSocket has its own delegate.

private let SERVICETYPE = "_apple-ausend._tcp."

@objc(BonjourService)
class BonjourService: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

	private var browser: NetServiceBrowser?
	private var sockets: [BonjourSocket] = []
	//  Holds services strongly while they resolve asynchronously.  The original
	//  balanced this with an explicit -retain in -didFindService and a -release in
	//  -netServiceDidResolveAddress / -didNotResolve; under ARC we mirror that with
	//  add/remove on this array so lifetime is preserved exactly.
	private var resolvingServices: [NetService] = []

	override init()
	{
		super.init()
		browser = nil
		sockets = []
	}

	deinit
	{
		if let browser = browser {
			browser.stop()
		}
	}

	private func findServices()
	{
		if browser != nil { browser = nil }

		let browser = NetServiceBrowser()
		self.browser = browser
		browser.delegate = self
		browser.searchForServices( ofType: SERVICETYPE, inDomain: "" )
	}

	@objc(registerService:)
	func registerService( _ serviceName: String ) -> BonjourSocket?
	{
		let socket = BonjourSocket( name: serviceName )
		sockets.append( socket )
		findServices()			// rescan for services
		return socket
	}

	@objc(removeService:)
	func removeService( _ serviceName: String )
	{
		for i in 0..<sockets.count {
			let socket = sockets[i]
			if socket.serviceName() == serviceName {
				sockets.remove( at: i )
				findServices()		//  rescan for sevices
				return
			}
		}
	}

	//  delegate for NetServiceBrowser that was created from -findServices:
	//  NetServiceBrowser calls this for each service it finds.
	//  In turn, this method asks for address resolution from NetService, which calls -netServiceDidResolveAddress:
	func netServiceBrowser( _ inBrowser: NetServiceBrowser, didFind service: NetService, moreComing: Bool )
	{
		//  found service
		//  now resolve address for this server, it should either call -netServiceDidResolveAddress or -didNotResolve below
		resolvingServices.append( service )		//  retain during async resolution
		service.delegate = self
		service.resolve( withTimeout: 3.0 )		//  resolve address to get address and port
	}

	func netServiceBrowser( _ netServiceBrowser: NetServiceBrowser, didRemove service: NetService, moreComing moreServicesComing: Bool )
	{
		findServices()			//  update service
	}

	//  Catch address resolutions for NetService resolveWithTimeout messages in -netServiceBrowser:didFindService
	//  Creates a NetAudioDevice for each device that is found.
	//  When the last service is reached, -netServiceDidResolve address signals the main thread by unlocking the lock.
	func netServiceDidResolveAddress( _ service: NetService )
	{
		let serviceName = service.name
		let addresses = service.addresses ?? []
		let count = addresses.count
		for index in 0..<count {
			//  find an address among the address listed
			let data = addresses[index]
			let matched = data.withUnsafeBytes { ( raw: UnsafeRawBufferPointer ) -> Bool in
				guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return false }
				var addr = base.assumingMemoryBound( to: sockaddr_in.self ).pointee
				if addr.sin_family == sa_family_t( AF_INET ) {
					// found an IPv4 address, check name against list in sockets array
					for socket in sockets {
						if serviceName == socket.serviceName() {
							//  found it... set up address
							socket.connectSocketAddr( &addr )
							return true
						}
					}
				}
				return false
			}
			if matched {
				release( service )
				return
			}
		}
		//  did not find any IPv4 address
		release( service )
	}

	func netService( _ service: NetService, didNotResolve error: [String : NSNumber] )
	{
		browser?.stop()
		browser = nil
		release( service )
	}

	//  mirror of the original's -[service release] balancing the -retain in -didFindService
	private func release( _ service: NetService )
	{
		if let idx = resolvingServices.firstIndex( where: { $0 === service } ) {
			resolvingServices.remove( at: idx )
		}
	}
}
