# TODO — Picker selection & search UX

Small polish batch from dogfooding on a MacBook trackpad. Grounded in the current
picker code (`Sources/unde/Picker/`), not a redesign. Four items; #3 (hover) and #4
(input shift) are the real ones.

Legend: `[x]` done · `[~]` code-complete, unverified · `[ ]` not started

**Status:** #1–#3 done and verified on-device (hover-jitter fix confirmed). #4 added
after dogfooding, code-complete.

## Seams

| Concern | File | What's there today |
|---------|------|--------------------|
| Open state | `Picker/PickerController.swift` `show()` (98-100) | `query = ""`, `selection = 0`, `anchor = 0` |
| Navigable list | `Picker/PickerModel.swift` (114) | `allRows = pinnedRows + clipRows` — index 0 is first pinned, else first clip |
| Section labels | `Picker/PickerView.swift` (188, 196) | `"Pinned snippets"`, `"Clipboard history"` |
| Type-to-filter | `Picker/PickerController.swift` (639-647) | appends char, resets `selection`/`anchor` to 0, `rebuildRows()` |
| Backspace | `Picker/PickerController.swift` (616-624) | `removeLast()` + `rebuildRows()` — **no reset**, only `clampSelection()` (311-315) |
| Hover → selection | `Picker/PickerView.swift` (428) → `PickerController.swift` `onHoverRow` (45-53) | `.onHover` sets `selection = index`, `anchor = index` |

---

## 1. Open with the first item selected — CONFIRM

- [x] `show()` already sets `selection = 0`; `allRows` is `pinned + clips`, so the
  default focus is the first pinned snippet, or the first history item when nothing
  is pinned. This is already the desired behavior.
- [ ] **Verify on-device:** open with pins present → first pin selected; open with
  no pins → first history item selected. Lock it in with a note so it isn't
  regressed by the hover work below.

## 2. Shorten the section labels — TRIVIAL

- [~] `PickerView.swift:187` — `"Pinned snippets"` → `"Pinned"`.
- [~] `PickerView.swift:196` — `"Clipboard history"` → `"History"`.
- The surrounding context already makes "snippets"/"clipboard" redundant.
- Consider whether the search placeholder (`"Search snippets and clipboard…"`,
  `PickerView.swift:147`) should follow suit — out of scope unless it reads odd
  next to the shorter headers.

## 3. Selection stops chasing the pointer — THE REAL ONE

**Symptom:** search for an item, but the selected row ends up "way down" because a
trackpad touch / result reflow moved the highlight off the top match.

**Root cause is NOT the reset.** Typing already resets `selection` to 0
(`639-647`). The problem is that **hover writes selection** (`onHoverRow`,
`45-53`). The race, per keystroke:

1. key → `selection = 0`
2. `rebuildRows()` → list re-renders, rows reflow **under the stationary pointer**
   (and/or an incidental trackpad brush moves it)
3. SwiftUI fires `.onHover` on the row now under the cursor
4. `onHoverRow` overwrites `selection` → lands "way down"

The reset already ran in step 1; hover wins in step 4. Resetting harder cannot fix
this.

### 3a. Suppress hover-jitter (headline fix)

Only let hover change selection on **deliberate pointer movement**, not on content
moving under a still cursor. This is what native macOS menus do.

- [~] Implemented via a `hoverAnchor: NSPoint?` guard on `PickerController`:
  - Armed (`= NSEvent.mouseLocation`) on every open (`show()`) and on every handled
    keystroke (event monitor), so the ensuing reflow/selection change is protected.
  - `onHoverRow` no-ops while `hoverAnchor` is set, until the pointer moves past
    `hoverWakeThreshold` (4pt) from the anchor — a deliberate move — which clears the
    guard and resumes normal hover-driven selection.
- [~] Left the existing `suppressAutoScroll` handshake (`PickerView.swift:216-223`)
  untouched — it suppresses *scrolling* on hover; this new guard suppresses the
  *selection write*. They stay independent.

### 3b. Make query-change reset uniform (finish what's started)

- [~] Backspace (`kVK_Delete` case) now resets `selection`/`anchor` to 0 like typing
  and ⌥⌫/⌘⌫ already do, so **any** query mutation snaps the highlight to the first
  result. Previously it only clamped.
- [~] With 3a in place, this reset now sticks (no hover stealing it back).

### Verify (3)

- [x] Type a query while resting a finger on the trackpad → highlight stays on the
  top match, does not jump to a row under the pointer.
- [x] Move the mouse deliberately onto a row → hover selection still works.
- [x] Backspace through a query → highlight stays on the first result at each step.
- [x] Keyboard up/down after a search → still scrolls into view (unchanged).

Fix landed as a `hoverAnchor` guard in `PickerController` plus swapping the row's
`.onHover` for `.onContinuousHover` (`PickerView.swift`) — `.onHover` is edge-triggered
and only fires on row-boundary crossings, which left the row already under the cursor
unselectable until you exited and re-entered it; `.onContinuousHover` fires on movement
within a row too, so the guard wakes on any deliberate move.

---

## 4. Search input stops shifting on `#`-tag entry — DONE

**Symptom:** typing a `#` tag forms a scope pill, and the whole search/input row
jumps down a few points.

**Cause:** the search row had no fixed height, so it sized to its tallest child. The
`ScopePill` (14pt text + `.padding(.vertical, 3)` ≈ 23pt) is taller than the bare
query text + caret (~20pt), so forming the pill grew the row and — since it sits at
the top of the fixed-height card — shoved the divider and list below it down.

- [x] Pin the search row to a constant `.frame(height: 24)` (`PickerView.swift`,
  `searchRow`), fitting the tallest state (the pill) so the pill-vs-text swap can no
  longer reflow the row.

## 5. Smaller search input text — DONE

Search placeholder + typed query were 17pt, oversized next to the 14pt rows.

- [x] Placeholder and typed query → 15pt (kept equal so the empty→typing transition
  doesn't jump); caret height 20 → 18pt to match (`PickerView.swift`).
