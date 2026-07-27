# TODO — Picker compact chrome

Tighten the picker's "chrome" (the fixed search row on top and the status/footer
bar on the bottom) so more of the panel is results, less is frame. Panel stays a
fixed 420pt card — shrinking the chrome just gives the list more room.

Legend: `[x]` done · `[~]` code-complete, unverified · `[ ]` not started

## Inspiration (Raycast / Alfred / launchers)

- **Raycast** — polished but *heavy*: a leading magnifier glyph and a tall input
  (~44pt, 16pt body text), rounded card, 6px-padded rows. Reference, not target —
  we're going more compact than Raycast's main window.
- **Alfred** — the utilitarian/compact end: minimal chrome, no persistent footer
  bloat, the input is the smallest thing that works.
- **Our direction** — Alfred-ish density with our existing styling: drop the leading
  icon, shorten the input, slim the footer. A deliberate divergence from Raycast
  (which keeps the magnifier), matching the request.

Sources: [Raycast design tokens](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/raycast/DESIGN.md),
[Raycast vs Alfred](https://joshcollinsworth.com/blog/alfred-raycast).

## Seams (`Sources/unde/Picker/PickerView.swift`)

| Element | Where | Today |
|---------|-------|-------|
| Search row | `searchRow` | magnifier (16pt) + input + `esc`; content `frame(height: 24)`, `padding(.vertical, 15)` → ~54pt tall |
| Scope pill | `ScopePill` | 14pt text, `padding(.vertical, 3)` → ~23pt |
| Footer | `footer` | hints + count; content `frame(height: 20)`, `padding(.vertical, 14)` → ~48pt tall |

---

## 1. Remove the search icon — DONE

- [x] Dropped the `Image(systemName: "magnifyingglass")` from `searchRow`. Input
  aligns to the row's leading padding; nothing else referenced it.

## 2. Shorter search row — DONE

- [x] Content `frame(height: 24 → 22)` and `padding(.vertical, 15 → 10)` → ~54pt
  down to ~42pt.
- [x] `ScopePill` `padding(.vertical, 3 → 2)` so the pill still fits inside the
  shorter fixed height (keeps the `#`-tag no-shift property from the previous batch).

## 3. Slimmer footer / status bar — DONE

- [x] Content `frame(height: 20 → 16)` and `padding(.vertical, 14 → 9)` → ~48pt down
  to ~34pt. Hint font stays 11pt.

## 4. Selection styling — DONE

Added while dogfooding this branch.

- [x] Removed the selected-row border (the `strokeBorder` overlay in `PickerRow`) and
  deleted the now-unused `rowSelectedStroke` token.
- [x] Bumped `rowSelectedBG` `0x2B2741 → 0x332F4F` (a touch more contrast vs the
  `0x232532` surface) so the fill alone carries the selection now the outline is gone.

## 5. Panel corner radius — DONE

- [x] `radiusPanel` `14 → 10`, matching Raycast's card (`rounded.lg`, 10pt). Rows stay
  at `radiusRow` 8.

### Verify (on-device, this branch)

- [x] Search row shorter, no icon, input left-aligned and readable.
- [x] Typing a `#` tag doesn't shift the row (pill fits the fixed height).
- [x] Footer shorter, hints + count legible and not clipped.
- [x] Selected row reads clearly from the fill alone; no border.
- [x] Panel corners visibly tighter.

### Follow-up knobs (not doing)

- Row density: measured ~37pt vs Raycast ~40pt — already comparable, left as-is.
- Divider gaps (`padding(.bottom/.top, 4)` around the two `Divider()`s in `mainCard`)
  could tighten a few more points if it ever feels roomy.
