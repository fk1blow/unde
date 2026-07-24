# Implementation Plan — Slip

Derived from PRD.md. Sequenced so that a usable tool exists at M3 and everything after is refinement.

---

## 0. Decisions made up front

These are load-bearing and expensive to reverse. Settle them before writing code.

| Decision | Choice | Why |
|----------|--------|-----|
| UI framework | AppKit shell, SwiftUI rows | SwiftUI's macOS keyboard/focus handling is the framework's weakest area. Owning the event loop in AppKit avoids a category of unfixable jank. |
| Window type | `NSPanel`, `.nonactivatingPanel` | Keeps the previous app frontmost. Eliminates the activate/reactivate race entirely — no sleeps, no sequencing bugs. |
| Hotkey API | Carbon `RegisterEventHotKey` | Works with zero permissions. `NSEvent` global monitors require Accessibility, which is friction we're deferring. Deprecated in name only. |
| Persistence | SQLite via GRDB | Mature, synchronous-friendly, no Core Data ceremony. Single-file DB is easy to inspect and back up. |
| Search | In-memory fuzzy over loaded array | A few thousand short strings filter in well under a millisecond. FTS5 is premature until proven otherwise. |
| Dependencies | GRDB only | Every added dependency is launch time and audit surface. |
| Distribution | Local build, Developer ID signed | No App Store — sandboxing conflicts with global hotkeys and Accessibility. |
| Accessibility permission | Mandatory, requested at first run | Auto-paste is the product. Deferring the prompt only produces a confusing first failure. |

**Blocking prerequisite:** resolve PRD Open Question 4 (fork Maccy vs. build fresh). This plan assumes building fresh. If forking, M1–M3 collapse to roughly a day and the plan effectively starts at M4.

---

## 1. Project structure

```
Slip/
  App/
    AppDelegate.swift          — wiring, lifecycle, launch-at-login
    MenuBarController.swift    — NSStatusItem, menu
  Clipboard/
    PasteboardMonitor.swift    — polling loop, filtering, dedup
    PasteboardWriter.swift     — write + optional synthesised paste
    ClipboardItem.swift        — model
  Snippets/
    Snippet.swift
    SnippetStore.swift
  Storage/
    Database.swift             — GRDB setup, migrations
    HistoryRepository.swift
    ImageStore.swift           — content-hashed files on disk
  Picker/
    PickerPanel.swift          — NSPanel subclass, canBecomeKey
    PickerViewController.swift — event monitor, selection state
    PickerRootView.swift       — SwiftUI list
    RowView.swift
    FuzzyMatcher.swift
  Hotkey/
    HotKey.swift               — Carbon registration
    HotKeyRecorder.swift       — settings UI control
  Settings/
    SettingsWindow.swift
    GeneralPane.swift
    SnippetsPane.swift
    PrivacyPane.swift
  Support/
    Preferences.swift          — UserDefaults wrapper
    Permissions.swift          — Accessibility check + prompt
```

---

## 2. Data model

```sql
CREATE TABLE history_item (
    id            INTEGER PRIMARY KEY,
    kind          TEXT NOT NULL,        -- 'text' | 'image'
    content       TEXT,                 -- text payload, NULL for images
    image_path    TEXT,                 -- relative path in Application Support
    image_width   INTEGER,
    image_height  INTEGER,
    byte_size     INTEGER NOT NULL,
    content_hash  TEXT NOT NULL,        -- dedup key
    source_bundle TEXT,
    created_at    REAL NOT NULL,
    last_used_at  REAL
);
CREATE UNIQUE INDEX idx_history_hash ON history_item(content_hash);
CREATE INDEX idx_history_created ON history_item(created_at DESC);

CREATE TABLE snippet (
    id         INTEGER PRIMARY KEY,
    label      TEXT,
    content    TEXT NOT NULL,
    slot       INTEGER,                 -- 1..9, NULL if unslotted
    sort_order INTEGER NOT NULL,
    created_at REAL NOT NULL
);
CREATE UNIQUE INDEX idx_snippet_slot ON snippet(slot) WHERE slot IS NOT NULL;
```

Dedup via `content_hash` UNIQUE + upsert that bumps `created_at`. That gets CAP-5 for free at the storage layer rather than in application code.

`last_used_at` is unused in v1 but costs nothing now and enables frecency ranking later.

---

## 3. Milestones

### M0 — Skeleton *(~1h)*

Xcode app target. `LSUIElement = true`. Storyboard deleted, `NSApplicationDelegate` set manually. Status bar item appears with a quit menu item.

**Done when:** app runs, no Dock icon, menu bar item quits it.

---

### M1 — Hotkey *(~2h)*

`HotKey.swift` per the Carbon pattern: static handler table keyed by hotkey ID, single installed event handler, `RegisterEventHotKey` with `cmdKey | optionKey` and `kVK_ANSI_V`.

Verify from a non-frontmost state — register, switch to another app, press the combo, confirm the callback fires.

**Done when:** Cmd+Opt+V logs from any app. No permission dialogs have appeared.

**Watch for:** `EventHotKeyID.signature` must be a valid four-char OSType. Registration failure returns non-`noErr` and is silent otherwise — check the status code.

---

### M2 — Panel *(~4h)*

`PickerPanel: NSPanel` — style mask `[.nonactivatingPanel, .borderless]`, `level = .floating`, `override var canBecomeKey: Bool { true }`, `hidesOnDeactivate = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`.

Constructed once in `applicationDidFinishLaunching`. Shown with `orderFrontRegardless()` + `makeKey()`. Hidden with `orderOut(nil)` — **never** closed or deallocated.

Positioning: `NSScreen.screens` filtered by `frame.contains(NSEvent.mouseLocation)`, centred horizontally, top third vertically.

Dismissal: local `NSEvent` monitor for Escape, `windowDidResignKey` delegate callback, and the hotkey itself toggling.

**Done when:** hotkey toggles a visible empty panel. The frontmost app's title bar stays active-looking throughout. Panel appears on whichever display holds the cursor.

**Watch for:** a borderless panel needs `isMovableByWindowBackground = false` and explicit `acceptsFirstResponder` on the content view or keystrokes go nowhere.

---

### M3 — Monitor + list, in memory *(~6h)*

`PasteboardMonitor`: `Timer` at 0.15s on the main run loop, `.common` mode so it survives menu tracking. Compare `changeCount`, bail if unchanged. On change, check the type filter (CAP-3) and exclusion list (CAP-4) before reading contents.

Items into a plain `[ClipboardItem]` array. No database yet.

SwiftUI list in the panel. Selection index owned by the view controller, driven by the AppKit event monitor — not SwiftUI focus. Type-to-filter via a hidden `NSTextField` or by accumulating characters from the event monitor.

`FuzzyMatcher`: subsequence match with a simple scoring function (consecutive-run bonus, word-boundary bonus, earlier-match bonus). ~40 lines.

Enter writes the selected item to the pasteboard and hides the panel.

**Done when:** copy three things, hotkey, arrow to the second, Enter, Cmd+V, correct text lands.

Note this is *not* yet a useful tool — the manual Cmd+V is the thing the product exists to eliminate. Push straight through to M5 before evaluating anything.

---

### M4 — Auto-paste *(~5h)* — **the milestone that decides whether this project is worth finishing**

Everything before this is scaffolding. If synthetic paste can't be made reliable into a terminal, stop and reconsider the whole approach rather than building persistence on top of a broken core.

`AXIsProcessTrustedWithOptions` with the prompt option, run during first launch rather than lazily.

The sequence, and it is order-sensitive:

1. Write to `NSPasteboard.general`, note the resulting `changeCount`.
2. `orderOut` the panel.
3. Re-activate the stored frontmost app if it is no longer frontmost.
4. Post Cmd+V: `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `kVK_ANSI_V`, `flags = .maskCommand`, keydown then keyup, `post(tap: .cghidEventTap)`.
5. After ~500ms, restore the user's previous pasteboard contents (PST-5).

Use a `CGEventSource` with state `.hidSystemState` — a private source can behave inconsistently across apps.

Suppress self-capture (CAP-7): record the `changeCount` you caused and have the monitor skip that exact value.

**Secure Input** is not deferred to polish. Before step 4, call `IsSecureEventInputEnabled()`. If true, skip the synthetic event and surface a notice — a small overlay near the menu bar item reading "Secure Input active — press Cmd+V". Silent failure here is the single worst bug this app can have, because the user will conclude the app is broken and stop trusting it. To name the offending process, walk `CGSSessionCopyAllSessionProperties` or check for terminals with Secure Keyboard Entry enabled; if that proves fiddly, ship the unnamed version.

**Done when:** hotkey → Enter → text appears in Terminal.app, iTerm2, Ghostty, VS Code, and Safari's address bar, with no manual keypress. Then toggle Secure Keyboard Entry on in Terminal and confirm you get the notice rather than nothing.

**Watch for:** with the nonactivating panel the frontmost app never lost key status, so step 3 is usually a no-op — keep it anyway for Spaces switches and for the case where the source app quit while the panel was open. Also: some Electron apps need a few ms between panel hide and event post; if VS Code drops the first paste, insert a 10–20ms delay before step 4 and no more.

---

### M5 — Snippets *(~6h)*

Introduce GRDB here rather than at persistence — snippets must survive relaunch, and setting up `DatabaseMigrator` for one small table now means the history table is just a second migration later.

DB at `~/Library/Application Support/Slip/slip.sqlite`, `snippet` table only. Loaded at launch into a separate array, rendered as a pinned section above history, visually distinct, not reordered by filtering.

Cmd+1…Cmd+9 handled in the event monitor *before* filter-text accumulation — these fire regardless of what's been typed.

Cmd+P promotes the selected history item to a snippet, assigning the lowest free slot. Settings pane with add/edit/delete/reorder and a slot column.

**Done when:** Cmd+Opt+V then Cmd+1 puts "master schedule of works" into the terminal. Time the full round trip from hotkey press to text on screen.

**This is the complete product.** Stop here and use it for a week. M6 and M7 should be shaped by that week, and some of M7 will turn out to be unnecessary.

---

### M6 — History persistence *(~5h)*

Second migration adding `history_item`. Load the most recent 500 into memory at launch; writes go to DB and array both. Eviction on insert past the cap, image files cleaned up alongside.

`ImageStore`: SHA-256 of the image data as filename, PNG on disk, path in the row.

**Done when:** history survives quit and relaunch. DB stays under a few MB after a week of realistic use.

---

### M7 — Polish *(~6h)*

Privacy: exclusion list UI with app picker, pause toggle with auto-resume, Cmd+Delete for single-item delete, clear-all with confirmation, optional secret-pattern filter (off by default).

Secure Input follow-through: menu bar state indicator (SEC-5), first-run explanation of Secure Keyboard Entry (SEC-4), and naming the holding process (SEC-3) if it wasn't done at M4.

Hotkey recorder control. Launch at login via `SMAppService`. Shift+Enter plain-text paste, Cmd+Enter copy-without-paste. Image thumbnails in rows. Source app icons via `NSWorkspace.icon(forFile:)`, cached by bundle ID.

Sign with Developer ID, notarise if it'll ever move between machines. Note that re-signing resets the Accessibility grant — you'll re-authorise after each signing identity change, which is expected, not a bug.

---

## 4. Performance verification

Not vibes — measure at M3 and again at M7.

| Budget | How to verify |
|--------|---------------|
| Hotkey → visible < 50ms | `CFAbsoluteTimeGetCurrent()` at hotkey callback and in `viewDidAppear`. Log the delta. |
| Keystroke → filtered < 16ms | Time the filter function over a 2000-item array. |
| Idle CPU < 0.1% | Activity Monitor, one hour idle. |
| Cold launch < 500ms | `Instruments` App Launch template. |

If hotkey→visible exceeds budget, the cause is almost always view construction on show. Verify the hierarchy is genuinely built at launch and that `orderFront` isn't triggering a first SwiftUI render.

---

## 5. Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| **Secure Input blocks paste in terminals** | **High — will happen** | Detect via `IsSecureEventInputEnabled()`, always surface a notice. User can disable Secure Keyboard Entry in the terminal's menu. Handled at M4, not deferred. |
| **Synthetic Cmd+V unreliable in some target app** | Medium | Verify against the actual daily-driver apps at M4, before building anything on top. If a specific app resists, `CGEventPost` to `.cgAnnotatedSessionEventTap` sometimes works where `.cghidEventTap` doesn't. |
| Accessibility grant lost after rebuild/re-sign | High, low impact | Expected behaviour with changing signatures. Use a stable signing identity in development to reduce churn. |
| Carbon hotkey API finally removed | Low, long horizon | Isolated behind `HotKey`. Swap to `NSEvent` global monitor + Accessibility if it happens — permission is already granted. |
| Nonactivating panel misbehaves in full-screen apps | Medium | Test early against a full-screen editor. `.fullScreenAuxiliary` handles most of it. Fallback is normal activation with stored frontmost app. |
| SwiftUI list stutters at 500+ rows | Medium | Render only filtered results, cap displayed rows at ~50. Fallback is `NSTableView`. |
| Password manager not marking items concealed | Low, high impact | Exclusion list as belt-and-braces. Pre-populate 1Password, Bitwarden, Keychain Access. |
| Pasteboard restoration (PST-5) races the target app's read | Medium | 500ms delay is generous; make it configurable and disable-able if any app reads late. |
| Scope creep into a text-expansion engine | **High** | It's in Open Questions for a reason. v2 or never. |
| Polling misses fast successive copies | Low | 150ms is well below human copy cadence. Ignore unless observed. |

---

## 6. Test plan

Unit-testable without much ceremony: `FuzzyMatcher` scoring and ordering, dedup/upsert behaviour, eviction at the cap, exclusion-list matching, secret-pattern detection.

Manual checklist, run before calling any milestone done.

**Paste matrix — run at M4 and again after any change to the paste path:**

| Target app | Enter pastes | Cmd+1 snippet pastes | Secure Input notice |
|-----------|--------------|---------------------|--------------------|
| Terminal.app | | | ✓ (toggle Secure Keyboard Entry) |
| iTerm2 | | | ✓ |
| Ghostty | | | |
| VS Code | | | |
| Safari address bar | | | |
| Notes / TextEdit | | | |
| A focused password field anywhere | n/a | n/a | ✓ |

**General:**

- Copy from an excluded app → not captured
- Copy from 1Password → not captured
- Copy 2MB of text → rejected, no crash
- Copy an image → thumbnail renders, file lands on disk
- Hotkey while a full-screen app is frontmost → panel appears over it
- Hotkey on a second display → appears on the display with the cursor
- Escape, click-outside, and hotkey-again → all dismiss
- Quit and relaunch → history and snippets intact
- Paste, then Cmd+V manually a second later → previous clipboard contents restored (PST-5)
- Revoke Accessibility → banner appears, app doesn't crash, clipboard-set still works
- Source app quits while the picker is open → no crash, paste fails gracefully

---

## 7. Effort summary

| Milestone | Estimate | Cumulative |
|-----------|----------|------------|
| M0 Skeleton | 1h | 1h |
| M1 Hotkey | 2h | 3h |
| M2 Panel | 4h | 7h |
| M3 Monitor + list | 6h | 13h |
| M4 **Auto-paste** | 5h | 18h |
| M5 Snippets | 6h | 24h |
| — *complete product; dogfood one week* — | | |
| M6 History persistence | 5h | 29h |
| M7 Polish | 6h | 35h |

Roughly a week of focused work, or four weekends.

Two checkpoints matter more than the total. **M4** is the go/no-go: if synthetic paste into a terminal can't be made reliable, the remaining seventeen hours are wasted and the honest move is to stop. **M5** is the point at which the headline use case works end to end — hotkey, Cmd+1, phrase in the terminal. If a week of using it at M5 doesn't visibly change your behaviour, M6 and M7 won't change that either.
