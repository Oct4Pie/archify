# Changelog

## 1.5.0

### Security

- Every change to an app in /Applications now requires administrator approval, which the helper verifies before acting.
- The helper accepts connections only from Archify signed by the same developer. On macOS 12 the check uses the connecting process's audit token instead of its process ID.
- The helper can only optimize apps and remove language folders. Its older file operations that accepted any path are gone.
- Helper paths are checked without following symbolic links, and requests outside the app being changed are refused.
- The helper exits when idle, so no root process lingers and an updated helper is used from the next operation.
- The Archify 1.4 helper is replaced automatically, with no restart or logout.

### Safer optimization

- Optimization is transactional: each app is changed with an atomic swap and rolled back on any failure. If macOS blocks a change, nothing is changed.
- Files sealed by an app's signature are left alone, so optimized apps keep a valid signature and stay notarized.
- Open apps are detected before changes. Archify offers to quit them, or skips them.
- Optimize Apps, Languages, scans and size calculations can be paused, resumed or canceled.
- Optimize App never overwrites an existing app. It offers Keep Both or Replace (which moves the old copy to the Trash).

### Permissions

- Full Disk Access is no longer required at launch. It is requested only when macOS protects an app from changes, with step-by-step guidance and a direct link to the setting. This fixes repeated Full Disk Access prompts on some Macs (#15).
- Helper approval opens Login Items and continues on its own once you approve it. On macOS 13 and later the helper is listed under Archify's name (#13).

### Languages

- A redesigned Languages screen: pick languages, review the affected apps, and see how much space each choice frees.
- Your preferred languages and each app's development language are always kept. Language folders that an app's signature requires are never removed.

### Apps and architectures

- A redesigned interface with Optimize App, Optimize Apps, Space Savings, Languages and Installed Apps.
- More accurate architecture detection, including apps with nonstandard layouts, arm64e and x86_64h (#12).
- Detects the real Mac architecture when running under Rosetta.
- Faster scanning.
- Universal build for Apple Silicon and Intel, macOS 12 or later.
- Remembers the window's size and position.

### Updates

- Automatic updates through Sparkle, with signed archives and a signed update feed (#14). Updating from 1.4 requires one manual install of 1.5.

### Command-line tool

- Transactional optimization that keeps sealed files, the same as the app.
- Never overwrites an existing app at the destination.
- Apps without entitlements are no longer reported as signing failures.

### Removed

- The bundled LDID source. LDID signing now uses an `ldid` you install, for example with `brew install ldid`.

## 1.4.0

- Signed with a Developer ID certificate, fixing an XPC vulnerability in the helper.
- Helper stability improvements.
- Full Disk Access checks.
- Optimizations and bug fixes.

## 1.3.1

- Fixed a Full Disk Access bug (#4).

## 1.3.0

- Performance improvements.
- Full Disk Access fixes.
- Helper versioning and app view improvements.

## 1.2.0

- Language cleaner.
- Batch processing.
- Privileged helper.
- Universal apps view.

## 1.1.0

- App processing, architecture size calculation, signing and entitlement options in the app.
- Architecture calculations, ad-hoc signing and entitlement options in the command-line tool.

## 1.0.0

- Initial command-line release.
