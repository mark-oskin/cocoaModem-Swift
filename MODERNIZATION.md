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

## Converted so far (17 classes, all committed, build green)

- Application: UTC, splash, splashPanel, ModemColor, VoiceAssistTextField,
  SleepManager, ModemSleepManager, MacroNode, MacroScripts, MacroMenu,
  UserInfo, Speech (faithful NSSpeechSynthesizer port — TODO AVSpeechSynthesizer).
- About: About, AboutView.  Instrumentation: DisplayColor.
  Preferences: SubDictionary.  QSO: QSO (`@objc(QSO) : StripPhi`, base stays ObjC).

Lesson banked (see DisplayColor): porting numeric C to Swift 1:1 is unsafe —
Swift's checked arithmetic/conversions TRAP where C silently wraps/truncates.
Use guarded conversions + wrapping operators (`&+`, `&<<`, `UInt32(bitPattern:)`)
for any bit/fixed-point math, and always launch-test after a batch.

Blocked until their Obj-C subclasses convert first (ObjC can't subclass Swift):
StripPhi (sub: ContestBar, Contest), Preferences (sub: Config).

### Wave process (tools/hierarchy.py + tools/pbx_swift.py)

- `tools/hierarchy.py leaves` lists classes whose Obj-C subclasses are already
  gone — safe to convert now. Convert an entire inheritance subtree in one wave
  (Swift resolves intra-module refs regardless of file order); a Swift class may
  subclass a still-Obj-C base.
- Per wave: add the wave's Obj-C base headers to the bridging header centrally,
  dispatch agents (they write Swift + swap importers, and REPORT—not edit—shared
  headers), then `pbx_swift.py add/remove-m/purge`, delete old files, build
  Debug, **launch-test**, commit.
- **Bridging-header leak (important):** the generated `cocoaModem-Swift.h`
  re-imports the bridging header, so everything in the bridging header is visible
  in every Obj-C file that imports the Swift header. Adding a base header can
  therefore surface latent duplicate file-scope `enum`/`typedef`/global
  definitions (e.g. PSKReceiver.m redefined RTTYReceiver.h's `enum
  LockCondition`). These are real bugs — fix by removing the redundant local
  copy. Keep the bridging header no larger than needed; remove a base header
  once that base itself becomes Swift.
- The deep DSP spine (CMPipe 105 desc → CMTappedPipe 75 → DestClient/Modem →
  the mode trees) converts LAST, or stays Obj-C/C permanently (fine in a mixed
  target; the C kernels in Sources/Filters need not become Swift).

## Remaining work (rough order)

- [ ] Application layer: AppDelegate (NSScriptCommand/scripting),
      Application.m (1.4k lines, central controller — do late).
- [ ] Interface Managers, Interfaces, Contest (44 files, interconnected).
- [ ] Instrumentation waterfalls/scopes (UI bitmap drawing — same overflow
      risk class as DisplayColor; convert carefully, verify visually).
- [ ] **Modems — 156 files, DSP signal path. HIGHEST RISK.** Demodulation
      correctness cannot be validated without a radio + audio input; a launch
      test only proves it doesn't crash. Convert incrementally WITH on-air /
      recorded-signal A/B testing, or leave as working Obj-C/C — a mixed-language
      target is fine and the C DSP kernels (Sources/Filters) need not become Swift.
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
