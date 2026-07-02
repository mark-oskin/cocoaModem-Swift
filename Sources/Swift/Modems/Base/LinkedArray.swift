//
//  LinkedArray.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/8/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of LinkedArray.m.
//

import Foundation

//  A fixed-capacity singly linked list backed by a preallocated C array of
//  nodes plus an idle free-list, exactly like the original.  The stored
//  objects are held UNRETAINED (the original ran under MRC and never retained
//  the id it kept in each node), so the node's data slot is an opaque,
//  non-owning pointer.  Identity comparison of two objects therefore reduces
//  to comparing their opaque pointers, matching the original "p->data == object".
@objc(LinkedArray)
class LinkedArray: NSObject {

	private struct DataElement {
		var data: UnsafeMutableRawPointer?					//  unretained id
		var next: UnsafeMutablePointer<DataElement>?
	}

	private var head: UnsafeMutablePointer<DataElement>?
	private var current: UnsafeMutablePointer<DataElement>?
	private let all: UnsafeMutablePointer<DataElement>
	private let idle: UnsafeMutablePointer<UnsafeMutablePointer<DataElement>?>
	private var elements: Int32 = 0
	private var idleElements: Int32
	private let capacity: Int32
	private let busy = NSLock()
	private var ident: String

	@objc(initWithCapacity:ident:)
	init( capacity size: Int32, ident inIdent: String )
	{
		capacity = size
		let cap = Int( size )
		all = UnsafeMutablePointer<DataElement>.allocate( capacity: cap )
		all.initialize( repeating: DataElement( data: nil, next: nil ), count: cap )
		idle = UnsafeMutablePointer<UnsafeMutablePointer<DataElement>?>.allocate( capacity: cap )
		for i in 0..<cap { idle[i] = all.advanced( by: i ) }
		elements = 0
		idleElements = size
		ident = inIdent
		head = nil
		current = nil
		super.init()
	}

	@objc(initWithCapacity:)
	convenience init( capacity size: Int32 )
	{
		//  original default ident was the object's pointer printed as an int;
		//  ident is only used by the (disabled) DEBUGARRAY printf, so its exact
		//  value does not matter.
		self.init( capacity: size, ident: "" )
	}

	@objc override convenience init()
	{
		self.init( capacity: 64 )
	}

	deinit
	{
		all.deinitialize( count: Int( capacity ) )
		all.deallocate()
		idle.deallocate()
	}

	//  MARK: - opaque (unretained) helpers

	@inline(__always) private func opaque( _ o: Any? ) -> UnsafeMutableRawPointer?
	{
		guard let o = o else { return nil }
		return Unmanaged.passUnretained( o as AnyObject ).toOpaque()
	}

	@inline(__always) private func object( _ p: UnsafeMutableRawPointer? ) -> Any?
	{
		guard let p = p else { return nil }
		return Unmanaged<AnyObject>.fromOpaque( p ).takeUnretainedValue()
	}

	//  MARK: - idle free list

	private func getIdleElement() -> UnsafeMutablePointer<DataElement>
	{
		idleElements -= 1
		return idle[ Int( idleElements ) ]!
	}

	private func putIdleElement( _ element: UnsafeMutablePointer<DataElement> )
	{
		idle[ Int( idleElements ) ] = element
		idleElements += 1
	}

	@objc func count() -> Int32
	{
		return elements
	}

	private func assign( _ object: Any?, next: UnsafeMutablePointer<DataElement>? ) -> UnsafeMutablePointer<DataElement>?
	{
		if elements >= capacity {
			NSLog( "DataArray exceeced capacity (%d)!", elements )
			return nil
		}
		let p = getIdleElement()
		p.pointee.next = next
		p.pointee.data = opaque( object )
		elements += 1
		return p
	}

	@objc(objectAtIndex:)
	func object( at index: Int32 ) -> Any?
	{
		if index >= elements {
			NSLog( "DataArray objectAtIndex error: array index (%d) out of bounds (%d)!", index, elements )
			current = nil
			return nil
		}
		busy.lock()
		var p = head
		var i: Int32 = 0
		while i < index { p = p?.pointee.next; i += 1 }
		let obj = ( p != nil ) ? object( p!.pointee.data ) : nil
		current = p
		busy.unlock()
		return obj
	}

	//  after an objectAtIndex call, or a previous nextObject call, this returns the next object, or nil
	@objc func nextObject() -> Any?
	{
		guard let c = current else { return nil }
		current = c.pointee.next
		guard let c2 = current else { return nil }
		return object( c2.pointee.data )
	}

	@objc(addObject:)
	func addObject( _ object: Any? )
	{
		if elements >= capacity {
			//  increase capacity here
			NSLog( "Internal DataArray error: capacity reached!" )
			return
		}
		busy.lock()
		if elements == 0 {
			head = assign( object, next: nil )
			busy.unlock()
			return
		}
		//  find tail
		var p = head
		var i: Int32 = 0
		while i < elements {
			if p?.pointee.next == nil { break }
			p = p?.pointee.next
			i += 1
		}
		if i >= elements {
			NSLog( "Internal DataArray error: did not find tail of linked list." )
			busy.unlock()
			return
		}
		p?.pointee.next = assign( object, next: p?.pointee.next )
		busy.unlock()
	}

	@objc(insertObject:atIndex:)
	func insertObject( _ object: Any?, at index: Int32 )
	{
		busy.lock()
		if index == 0 {
			//  let index 0 be used even if list is empty
			head = assign( object, next: head )
			busy.unlock()
			return
		}
		if index >= elements {
			NSLog( "DataArray insertObject error: array index (%d) out of bounds (%d)!", index, elements )
			busy.unlock()
			return
		}
		var p = head
		var i: Int32 = 1
		while i < index { p = p?.pointee.next; i += 1 }
		p?.pointee.next = assign( object, next: p?.pointee.next )
		busy.unlock()
	}

	@objc(removeObjectAtIndex:)
	func removeObject( at index: Int32 )
	{
		if index >= elements {
			NSLog( "DataArray removeObject error: array index (%d) out of bounds (%d)!", index, elements )
			return
		}
		busy.lock()
		if index == 0 {
			if let h = head {
				putIdleElement( h )
				elements -= 1
				head = h.pointee.next
			}
			busy.unlock()
			return
		}
		var p = head
		var q = head
		var i: Int32 = 0
		while i < index {
			q = p
			p = p?.pointee.next
			i += 1
		}
		if let p = p {
			putIdleElement( p )
			elements -= 1
			q?.pointee.next = p.pointee.next
		}
		busy.unlock()
	}

	//  find index of object, return -1 if not found
	@objc(indexOfObject:)
	func indexOfObject( _ object: Any? ) -> Int32
	{
		let target = opaque( object )
		busy.lock()
		var p = head
		var i: Int32 = 0
		while i < elements {
			guard let pp = p else {
				busy.unlock()
				return -1
			}
			if pp.pointee.data == target {
				busy.unlock()
				return i
			}
			p = pp.pointee.next
			i += 1
		}
		busy.unlock()
		return -1
	}

	@objc(removeObject:)
	func removeObject( _ object: Any? )
	{
		let target = opaque( object )
		var found = false
		busy.lock()
		var p = head
		var q = head
		var i: Int32 = 0
		while i < elements {
			guard let pp = p else {
				NSLog( "DataArray internal error in removeObject: list shorter than it should be!" )
				busy.unlock()
				return
			}
			if pp.pointee.data == target {
				if found {
					//  sanity check
					NSLog( "DataArray removeObject error: object found in more than one location!" )
					if pp == head { head = pp.pointee.next } else { q?.pointee.next = pp.pointee.next }		//  v0.58
					putIdleElement( pp )																		//  v0.58
					elements -= 1																				//  v0.58
					p = q																						//  v0.58
				} else {
					found = true
					if pp == head { head = pp.pointee.next } else { q?.pointee.next = pp.pointee.next }
					putIdleElement( pp )
					elements -= 1
					p = q
				}
			}
			q = p
			p = p?.pointee.next
			i += 1
		}
		if !found {
			NSLog( "DataArray removeObject error: object not found!" )
		}
		busy.unlock()
	}

	@objc func removeAllObjects()
	{
		busy.lock()
		var p = head
		var i: Int32 = 0
		while i < elements {
			guard let pp = p else {
				NSLog( "DataArray internal error in removeAllObjects: list shorter than it should be!" )
				break
			}
			putIdleElement( pp )
			p = pp.pointee.next
			i += 1
		}
		head = nil
		elements = 0
		busy.unlock()
	}

	//  increase the index of an object, if possible
	@objc(increaseIndexOfObject:)
	func increaseIndexOfObject( _ object: Any? )
	{
		let target = opaque( object )
		busy.lock()
		var p = head
		var q = head
		var i: Int32 = 0
		while i < elements {
			guard let pp = p else {
				NSLog( "DataArray internal error in increaseIndexOfObject: list shorter than it should be!" )
				busy.unlock()
				return
			}
			if pp.pointee.data == target {
				guard let r = pp.pointee.next else {
					//  already at tail
					busy.unlock()
					return
				}
				if head == pp { head = r } else { q?.pointee.next = r }
				pp.pointee.next = r.pointee.next
				r.pointee.next = pp
				busy.unlock()
				return
			}
			q = p
			p = pp.pointee.next
			i += 1
		}
		NSLog( "DataArray error in increaseIndexOfObject: object not found!" )
		busy.unlock()
	}

	//  increase the index of an object, if possible
	@objc(increaseIndexOfObjectAtIndex:)
	func increaseIndexOfObject( at index: Int32 )
	{
		if elements <= 1 { return }
		busy.lock()
		if index == 0 {
			if let p = head, let r = p.pointee.next {
				head = r
				p.pointee.next = r.pointee.next
				r.pointee.next = p
			}
			busy.unlock()
			return
		}
		if index >= elements {
			NSLog( "DataArray increaseIndexOfObjectAtIndex error: array index (%d) out of bounds (%d)!", index, elements )
			busy.unlock()
			return
		}
		var p = head
		var q = head
		var i: Int32 = 1
		while i < index {
			guard let pp = p else {
				NSLog( "DataArray internal error in increaseIndexOfObjectAtIndex: list shorter than it should be!" )
				busy.unlock()
				return
			}
			q = p
			p = pp.pointee.next
			i += 1
		}
		if let pp = p, let r = pp.pointee.next {
			if head == pp { head = r } else { q?.pointee.next = r }
			pp.pointee.next = r.pointee.next
			r.pointee.next = pp
		}
		busy.unlock()
	}
}
