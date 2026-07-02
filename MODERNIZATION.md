# cocoaModem 2.0 — Modernization Status

cocoaModem 2.0 (Kok Chen, W7AY) — amateur-radio digital-mode modem app,
originally written 2004–2009 in manual-retain-release Objective-C (~88k lines,
~270 source files, 19 modem modes). This repo tracks its conversion to Swift
and modern macOS.

## Done

- **Builds and runs on modern macOS** (macOS 14+ deployment target, built with
  the macOS 26 SDK), universal arm64 + x86_64 binary.
  - Legacy vecLib calls renamed to modern `vDSP_*` API (`conv`→`vDSP_conv`,
    `ctoz`→`vDSP_ctoz`, `create_fftsetup`→`vDSP_create_fftsetup`, …);
    `COMPLEX`/`COMPLEX_SPLIT` → `DSPComplex`/`DSPSplitComplex`.
  - Links `Accelerate.framework` (direct vecLib linkage is no longer allowed).
  - Missing includes added (`IOPMLib.h`, `sys/ioctl.h`, …); project-local
    angled includes quoted; two file-local `CWPipeline` structs renamed to
    avoid colliding with the `CWPipeline` class (fragile-ABI era code).
  - `NSMicrophoneUsageDescription` added (audio input requires it now).
  - Build settings modernized in place (old objectVersion-42 project still
    opens fine in current Xcode).
- **Old nibs still work.** The pre-Interface Builder 3 `.nib` bundles contain
  `keyedobjects.nib` (the runtime format); modern ibtool compiles them into
  the bundle and AppKit loads them, dark mode included. They cannot be
  *edited* in modern Xcode — long-term they should be rebuilt as code or
  SwiftUI, window by window.
- **Mixed Swift/Obj-C target works.** Swift 5 settings + bridging header
  (`cocoaModem 2.0/cocoaModem-Bridging-Header.h`); Obj-C sees Swift classes
  via the generated `cocoaModem-Swift.h`. Module name: `cocoaModem`.

## Swift conversion — how it works

Converted classes live under `Sources/Swift/…` mirroring the old layout.
Ground rules (see `Sources/Swift/Application/UTC.swift` for the pattern):

1. `@objc(OriginalName)` on every converted class — nibs instantiate classes
   by name and old code messages them by selector.
2. Selectors and C types must match the original `.h` exactly
   (`@objc(originalSelector:)` where Swift naming differs).
3. Nib-connected ivars stay KVC-compatible: `@objc var name: NSTextField!`
   with the exact original ivar name; actions are `@objc func name(_: Any?)`.
4. MRC `dealloc` → `deinit`; malloc'd/CF resources still freed explicitly.
5. Obj-C files that imported a converted header import
   `"cocoaModem-Swift.h"` instead; headers use `@class X ;` forward decls.
   Every importer must be updated or you get duplicate-interface errors.
6. Superclasses can't be converted before their Obj-C subclasses
   (Obj-C can't inherit from Swift). Convert leaves of the class tree first.
7. `tools/pbx_swift.py add <path>` adds a Swift file to the project;
   `tools/pbx_swift.py remove-m <File.m>` retires the old implementation.
   Keep the build green after each batch; launch the app as a smoke test.

## Remaining work (rough order)

- [ ] Application layer: Speech (consider AVSpeechSynthesizer), AppDelegate,
      Application.m (1.4k lines, central controller — do late).
- [ ] Categories, QSO, Preferences, Interface Managers.
- [ ] Audio layer (AudioManager and friends still use pre-10.6 CoreAudio
      `AudioDeviceGetProperty` API — works but deprecated; migrate to
      `AudioObjectGetPropertyData` during conversion).
- [ ] Modems (19 modes; DSP-heavy — convert carefully with A/B listening
      tests, or keep the C DSP kernels in `Sources/Filters` as C, which is
      fine from Swift).
- [ ] PTT/serial, NetAudio, Interfaces, Contest layers.
- [ ] Rebuild nibs as modern UI (only after their controller classes are
      Swift), then drop the deprecated-format nibs.
- [ ] Replace remaining deprecated AppKit calls (NSCalibratedRGBColor-era
      color APIs, `initWithPath:`-style NSSound, NSSpeechSynthesizer, …).
- [ ] App sandbox/hardened runtime + real code signing for distribution.

## Build

```sh
cd "cocoaModem 2.0"
xcodebuild -project "cocoaModem 2.0.xcodeproj" -target "cocoaModem 2.0" \
           -configuration Release build
```

The auxiliary `CreateFont` and `AppleScript Tests` projects are historical
tooling and are not part of the modernization.
