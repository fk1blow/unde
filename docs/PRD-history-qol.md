# PRD — History QoL: Retention Window & Kind Filters

**Parent:** [PRD.md](PRD.md) — this is an addendum, not a replacement. IDs and
conventions carry over.
**Status:** Draft v1
**Scope:** Two features shipped in order — (A) an age-based retention window,
then (B) `#`-token kind filters in the picker.

---

## 1. Problem

History grows fast and stale. Today it is bounded only by *count* — 500 items by
default, evicting the oldest beyond that (`STO-2`). That keeps the database from
growing without limit, but it does nothing for the thing that actually makes the
list feel heavy: a copy from last Tuesday is still sitting there, indistinguishable
from one made a minute ago, until 500 newer items have pushed it out.

Two separate needs fall out of this:

1. **Passive freshness.** The list should forget things on its own, by age, so the
   author never has to think about pruning. Count is the wrong axis; time is the
   right one.
2. **Active pruning by kind.** Sometimes you want to sweep out a *class* of thing —
   "all the images I pasted while working on that doc" — on demand. The app already
   has the machinery to do this safely (filter → multi-select → `⌘⌫`); what's
   missing is a way to narrow the list to one kind so the selection is meaningful.

The rejected alternative — imperative slash commands like `/delete-images` typed
into the search field — fails on this product's terms: it overloads the single
most latency- and muscle-memory-critical control with a second, invisible mode; it
reserves `/`, a character that legitimately appears in copied paths and URLs; and
it commits a destructive bulk action against a target the user cannot see at the
moment they press Enter. Both features below keep the app's existing safety
property: **you see what you're about to remove before you remove it.**

## 2. Goals

1. History forgets stale items automatically, on an axis the author controls, with
   zero routine interaction.
2. The picker can be narrowed to a single kind of item in one token, composing with
   the delete gestures that already exist.
3. Neither feature adds a mode the author can enter by accident or a keystroke that
   silently changes what a familiar control does.
4. No destructive action without the target visible on screen first.

## 3. Non-goals

- Typed imperative commands (`/delete-images`, `/clear`) — explicitly rejected; see
  §1. A discoverable action menu, if ever wanted, is a separate future item.
- Per-item pinning/protection of history entries from age eviction. Snippets are
  already the "keep forever" mechanism (`STO-5`); promote to pin.
- Retention policies more complex than a single global window (no per-app,
  per-kind, or size-based retention).
- Full-text scope operators beyond kind (`app:`, `before:`, `size:>1mb`). Kind is
  the one worth building; the rest are `Open Questions`.
- Undo of an eviction or a delete. Consistent with the current app — deletes are
  immediate and final.

## 4. Feature A — Retention window

An age-based eviction pass that runs alongside the existing count cap. Items older
than the window are removed regardless of how few there are; the count cap still
applies as a hard ceiling on top.

### 4.1 Behaviour

| ID | Requirement |
|----|-------------|
| RET-1 | A single global **retention window** preference: `Forever` (off) or one of `1 day`, `7 days`, `30 days`, `90 days`. |
| RET-2 | Default is **Forever** — the current behaviour. The feature is opt-in; a version update must never silently delete history the author didn't ask it to lose. |
| RET-3 | When set to N days, any history item whose freshness timestamp is older than `now − N days` is evicted: removed from the in-memory list *and* the database, with its backing image file cleaned up (same path as `STO-2` eviction). |
| RET-4 | Freshness is measured from `created_at`, which the dedup upsert (`CAP-5`) already bumps to "now" on every re-copy. So the window measures *time since last copied*, not time since first seen — an item you keep reaching for never expires. This is the intended semantics, not an accident. |
| RET-5 | Eviction runs at launch (after the warm-load) and again while the app is running, so an item crossing the threshold disappears without a relaunch. Cadence need only be coarse — a window is a soft boundary, not a deadline. |
| RET-6 | Age eviction and the count cap compose: an item is retained only if it is both younger than the window **and** within the newest `historyCapacity` rows. Age is applied first, count second. |
| RET-7 | Pinned snippets are never subject to retention — they live in a separate table and are out of scope entirely (consistent with `STO-5`). |
| RET-8 | If the picker is open when an eviction fires, the list refreshes in place (it already live-refreshes on history changes). Removing the currently-selected row must not crash or leave selection dangling — clamp as the existing delete path does. |
| RET-9 | Changing the window to a shorter value applies immediately: the next eviction pass (which should be triggered by the preference change) prunes anything now out of range. Changing it to `Forever` stops future age eviction; it does **not** resurrect already-evicted items. |

### 4.2 Surface

| ID | Requirement |
|----|-------------|
| RET-10 | One control in Settings → **Clipboard**, a segmented/pop-up picker labelled "Keep history for", with the RET-1 options. Sits beside the existing "When you copy a file" control. |
| RET-11 | No confirmation dialog on change. Setting a window is not itself destructive-feeling; it's a policy. (The one-time first prune it triggers is bounded and, by RET-2, never a surprise on upgrade.) |

### 4.3 Success criteria

- Set "7 days", use the app for two weeks: nothing older than a week is ever in the
  list, and the author never manually cleared anything.
- An item copied daily stays in history indefinitely under a 7-day window.
- Upgrading a build with existing history and never touching the setting changes
  nothing about what's retained.

## 5. Feature B — Kind filters (`#` tokens)

A leading `#token` in the picker query scopes the list to one kind of item. The
rest of the query fuzzy-filters within that scope, exactly as today. This is a
*filter*, not an action: it narrows what you see so the existing select + delete
gestures act on a meaningful set.

### 5.1 Behaviour

| ID | Requirement |
|----|-------------|
| FLT-1 | A query whose first whitespace-delimited word is a recognised `#token` activates a kind scope. Recognised tokens: `#text`, `#image`, `#file`, `#link`, `#pinned`. |
| FLT-2 | The remaining text after the token fuzzy-filters within the scope. `#file report` → file items matching "report"; `#image` alone → all images. |
| FLT-3 | `#link` scopes to text items classified as links (the existing `classification == "link"` rule). `#pinned` scopes to pinned snippets and hides history. The others map to `ClipboardItem.Kind`. |
| FLT-4 | **Literal-`#` escape hatch:** a leading `#` that is *not* a recognised token (e.g. `#ff0000`, `#deploy`, a markdown heading) is treated as ordinary search text, matched literally as today. Only exact known tokens are intercepted, so real content starting with `#` is never swallowed. |
| FLT-5 | While the first word is a partial, unfinished token (`#`, `#im`), the list is replaced by an **autocomplete list** of matching tokens — arrow-selectable, completed with Tab or Enter. This is the feature's discoverability: typing `#` reveals what scopes exist. |
| FLT-6 | An active scope is shown as a small pill/chip in the search field (e.g. `[image]`) so the mode is never invisible — the user always sees why the list is narrowed. |
| FLT-7 | The result-count label reflects the scope ("3 images"), and the empty state names the scope ("No images") rather than a generic "No results". |
| FLT-8 | Backspacing through the token clears the scope and restores the full list, with no residual mode. |

### 5.2 The prune payoff

| ID | Requirement |
|----|-------------|
| FLT-9 | **⌘A selects every currently-listed row** (all rows the active query/scope shows). This is the missing gesture that makes filter → delete a three-keystroke sweep: `#image` · `⌘A` · `⌘⌫`. |
| FLT-10 | `⌘A` respects the scope: it selects only what's visible, never hidden rows. Deleting the selection then uses the existing multi-delete path (`deleteSelected`), which already handles image-file cleanup and selection clamping. |
| FLT-11 | `#pinned` + `⌘A` + `⌘⌫` deletes snippets, which is a heavier action than clearing history. Snippet deletion via this path must go through the same `SnippetStore.delete` already used, and — unlike history — should feel deliberate. (Confirmation is an Open Question; default to no dialog for consistency, revisit if it bites.) |

### 5.3 Non-destructive by construction

The whole point of choosing filters over commands: FLT never deletes anything.
The user narrows the list (FLT-1…8), *looks at it*, and only then invokes the
existing, already-safe delete gestures (FLT-9…11). There is no path where typing a
token removes data.

### 5.4 Success criteria

- Typing `#` shows the five scopes without the author having read any docs.
- `#image` then `⌘A` then `⌘⌫` clears every image from history and nothing else, in
  three keystrokes, having shown exactly those images first.
- Copying `#include <stdio.h>` or a hex colour and searching for it still works —
  the leading `#` finds the literal text, not an empty image scope.

## 6. Interaction between the two features

They are orthogonal and reinforcing: retention keeps the list small passively;
kind filters prune it actively when the author wants a specific class gone now.
Neither shares state with the other. Ship A first (it needs no picker changes and
directly answers "history gets big fast"), then B.

## 7. Open questions

1. **Retention default.** Shipping `Forever` is the safe, no-surprise choice, but
   it means the feature does nothing until the author finds the setting. A default
   of `30 days` would deliver the QoL immediately at the cost of silently pruning
   on first launch. Leaning `Forever`; revisit after dogfooding.
2. **Eviction cadence (RET-5).** On-insert is simplest and always-correct for the
   common case (you're copying, so the pass runs). A low-frequency timer covers the
   "app left open idle for hours" case. Start with on-insert + launch; add a timer
   only if a stale item is ever observed lingering.
3. **Snippet-delete confirmation (FLT-11).** Deleting pinned snippets via
   `#pinned` + `⌘A` is the one genuinely heavy action in this set. A confirm step
   there (only there) may be worth the inconsistency. Decide after trying it.
4. **More scopes.** `app:safari`, `before:monday`, `size:>1mb` are natural
   extensions of the same token grammar. Out of scope for v1; the parser should be
   written so they're additions, not rewrites.
