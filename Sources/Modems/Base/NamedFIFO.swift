//
//  NamedFIFO.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 5/15/06.
//  Swift port of NamedFIFO.m.
//

import Foundation

//  implementation of a Unix named FIFO for doing read() and write() operations
@objc(NamedFIFO)
class NamedFIFO: NSObject {

	private var name: UnsafeMutablePointer<CChar>?
	private var inputFD: Int32 = 0
	private var outputFD: Int32 = 0

	@objc(initWithPipeName:)
	init( pipeName fifoName: UnsafePointer<CChar> )
	{
		super.init()

		let n = strlen( fifoName )
		name = malloc( n + 32 )?.assumingMemoryBound( to: CChar.self )
		if let name = name {
			strcpy( name, fifoName )
			strcat( name, "-XXXXXX" )
			mktemp( name )
			inputFD = 0
			outputFD = 0
			//  now create the pipe
			if mknod( name, mode_t( S_IFIFO | 0o600 ), 0 ) == 0 {
				//  now open for read and write
				inputFD = open( name, O_RDWR )
				if inputFD > 0 {
					//  original issued ioctl( inputFileDescriptor, O_RDONLY, 0 ) "to
					//  change to read-only".  O_RDONLY (0) is not a valid ioctl request
					//  and the call was a no-op whose result was ignored; Swift cannot
					//  call the C variadic ioctl(), so the no-op is simply omitted.
					outputFD = open( name, O_RDWR | O_NONBLOCK )
				}
			}
		}
	}

	deinit
	{
		if let name = name {
			unlink( name )
			free( name )
		}
	}

	@objc func stopPipe()
	{
		if name != nil {
			if outputFD > 0 { close( outputFD ) }
		}
	}

	@objc func inputFileDescriptor() -> Int32
	{
		return inputFD
	}

	@objc func outputFileDescriptor() -> Int32
	{
		return outputFD
	}
}
