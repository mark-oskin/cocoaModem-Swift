# Notes on the Objective-C → Swift conversion

Technical detail on how this port was done, split out of the main README
since it's only relevant to someone modifying this code, not someone running
the app.

Converted classes kept the original layout and these ground rules throughout
(see `Sources/Application/UTC.swift` for the pattern):

1. `@objc(OriginalName)` on every converted class — nibs instantiate classes
   by name, and other code messages them by selector.
2. Selectors and C types matched the original `.h` exactly
   (`@objc(originalSelector:)` where Swift naming differs).
3. Nib-connected ivars stayed KVC-compatible: `@objc var name: NSTextField!`
   with the exact original ivar name; actions as `@objc func name(_: Any?)`.
4. MRC `dealloc` → `deinit`; malloc'd/CF resources still freed explicitly.
5. Obj-C files that imported a converted header switched to importing
   `"cocoaModem-Swift.h"` instead; headers used `@class X;` forward decls.
6. Superclasses were never converted before their Obj-C subclasses (Obj-C
   can't inherit from Swift) — leaves of the class tree converted first.
7. `tools/pbx_swift.py add <path>` / `remove-m <File.m>` managed the old
   project file during the transition; kept the build green after every
   batch, with a launch test as a smoke check.

## The ivar-coupling wall

The hardest constraint throughout: **a Swift subclass cannot access an
Objective-C superclass's instance variables** — only its methods and
`@property` declarations. cocoaModem's DSP framework was built on the
opposite convention (subclasses reaching directly into base classes'
`@protected` C structs, fixed arrays, ring buffers, `void*` pipelines), which
split the remaining classes into three tiers:

1. **Cleanly convertible** — rooted at a system class, or touches its Obj-C
   base only through methods.
2. **KVC-convertible** — subclasses an Obj-C base and reads/writes only
   scalar/object base ivars, off the per-sample hot path. Reached with
   `value(forKey:)`/`setValue(_:forKey:)` (relies on
   `accessInstanceVariablesDirectly`, default YES). Never viable on
   per-sample DSP paths (string-keyed lookup is too slow) or for
   C-struct/array/`void*` ivars.
3. **Blocked** — subclasses an Obj-C base and accesses C-struct/array/`void*`
   ivars per-sample. This was most of the modem signal path (receivers,
   demodulators, modulators, matched filters, configs).

Tier 3 was unblocked by converting **bottom-up, one whole inheritance tree at
a time** — the moment a base becomes Swift, its Obj-C subclasses stop
compiling (Obj-C can't subclass Swift), so an entire tree had to convert
together in one wave: `CoreFilter` C kernels stayed C (Swift calls them
fine, no conversion needed); `CMPipe`→`CMTappedPipe`→(`CMFilter`, `CMNCO`,
`DestClient`, …) — the ~75-class DSP pipe framework — converted as one
coordinated migration; then `Modem`→`MacroInterface`→`ContestInterface`→
per-mode receiver/modulator/demod/config trees; then
`StripPhi`→`Contest`→`RSTExchange` and the contest-exchange classes.

Other lessons banked along the way:

- Porting numeric C to Swift 1:1 is unsafe — Swift's checked
  arithmetic/conversions **trap** where C silently wraps or truncates. Any
  bit/fixed-point math needs guarded conversions and wrapping operators
  (`&+`, `&<<`, `UInt32(bitPattern:)`).
- **Bridging-header leak:** the generated `cocoaModem-Swift.h` re-imports
  the bridging header, so everything in it becomes visible to every Obj-C
  file that imports the Swift header. Adding a base header could surface
  latent duplicate file-scope `enum`/`typedef` definitions between unrelated
  modem modes (a real, if quiet, correctness bug in the original codebase) —
  fixed by removing the redundant local copy, not by hiding the header.
- The pre-Interface-Builder-3 `.nib` bundles still load fine under modern
  AppKit (`keyedobjects.nib` is the runtime format ibtool/AppKit still
  understand) but can no longer be *edited* in modern Xcode's Interface
  Builder.
