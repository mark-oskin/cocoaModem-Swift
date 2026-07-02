//
//  KeyerInterface.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/11/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  The KeyerInterface class is now Swift (see KeyerInterface.swift /
//  cocoaModem-Swift.h).  Only the two global C helper functions remain here in
//  C, so that Router.swift, MicroKeyer.swift and any Obj-C caller keep a stable
//  C-linkage symbol (a Swift global function cannot export a plain C symbol).
//

#ifndef _KEYERINTERFACE_H_
	#define _KEYERINTERFACE_H_

	@class KeyerInterface ;

	//  Open a pair of ports to the parent ports for read and write to a given type of connection.
	void obtainRouterPorts( int *readFileDescriptor, int *writeFileDescriptor, int type, int parentReadFileDescriptor, int parentWriteFileDescriptor ) ;

	//  v0.89 -- open a keyer from its keyerID
	void obtainKeyerPortsFromKeyerID( int *readFileDescriptor, int *writeFileDescriptor, char *keyerID, int parentReadFileDescriptor, int parentWriteFileDescriptor ) ;

#endif
