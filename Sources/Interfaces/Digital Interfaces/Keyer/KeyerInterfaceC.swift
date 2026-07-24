//
//  KeyerInterfaceC.swift
//  cocoaModem 2.0
//
//  Swift port of the two free C helper functions in KeyerInterface.m.
//  Created by Kok Chen on 2/11/08 (Obj-C); ported to Swift.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  These are called from Router.swift / MicroKeyer.swift / KeyerInterface.swift
//  through their original C-imported signatures, which are preserved verbatim.
//

import Foundation

//  ROUTERFUNCTION (0x80) + 0x08 -- from RouterCommands.h (object-like macro not imported to Swift).
private let OPENKEYER: Int32 = 0x88

//  Open a pair of ports to the parent ports for read and write to a given type of connection
//	if one of the result pointers is nil, no open is made to that file descriptor
//	return -1 in all non-nil file descriptors of cannot open connection

func obtainRouterPorts(_ readFileDescriptor: UnsafeMutablePointer<Int32>!, _ writeFileDescriptor: UnsafeMutablePointer<Int32>!, _ type: Int32, _ parentReadFileDescriptor: Int32, _ parentWriteFileDescriptor: Int32) {

    var path = [CChar](repeating: 0, count: 26)
    var string = [CChar](repeating: 0, count: 20)
    var request = [CChar](repeating: CChar(truncatingIfNeeded: type), count: 1)

    _ = write(parentWriteFileDescriptor, &request, 1)
    if read(parentReadFileDescriptor, &string, 20) > 0 {

        if let writeFileDescriptor = writeFileDescriptor {
            if string[0] == 0 { writeFileDescriptor.pointee = -1 }
            else {
                strcpy(&path, &string)
                strcat(&path, "Write")
                writeFileDescriptor.pointee = open(&path, O_WRONLY)
            }
        }
        if let readFileDescriptor = readFileDescriptor {
            if string[0] == 0 { readFileDescriptor.pointee = -1 }
            else {
                strcpy(&path, &string)
                strcat(&path, "Read")
                readFileDescriptor.pointee = open(&path, O_RDONLY)
            }
        }
    }
}

//  v0.89
//	Use OPENKEYER instead of OPENMICROKEYER, OPENCWKEYER or OPENDIGIKEYER

func obtainKeyerPortsFromKeyerID(_ readFileDescriptor: UnsafeMutablePointer<Int32>!, _ writeFileDescriptor: UnsafeMutablePointer<Int32>!, _ keyerID: UnsafeMutablePointer<CChar>!, _ parentReadFileDescriptor: Int32, _ parentWriteFileDescriptor: Int32) {

    var path = [CChar](repeating: 0, count: 72)
    var string = [CChar](repeating: 0, count: 64)
    var request = [CChar](repeating: 0, count: 32)

    request[0] = CChar(truncatingIfNeeded: OPENKEYER)     //  OPENKEYER from RouterCommands.h
    let n = Int(strlen(keyerID))
    var i = 0
    while i < n {
        request[i + 1] = keyerID[i]
        i += 1
    }
    request[i + 1] = 0
    _ = write(parentWriteFileDescriptor, &request, n + 2)

    if read(parentReadFileDescriptor, &string, 63) > 0 {
        if let writeFileDescriptor = writeFileDescriptor {
            if string[0] == 0 { writeFileDescriptor.pointee = -1 }
            else {
                strcpy(&path, &string)
                strcat(&path, "Write")
                writeFileDescriptor.pointee = open(&path, O_WRONLY)
            }
        }
        if let readFileDescriptor = readFileDescriptor {
            if string[0] == 0 { readFileDescriptor.pointee = -1 }
            else {
                strcpy(&path, &string)
                strcat(&path, "Read")
                readFileDescriptor.pointee = open(&path, O_RDONLY)
            }
        }
    }
}
