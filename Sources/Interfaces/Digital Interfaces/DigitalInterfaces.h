//
//  DigitalInterfaces.h
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/11.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//
//  Converted to Swift (see DigitalInterfaces.swift / cocoaModem-Swift.h).
//  The interface-type constants and base-class imports are kept here because
//  many Objective-C files still reach DigitalInterface / Config / the k*Type
//  constants (and MicroKeyer) transitively through this header.
//

#import "DigitalInterface.h"
@class Config ;

#define	kVOXType			0
#define	kCocoaPTTType		1
#define	kMLDXType			2
#define kUserPTTType		3
#define	kMicroHAMType		4

@class MicroKeyer ;
@class Router ;
@class DigitalInterfaces ;
