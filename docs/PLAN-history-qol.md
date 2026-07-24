# Implementation Plan — History QoL: Retention & Kind Filters

Derived from [PRD-history-qol.md](PRD-history-qol.md). Two features, sequenced
so the first ships and gets dogfooded before the second is touched.

- **H1 — Retention window** (Feature A). No picker changes; pure storage +
  one setting. Directly answers "history gets big fast."
- **H2 — Kind filters** (Feature B). Picker query grammar + a select-all gesture.

Grounded in the current code, not a greenfield design. The relevant seams already
exist:

| Seam | File | What's there today |
|------|------|--------------------|
| Count eviction | `Storage/HistoryRepository.swift` | `evict(keeping:)` — SELECT doomed image paths, delete files, delete rows. H1 mirrors this for age. |
| In-memory list | `Clipboard/HistoryStore.swift` | `insert` enforces the cap; `remove(ids:)`, `clear()` already prune + mirror. H1 adds an age prune here. |
| Prefs | `Support/Preferences.swift` | Typed UserDefaults wrapper, one property per key. H1 adds `retentionDays`. |
| Settings UI | `Settings/SettingsView.swift` | `Section("Clipboard")` with the file-mode `Picker`. H1 adds a sibling picker. |
| Query → rows | `Picker/PickerController.swift` `rebuildRows()` | Trims the query, fuzzy-filters `history.items` and `snippets.ordered`. H2 parses a leading scope token here. |
| Key handling | `Picker/PickerController.swift` `handleKeyDown` | Owns every key. H2 adds `⌘A` (select-all) and Tab (token-complete). |
| Selection model | `Picker/PickerModel.swift` | `selection`/`anchor`/`selectionRange`, `countLabel`. H2 extends the label and adds a scope field. |

---

## H1 — Retention window *(~3h)*

### Storage — `HistoryRepository`

Add an age sibling to `evict(keeping:)`, following its exact shape (gather doomed
image paths, delete the files, then delete the rows):

```swift
/// Evict every item older than `cutoff`, cleaning up backing image files (RET-3).
func evict(olderThan cutoff: Date) {
    let ts = cutoff.timeIntervalSince1970
    let doomed = (try? db.query(
        "SELECT image_path FROM history_item WHERE created_at < ?;",
        [.double(ts)]) { $0.text(0) }) ?? []
    for path in doomed.compactMap({ $0 }) { imageStore.delete(path: path) }
    try? db.execute("DELETE FROM history_item WHERE created_at < ?;", [.double(ts)])
}
```

No schema migration — `created_at` and `idx_history_created` already exist.

### In-memory — `HistoryStore`

The store owns the array the UI reads, so it must prune in memory too, not just on
disk. Add:

```swift
/// Drop items older than the retention window (RET-3, RET-6). No-op when the
/// window is "forever" (retentionDays == 0). Returns whether anything changed.
@discardableResult
func evictExpired(olderThan cutoff: Date) -> Bool {
    let before = items.count
    items.removeAll { $0.createdAt < cutoff }
    let changed = items.count != before
    if changed { repository?.evictExpired... }  // mirror; or call repo.evict(olderThan:)
    return changed
}
```

Call sites (RET-5):
1. **Launch** — after the warm `loadRecent`, in `init`, run one pass with the
   current window.
2. **On insert** — at the top of `insert(_:)`, cheaply prune expired before adding.
   This is the "you're actively copying, so the pass runs" case and covers the
   overwhelming majority of real transitions.
3. **On preference change** — see below.

The window (days) is supplied by the owner (`AppDelegate`) rather than read inside
the store, keeping `HistoryStore` free of a `Preferences` dependency. Simplest:
pass a `retentionDays` value or a `() -> Date?` cutoff provider into the store, or
have `AppDelegate` call `evictExpired(olderThan:)` with a computed cutoff.

### Preference — `Preferences`

```swift
private static let retentionDaysKey = "retentionDays"   // 0 == forever

/// Days to keep history; 0 means forever (RET-1, RET-2). Default 0.
var retentionDays: Int {
    get { defaults.integer(forKey: Key.retentionDays) }   // absent → 0 → forever
    set { defaults.set(newValue, forKey: Key.retentionDays) }
}

/// The cutoff instant, or nil when retention is off.
func retentionCutoff(now: Date = Date()) -> Date? {
    retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 86_400) : nil
}
```

Default **0 / forever** satisfies RET-2 without a `register(defaults:)` entry
(absent key reads as 0). Add the raw value to the allowed set `{0,1,7,30,90}` only
implicitly via the picker — no validation needed for a personal tool.

### Settings — `SettingsView`

Add to the existing `Section("Clipboard")`, below the file-mode picker:

```swift
Picker("Keep history for", selection: $retentionDays) {
    Text("Forever").tag(0)
    Text("1 day").tag(1)
    Text("7 days").tag(7)
    Text("30 days").tag(30)
    Text("90 days").tag(90)
}
.onChange(of: retentionDays) { newValue in
    prefs.retentionDays = newValue
    onRetentionChange(newValue)   // RET-9: prune immediately with the new window
}
```

`onRetentionChange` is a new closure wired like the existing `onHotKeyChange`,
routed to `AppDelegate` → `HistoryStore.evictExpired`. Add a `@State private var
retentionDays` initialised from `prefs.retentionDays`.

### Wiring — `AppDelegate`

- Own the "prune now" call: a small `pruneHistory()` that computes
  `prefs.retentionCutoff()` and calls `history.evictExpired(olderThan:)` when
  non-nil.
- Call it at launch (after stores are built) and from the settings `onRetentionChange`.
- Optional timer (RET-5, Open Question 2): only if a lingering stale item is ever
  observed. Skip for v1.

**Done when:** set "7 days" in Settings; an item with a `created_at` older than a
week vanishes from both the open picker and the DB, its image file is gone from
disk, pinned snippets are untouched, and re-copying an old item resets its clock so
it survives.

**Watch for:**
- RET-8: pruning while the picker is open must not dangle selection. The picker
  already live-refreshes on `history.$items` and `rebuildRows()` clamps
  `selection`/`anchor` past the end — verify the clamp covers a mid-list removal,
  not just a shrink from the tail.
- The on-insert prune runs on the capture path (main run loop); a `DELETE … WHERE
  created_at < ?` against an indexed column over ≤2000 rows is sub-millisecond, but
  don't add a second full-table scan per keystroke — prune on *insert*, not on
  *filter*.
- RET-9 "shorter window applies now, Forever doesn't resurrect": eviction is
  one-directional deletion; nothing to undo. Just ensure the change fires one prune.

---

## H2 — Kind filters (`#` tokens) *(~5h)*

Ships after H1 has been used for a few days. All of this lives in the picker; no
storage changes.

### 1. Parse the scope — `PickerController.rebuildRows()`

Introduce a tiny value type and a parser. Keep it isolated so future scopes
(`app:`, `before:`) are additions, not a rewrite (PRD Open Question 4):

```swift
enum QueryScope: String, CaseIterable {
    case text, image, file, link, pinned
    var token: String { "#\(rawValue)" }
}

struct ParsedQuery {
    var scope: QueryScope?      // nil = no scope
    var text: String            // remaining fuzzy query
    var completing: String?     // non-nil while typing a partial token (FLT-5)
}
```

Parse rule (FLT-1, FLT-4): split the query on first whitespace. If word 1 starts
with `#`:
- exact match to a known token → set `scope`, `text` = the rest;
- a *prefix* of one or more tokens with no trailing space yet → `completing` = the
  partial (drives the autocomplete list);
- otherwise (unknown, e.g. `#ff0000`) → **not** a scope; the whole string is
  literal `text`. This is the escape hatch that keeps real `#` content searchable.

`rebuildRows` then:
- filters `history.items` by `scope` before the existing fuzzy pass
  (`#image` → `kind == .image`; `#link` → `classification == "link"`;
  `#pinned` → empty history, keep snippets);
- fuzzy-filters the scoped set with `ParsedQuery.text` exactly as today;
- when `completing != nil`, bypasses rows entirely and renders token suggestions
  (see step 3).

### 2. Show the active scope — `PickerModel` + `PickerView`

- Add `@Published var scope: QueryScope?` to the model, set by `rebuildRows`.
- `PickerView` renders a small pill in the search field when `scope != nil`
  (FLT-6), using the existing `DesignTokens`.
- Extend `countLabel` (FLT-7): `scope`-aware — "3 images", "No files". The
  singular/plural helper already exists; add a per-scope noun.

### 3. Token autocomplete — `PickerView`

When `ParsedQuery.completing` is set (FLT-5), the list area shows the matching
tokens as selectable rows instead of results. Reuse the row selection machinery:
`selection`/arrows already move a highlight; Tab or Enter completes the highlighted
token into the query (append the token + a space, then re-parse). This is the
whole discoverability story — typing `#` lists the five scopes.

Minimal-risk first cut: render suggestions as plain rows in the existing list;
Tab/Enter on a suggestion rewrites `model.query`. No new panel.

### 4. Select-all — `PickerController.handleKeyDown`

Add under the `cmd` branch (FLT-9, FLT-10):

```swift
if chars == "a" { selectAllVisible(); return true }
```

```swift
private func selectAllVisible() {
    let n = model.count
    guard n > 0 else { return }
    model.anchor = 0
    model.selection = n - 1     // range 0...n-1 = every listed row
}
```

Because `rebuildRows` has already narrowed `pinnedRows`/`clipRows` to the scope,
"all visible" is automatically scope-respecting — `⌘A` after `#image` selects only
images. `deleteSelected` (already built) then handles the removal, image-file
cleanup, and selection clamping (FLT-10).

### 5. Token-complete key — `handleKeyDown`

Add Tab handling: when a suggestion is highlighted (`completing != nil`), Tab
completes it; otherwise Tab is swallowed (the picker has no other tab use). Enter
in completing-mode completes rather than pastes.

**Done when:**
- Typing `#` lists the five scopes; arrow + Tab completes one.
- `#image` narrows to images with a visible `[image]` pill and an "N images" count;
  `⌘A` then `⌘⌫` clears exactly those images.
- `#file report` shows only files matching "report".
- Copying `#ff0000` or `#include <stdio.h>` and searching finds the literal text
  (FLT-4) — no empty image scope.
- Backspacing the token restores the full list with no residual pill (FLT-8).

**Watch for:**
- FLT-4 ordering: check the exact-token match *before* treating `#…` as a partial,
  and the partial before falling through to literal — get the precedence wrong and
  either `#ff0000` gets eaten or `#im` never suggests.
- The type-to-filter path in `handleKeyDown` appends printable chars including `#`
  and letters — no change needed there; parsing happens in `rebuildRows`. Don't
  intercept `#` at the keystroke layer.
- `#pinned` + `⌘A` + `⌘⌫` deletes snippets (FLT-11). Confirm it routes through
  `snippets.delete` (it does, via `deleteSelected`). Revisit the confirmation
  question (PRD OQ3) only after feeling it.
- Count label and empty-state strings are user-facing polish; wire them or the
  scope feels half-done ("0 results" under an `#image` pill reads as broken).

---

## Test plan

Unit-testable without ceremony (add to `Tests/undeTests/LogicTests.swift`):

**H1:**
- `evict(olderThan:)` removes only rows past the cutoff, keeps the rest.
- `evictExpired` prunes the in-memory array and returns changed correctly.
- `retentionCutoff(now:)` is nil at 0, and `now − N·86400` otherwise.
- Re-copy (upsert bumps `created_at`) rescues an item that was about to expire.

**H2:**
- Query parser: `#image x` → (.image, "x"); `#img` → completing; `#ff0000` →
  (nil, "#ff0000", literal); `#pinned` → (.pinned, ""); leading spaces tolerated.
- Scope filtering picks the right `Kind` / `classification` subset.
- `selectAllVisible` produces `selectionRange == 0...(count-1)`.

Manual checklist:

- H1: set each window value, confirm eviction boundary, image-file cleanup, pinned
  untouched, open-picker refresh, upgrade-with-existing-history is a no-op at
  Forever.
- H2: the four `Done when` bullets above, plus `#link` picks up URLs, and the pill
  scales with the UI-scale pref.

---

## Effort summary

| Feature | Estimate |
|---------|----------|
| H1 Retention window | ~3h |
| — *ship; dogfood a few days* — | |
| H2 Kind filters + select-all | ~5h |

H1 is the higher-value, lower-risk half and stands alone — it needs no picker
changes and directly closes the "history gets big fast" complaint. H2 is the
ergonomic payoff on top, and its cost is mostly in the autocomplete/pill polish
that makes the mode discoverable rather than in the filtering itself.
