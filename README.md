# Yank

A Paste-style clipboard manager for macOS 26 and later. Menu bar only, sandboxed, no sync. The full
spec is the plan in the project thread; this README covers building, testing and what we learned.

## Build and run

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen                     # creates Yank.xcodeproj from project.yml (it is not committed)
open Yank.xcodeproj          # then press ⌘R in Xcode, or:
xcodebuild -scheme Yank -derivedDataPath build -destination 'platform=macOS,arch=arm64' build
open build/Build/Products/Debug/Yank.app
```

`project.yml` is the source of truth for targets, build settings, signing and dependencies. Change it,
not the Xcode project, then run `xcodegen` again. Adding or removing a Swift file also needs a rerun.

Signing uses the "Apple Development" certificate of team `ZT5VFPR74U`. A stable signature matters: macOS
ties permissions such as Accessibility to it, so an unsigned or ad hoc build loses them on every rebuild.

## Layout

| Path | What lives there |
| --- | --- |
| `App/` | The app target: windows, menu bar, panel. May import ClipCore, ClipSystem, SwiftUI, AppKit, KeyboardShortcuts. |
| `Packages/ClipCore/Sources/ClipCore` | Model, rules, storage, services, ports. Foundation, CryptoKit, os only; GRDB only in `Storage/`. |
| `Packages/ClipCore/Sources/ClipSystem` | Adapters that talk to macOS, implementing ClipCore's ports. |
| `AppUITests/` | XCTest UI tests that drive the real app. |
| `scripts/` | `test.sh`, `check-imports.sh`. |

## Code style

- **Comments teach.** The code is commented heavily on purpose. Every comment says what the code does,
  why it is needed and how it works, in simple plain English with no jargon, and relates Swift and macOS
  ideas to TypeScript, React/React Native and Android where that helps. A note about Swift syntax is
  allowed only as a short tail after that, never on its own. This replaces the plan's house rule 2
  ("comments only explain why") at the requester's request. New code follows the same style. Comments
  describe the code only: they never mention the plan, its stages or acceptance-criteria IDs.
- **Formatting:** `swift format` (bundled with Xcode). `.swift-format` sets 4-space indents and 110-column
  lines; JSON allows no comments, so it is explained here. Format with
  `swift format --in-place --recursive App AppUITests Packages/ClipCore`, check with `swift format lint`.

Logs: open Console.app and filter on subsystem `com.thattechedguy.Yank`, or run
`log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info`.

## Tests

```sh
scripts/test.sh --fast   # import check + package tests, a few seconds, no app launch
scripts/test.sh          # also the UI tests; quits a running Yank first and reopens it after
```

UI tests drive the real app and may write to your clipboard.

## Sandbox and copied files (stage 0 spike)

Question: when the user copies a file in Finder, can the sandboxed app, reading the clipboard on a timer
rather than through a user paste, use that file?

| Check | Result |
| --- | --- |
| `fileExists` / read the file's bytes | Works. 10 KB PDF and 20 MB HEIC in `~/Dev`, read in full. |
| Quick Look thumbnail (`QLThumbnailGenerator`) | Works. 396×512 for the PDF, 512×512 for the HEIC. |
| Write the URL back to the clipboard | Works. Pasting it into a Finder folder: not yet checked by hand. |
| Drag the file from our window to the Desktop | Works, but Finder **moved** the file instead of copying it. |

The file URL was put on the clipboard by another process (`osascript`), not by Finder itself, because this
Mac's automation can't press ⌘C in Finder. A file outside the container was readable anyway, so reading
the URL from the clipboard appears to give the app access to that file. The hand check of a real Finder ⌘C
was inconclusive (screen sharing replaced the clipboard with text); the stage 1 hand check repeats it.

**Decisions:**

- A file item stores the file's path, not a security-scoped bookmark. Revisit only if a real Finder copy
  in stage 1 can't be read.
- Dragging a card out (stage 8) must offer only the copy operation, so it never moves the user's file.
