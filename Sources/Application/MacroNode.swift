//
//  MacroNode.swift
//  cocoaModem
//
//  Swift port of MacroNode.m (Kok Chen, Sun Jul 04 2004).
//

import Foundation

@objc(MacroNode)
class MacroNode: NSObject {
	private var children: [MacroNode] = []
	private var name: String? = ""
	private var function: String?

	@objc override init()
	{
		super.init()
	}

	@objc(initWithName:function:)
	convenience init( name nameString: String?, function functionString: String? )
	{
		self.init()
		setNodeName( nameString, function: functionString )
	}

	@objc(setNodeName:function:)
	func setNodeName( _ nameString: String?, function functionString: String? )
	{
		name = nameString
		function = functionString
	}

	@objc func nodeName() -> String?
	{
		return name
	}

	@objc func nodeFunction() -> String?
	{
		return function
	}

	@objc(addChild:)
	func addChild( _ node: MacroNode )
	{
		children.append( node )
	}

	@objc(childAtIndex:)
	func child( at i: Int32 ) -> MacroNode
	{
		return children[ Int( i ) ]
	}

	@objc func childrenCount() -> Int32
	{
		return Int32( children.count )
	}
}
