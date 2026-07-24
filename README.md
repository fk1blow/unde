# unde

A native macOS clipboard & snippet manager. *unde* is Romanian for **where** —
as in "where did that thing I copied go." A global hotkey brings up a picker;
Enter (or ⌘1–9 for a pinned snippet) pastes straight into the app you were in.

- **Platform:** macOS 14+, Apple Silicon + Intel
- **Stack:** Swift, AppKit shell + SwiftUI rows, no third-party runtime
- **Status:** M0 verified; M1–M5 (the complete product) code-complete, pending
  on-device verification. See [docs/CHECKLIST.md](docs/CHECKLIST.md).

## Build & run

```bash
swift build                      # compile check
./scripts/build_app.sh release   # assemble build/unde.app + ad-hoc sign
open build/unde.app              # menu bar item appears, no Dock icon
```

First launch prompts for **Accessibility** — required for auto-paste. Grant it in
System Settings → Privacy & Security → Accessibility.

## Docs

- [docs/PRD.md](docs/PRD.md) — product requirements
- [docs/PLAN.md](docs/PLAN.md) — implementation plan, milestones M0–M7
- [docs/CHECKLIST.md](docs/CHECKLIST.md) — **resume point**, per-stage checklist

## Layout

```
Sources/unde/
  App/        main, AppDelegate, MenuBarController
  Clipboard/  ClipboardItem, HistoryStore, PasteboardMonitor, Paster, SecureInput
  Snippets/   Snippet, SnippetStore
  Picker/     PickerPanel, PickerController, PickerView, PickerModel, FuzzyMatcher, DesignTokens
  Hotkey/     HotKey (Carbon)
  Settings/   SettingsWindowController, SettingsView, KeyCombo+Display
  Support/    Preferences, Permissions, LaunchAtLogin, NoticePresenter
```
