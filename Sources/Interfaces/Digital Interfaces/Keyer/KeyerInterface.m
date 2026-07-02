//
//  KeyerInterface.m
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/11/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  The KeyerInterface class was ported to Swift (see KeyerInterface.swift).
//  This file is retained in the build ONLY to keep the two global C helper
//  functions as real C-linkage symbols for Router.swift / MicroKeyer.swift.
//

#import "KeyerInterface.h"
#import "RouterCommands.h"

#include <unistd.h>
#include <fcntl.h>
#include <string.h>

//  Open a pair of ports to the parent ports for read and write to a given type of connection
//	if one of the result pointers is nil, no open is made to that file descriptor
//	return -1 in all non-nil file descriptors of cannot open connection

void obtainRouterPorts( int *readFileDescriptor, int *writeFileDescriptor, int type, int parentReadFileDescriptor, int parentWriteFileDescriptor )
{
	char path[26], string[20], request[1] = { type } ;

	write( parentWriteFileDescriptor, request, 1 ) ;
	if (  read( parentReadFileDescriptor, string, 20 ) > 0 ) {

		if ( writeFileDescriptor != NULL ) {
			if ( string[0] == 0 ) *writeFileDescriptor = -1 ;
			else {
				strcpy( path, string ) ;
				strcat( path, "Write" ) ;
				*writeFileDescriptor = open( path, O_WRONLY ) ;
			}
		}
		if ( readFileDescriptor ) {
			if ( string[0] == 0 ) *readFileDescriptor = -1 ;
			else {
				strcpy( path, string ) ;
				strcat( path, "Read" ) ;
				*readFileDescriptor = open( path, O_RDONLY ) ;
			}
		}
	}
}

//  v0.89
//	Use OPenKEYER instead of OPENMICROKEYER, OPENCWKEYER or OPENDIGIKEYER
void obtainKeyerPortsFromKeyerID( int *readFileDescriptor, int *writeFileDescriptor, char *keyerID, int parentReadFileDescriptor, int parentWriteFileDescriptor )
{
	char path[72], string[64], request[32] ;
	int i, n ;

	request[0]= OPENKEYER ;
	n = strlen( keyerID ) ;
	for ( i = 0; i < n; i++ ) request[i+1] = keyerID[i] ;
	request[i+1] = 0 ;
	write( parentWriteFileDescriptor, request, n+2 ) ;

	n = read( parentReadFileDescriptor, string, 63 );
	if ( n > 0 ) {
		if ( writeFileDescriptor != NULL ) {
			if ( string[0] == 0 ) *writeFileDescriptor = -1 ;
			else {
				strcpy( path, string ) ;
				strcat( path, "Write" ) ;
				*writeFileDescriptor = open( path, O_WRONLY ) ;
			}
		}
		if ( readFileDescriptor ) {
			if ( string[0] == 0 ) *readFileDescriptor = -1 ;
			else {
				strcpy( path, string ) ;
				strcat( path, "Read" ) ;
				*readFileDescriptor = open( path, O_RDONLY ) ;
			}
		}
	}
}
