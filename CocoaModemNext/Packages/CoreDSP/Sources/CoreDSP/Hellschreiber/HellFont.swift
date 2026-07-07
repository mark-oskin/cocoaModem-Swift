//
//  HellFont.swift
//  CoreDSP
//
//  The Hellschreiber pixel-raster font table.
//
//  IMPORTANT PROVENANCE NOTE (read before "fixing" this file):
//  The original app's font table was NOT literal Swift/C source. HellModulator
//  loaded a compiled binary blob (a HellschreiberFontHeader struct followed by
//  a packed byte pixmap) from a *.font resource file on disk via fopen(), see
//  the ported-but-inert loader in HellschreiberFontC.swift (MakeHellFont). That
//  binary was itself compiled, by a separate "CreateFont" build tool, FROM a
//  human-authored ASCII-art glyph table -- the actual, only human-readable
//  source of the pixel patterns anywhere in the old repository:
//
//      /Users/oskin/Desktop/cm/CreateFont/Fonts Definitions/cmsmall_def.h
//
//  Since there is no literal Swift raster table to "transcribe verbatim" (the
//  real one is a runtime-loaded binary that doesn't exist as source), this file
//  instead transcribes the verbatim ASCII-art glyph rows from cmsmall_def.h
//  ('.' = off, '+' = dim, 'o' = medium, 'O' = full brightness -- exactly the
//  characters used in the original file) and converts them into per-column
//  gray-value arrays at load time. This is a deliberate, documented substitution
//  for the binary font resource, not an approximation of pixel *shapes* -- the
//  row strings below are copied character-for-character from cmsmall_def.h.
//
//  KNOWN LIMITATION: cmsmall_def.h defines separate upper- and lower-case glyphs
//  plus a large symbol set; to keep this transplant tractable we transcribed
//  uppercase A-Z, digits 0-9, space, and the punctuation most relevant to
//  amateur-radio traffic (period, comma, colon, semicolon, question mark,
//  hyphen, slash, apostrophe, parens, at-sign, equals). Lowercase ASCII input
//  is folded to uppercase before lookup (traditional Feld Hell traffic is
//  caps-only). Any character without a glyph renders as a narrow blank column.
//

import Foundation

enum HellFont {

    /// Gray levels for the ASCII-art density characters used in cmsmall_def.h.
    /// ('*' appears once in the source, in "newe", clearly standing in for 'O'.)
    private static func gray(for symbol: Character) -> UInt8 {
        switch symbol {
        case ".": return 0
        case "+": return 96
        case "o": return 170
        case "O", "*": return 255
        default: return 0
        }
    }

    /// Row height every glyph is transcribed at (matches cmsmall_def.h's 6-row cells).
    private static let sourceRows = 6
    /// Column height a HellModulator/HellReceiver column carries (14 active
    /// Hellschreiber pixels per column, matching the original's non-FM105
    /// per-column pixel count). The 6 source rows are embedded centered
    /// within this taller cell.
    static let columnHeight = 14
    private static let rowInset = (columnHeight - sourceRows) / 2   // = 4

    /// Verbatim ASCII-art rows, transcribed character-for-character from
    /// /Users/oskin/Desktop/cm/CreateFont/Fonts Definitions/cmsmall_def.h.
    private static let glyphRows: [Character: [String]] = [
        " ": ["...................", "...................", "...................",
              "...................", "...................", "..................."],

        "A": [".+OOO+............", ".O...O............", ".O...O............",
              ".OOOOO............", ".O...O............", "..................."],
        "B": [".OOOO+............", ".O...O............", ".OOOO+............",
              ".O...O............", ".OOOO+............", "..................."],
        "C": [".+OOOO............", ".O................", ".O................",
              ".O................", ".+OOOO............", "..................."],
        "D": [".OOOO+............", ".O...O............", ".O...O............",
              ".O...O............", ".OOOO+............", "..................."],
        "E": [".OOOOO............", ".O................", ".OOOO.............",
              ".O................", ".OOOOO............", "..................."],
        "F": [".OOOOO............", ".O................", ".OOOO.............",
              ".O................", ".O................", "..................."],
        "G": [".+OOOO............", ".O................", ".O..OO............",
              ".O...O............", ".+OOOO............", "..................."],
        "H": [".O...O............", ".O...O............", ".OOOOO............",
              ".O...O............", ".O...O............", "..................."],
        "I": ["..O...............", "..O...............", "..O...............",
              "..O...............", "..O...............", "..................."],
        "J": ["....OO............", ".....O............", ".....O............",
              ".O...O............", ".+OOO+............", "..................."],
        "K": [".O...O............", ".O..O.............", ".OOO..............",
              ".O..O.............", ".O...O............", "..................."],
        "L": [".O................", ".O................", ".O................",
              ".O................", ".OOOOO............", "..................."],
        "M": [".+OO+OO+..........", ".O..O..O..........", ".O..O..O..........",
              ".O..O..O..........", ".O..O..O..........", "..................."],
        "N": [".+OOO+.............", ".O...O............", ".O...O............",
              ".O...O............", ".O...O............", "..................."],
        "O": [".+OOO+............", ".O...O............", ".O...O............",
              ".O...O............", ".+OOO+............", "..................."],
        "P": [".OOOO+............", ".O...O............", ".O...O............",
              ".OOOO+............", ".O................", "..................."],
        "Q": [".+OOO+............", ".O...O............", ".O.o.O............",
              ".O.O.O............", ".+OOOO............", "......O..........."],
        "R": [".OOOO+............", ".O...O............", ".OOOO+............",
              ".O..O.............", ".O...O............", "..................."],
        "S": [".+OOOO............", ".O................", ".+OOO+............",
              ".....O............", ".OOOO+............", "..................."],
        "T": [".OOOOO............", "...O..............", "...O..............",
              "...O..............", "...O..............", "..................."],
        "U": [".O...O............", ".O...O............", ".O...O............",
              ".O...O............", ".+OOO+............", "..................."],
        "V": [".O...O............", ".O...O............", ".O..O.............",
              ".O.O..............", ".Oo...............", "..................."],
        "W": [".O..O..O..........", ".O..O..O..........", ".O..O..O..........",
              ".O..O..O..........", ".+OO.OO+..........", "..................."],
        "X": [".O...O............", "..O.O.............", "...O..............",
              "..O.O.............", ".O...O............", "..................."],
        "Y": [".O...O............", "..O.O.............", "...O..............",
              "...O..............", "...O..............", "..................."],
        "Z": [".OOOOO............", "....O.............", "...O..............",
              "..O...............", ".OOOOO............", "..................."],

        "0": [".+OOO+............", ".O...O............", ".O.O.O............",
              ".O...O............", ".+OOO+............", "..................."],
        "1": [".+O...............", ".OO...............", "..O...............",
              "..O...............", "..O...............", "..................."],
        "2": [".OOOO+............", ".....O............", "..OOO.............",
              ".O................", ".OOOOO............", "..................."],
        "3": [".OOOO+............", ".....O............", "..OOO.............",
              ".....O............", ".OOOO+............", "..................."],
        "4": ["....OO............", "...O.O............", "..O..O............",
              ".OOOOO............", ".....O............", "..................."],
        "5": [".OOOO.............", ".O................", ".OOOO+............",
              ".....O............", ".OOOO+............", "..................."],
        "6": [".+OOO.............", ".O................", ".OOOO+............",
              ".O...O............", ".+OOO+............", "..................."],
        "7": [".OOOOO............", ".....O............", "....O.............",
              "...O..............", "..O...............", "..................."],
        "8": [".+OOO+............", ".O...O............", ".+OOO+............",
              ".O...O............", ".+OOO+............", "..................."],
        "9": [".+OOO+............", ".O...O............", ".+OOOO............",
              ".....O............", "..OOO+............", "..................."],

        ".": ["...................", "...................", "...................",
              "...................", "..O................", "..................."],
        ",": ["...................", "...................", "...................",
              "...................", "...O...............", "..O................"],
        ":": ["...................", "..O................", "...................",
              "...................", "..O................", "..................."],
        ";": ["...................", "...O...............", "...................",
              "...................", "...O...............", "..O................"],
        "?": [".+OOO+............", ".O..oO...........", "...o+.............",
              "...................", "...O..............", "..................."],
        "-": ["...................", "...................", ".OOOOO............",
              "...................", "...................", "..................."],
        "/": [".....O............", "....O.............", "...O..............",
              "..O...............", ".O................", "..................."],
        "\\": [".O................", "..O...............", "...O..............",
              "....O.............", ".....O............", "..................."],
        "'": ["..O...............", "..O...............", "...................",
              "...................", "...................", "..................."],
        "(": ["..+O..............", "..O...............", "..O...............",
              "..O...............", "..+O..............", "..................."],
        ")": ["..O+..............", "...O..............", "...O..............",
              "...O..............", "..O+..............", "..................."],
        "@": [".+OOOO+............", ".O.O..O............", ".O.OOO+............",
              ".O................", ".+OOOO............", "..................."],
        "=": ["...................", ".OOOOO............", "...................",
              ".OOOOO............", "...................", "..................."],
    ]

    /// Rendered gray-value columns for `character` (folded to uppercase), 14
    /// pixels tall each. Unknown characters render as a 3-column blank cell
    /// (matching the width of a plain space) instead of trapping.
    static func columns(for character: Character) -> [[UInt8]] {
        let key = Character(character.uppercased())
        guard let rows = glyphRows[key], rows.count == sourceRows else {
            return blankColumns(3)
        }

        // Ink-trim: find the rightmost column (0-based) touched by any row,
        // across all rows, so narrow glyphs ("I", "1", ".") don't carry 19
        // columns of dead space.
        var lastInk = 0
        for row in rows {
            let chars = Array(row)
            for (i, c) in chars.enumerated() where c != "." {
                lastInk = max(lastInk, i)
            }
        }
        let width = max(lastInk + 1, 1)

        var result: [[UInt8]] = []
        result.reserveCapacity(width + 1)
        for col in 0..<width {
            var column = [UInt8](repeating: 0, count: columnHeight)
            for (r, row) in rows.enumerated() {
                let chars = Array(row)
                guard col < chars.count else { continue }
                column[rowInset + r] = gray(for: chars[col])
            }
            result.append(column)
        }
        // one blank inter-character spacing column
        result.append([UInt8](repeating: 0, count: columnHeight))
        return result
    }

    private static func blankColumns(_ count: Int) -> [[UInt8]] {
        Array(repeating: [UInt8](repeating: 0, count: columnHeight), count: count)
    }
}
