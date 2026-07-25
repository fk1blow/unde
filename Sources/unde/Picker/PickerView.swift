import SwiftUI

/// The picker's SwiftUI content. A faithful build of the Nocturne "Snippet Bar"
/// design: a search row, a pinned-snippets section above a clipboard-history
/// section, and a footer of keyboard hints. Purely a view — all keyboard input
/// and selection is handled by `PickerController`.
struct PickerView: View {
    /// Which of the two picker windows this view fills. The main card and the
    /// detached preview card live in *separate* panels: rendering the resizing
    /// preview in the main panel left stale image/SVG rasters ghosting in the
    /// transparent backing when the preview shrank. A dedicated panel is resized
    /// (and hidden) per selection, so its backing is cleared naturally.
    enum Surface { case main, preview }

    @ObservedObject var model: PickerModel

    /// Which window this instance renders. Defaults to the main card.
    var surface: Surface = .main

    /// Called when a row is clicked, with its global index. (Main surface only.)
    var onClickRow: (Int) -> Void = { _ in }
    /// Called when the pointer enters a row, with its global index. (Main only.)
    var onHoverRow: (Int) -> Void = { _ in }
    /// Reports the preview content's natural (unscaled) size whenever it changes,
    /// so the controller can size the detached panel to hug it exactly. Driven by
    /// SwiftUI layout, so it is never stale. (Preview surface only.)
    var onPreviewSize: (CGSize) -> Void = { _ in }

    /// The last measured design (unscaled) size of the preview content, used to
    /// reclaim the scaled footprint so the surface's layout size matches the
    /// design×scale panel. (Preview surface only.)
    @State private var previewDesignSize: CGSize = CGSize(width: PickerView.previewWidth, height: 1)

    /// Past this many lines the text preview truncates rather than growing the
    /// card unbounded.
    private static let textPreviewMaxLines = 16

    /// Scroll-target ids for the section headers, so selecting the first row of a
    /// section can reveal its label rather than clip it at the top.
    private static let pinnedHeaderID = "header-pinned"
    private static let clipHeaderID = "header-clip"

    // Layout — the window holds the main card and, when there's something worth
    // showing, a detached preview card floating to its right across a transparent
    // gap. `windowWidth` must match `PickerController.panelWidth`.
    static let mainWidth: CGFloat = 600
    static let previewWidth: CGFloat = 300
    static let cardGap: CGFloat = 18
    static let windowWidth: CGFloat = mainWidth + cardGap + previewWidth
    /// The design-size height of the picker content, before UI scaling. The panel
    /// is sized to this × `uiScale` by `PickerController`.
    static let baseHeight: CGFloat = 420

    var body: some View {
        switch surface {
        case .main:    mainSurface
        case .preview: previewSurface
        }
    }

    /// The main panel: the fixed-size card, scaled by the UI-scale pref.
    private var mainSurface: some View {
        mainCard
            .frame(width: Self.mainWidth, height: Self.baseHeight)
            .scaleEffect(model.uiScale, anchor: .topLeading)
            .frame(width: Self.mainWidth * model.uiScale,
                   height: Self.baseHeight * model.uiScale,
                   alignment: .topLeading)
    }

    /// The detached preview panel: the card hugging its content, or nothing when
    /// the selection has no preview. Its own panel is sized to this by the
    /// controller (reading `fittingSize`), so `scaleEffect` here is deliberately
    /// left out of the layout size — the controller multiplies by the UI scale.
    @ViewBuilder
    private var previewSurface: some View {
        Group {
            if let kind = previewKind {
                previewCard(kind)
                    .frame(width: Self.previewWidth)
            } else {
                // A near-zero footprint so the controller reads "no preview" from
                // the reported size and hides the panel.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Measure the laid-out (design) size *before* the scaleEffect. This drives
        // both the panel size (via `onPreviewSize`) and the reframe below, so all
        // three — content, hosting view, panel — agree. `onPreferenceChange` is the
        // reliable trigger (fires on every change of the reduced value, grow or
        // shrink). Keyed on `previewGeneration` so re-opening re-reports.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PreviewSizeKey.self, value: geo.size)
            }
        )
        .scaleEffect(model.uiScale, anchor: .topLeading)
        // Reclaim the *scaled* footprint (mirrors `mainSurface`). Without this the
        // content lays out at design size while the panel is design×scale, so at
        // scale ≠ 1 the scaled content is centred and its right/bottom edges — and
        // their borders — spill past the panel and get clipped.
        .frame(width: previewDesignSize.width * model.uiScale,
               height: previewDesignSize.height * model.uiScale,
               alignment: .topLeading)
        .onPreferenceChange(PreviewSizeKey.self) { size in
            previewDesignSize = size
            onPreviewSize(size)
        }
        .id(model.previewGeneration)
    }

    /// The main panel: search row, the results list, and the footer of hints.
    private var mainCard: some View {
        VStack(spacing: 0) {
            searchRow
            // Small gaps so the list doesn't look glued to the search row above
            // or the status bar below.
            Divider().overlay(Theme.divider).padding(.bottom, 4)
            list
            Divider().overlay(Theme.divider).padding(.top, 4)
            footer
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Theme.neutral500.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Theme.neutral500)
            HStack(spacing: 8) {
                // An active kind scope shows as a pill (FLT-6), with only the
                // residual fuzzy text drawn after it — not the raw "#image foo".
                if let scope = model.scope {
                    ScopePill(text: scope.rawValue)
                }
                ZStack(alignment: .leading) {
                    if model.query.isEmpty {
                        Text("Search snippets and clipboard…")
                            .font(.system(size: 17))
                            .foregroundColor(Theme.neutral600)
                    }
                    HStack(spacing: 1) {
                        Text(model.scope != nil ? model.queryText : model.query)
                            .font(.system(size: 17))
                            .foregroundColor(Theme.text)
                        Caret()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KBD("esc")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.isCompleting {
                        // Token autocomplete: the suggestion list replaces results
                        // while a partial `#…` is being typed (FLT-5).
                        sectionHeader("Filter by kind")
                        ForEach(Array(model.suggestionRows.enumerated()), id: \.element.id) { offset, row in
                            rowView(row, index: offset)
                        }
                    } else {
                        // With a scope active, the search-row pill already names the
                        // category, so the section header would just repeat it — show
                        // headers only when unscoped.
                        let showHeaders = model.scope == nil
                        if !model.pinnedRows.isEmpty {
                            if showHeaders {
                                sectionHeader("Pinned snippets")
                                    .id(Self.pinnedHeaderID)
                            }
                            ForEach(Array(model.pinnedRows.enumerated()), id: \.element.id) { offset, row in
                                rowView(row, index: offset)
                            }
                        }
                        if !model.clipRows.isEmpty {
                            if showHeaders {
                                sectionHeader("Clipboard history")
                                    .padding(.top, model.pinnedRows.isEmpty ? 0 : 6)
                                    .id(Self.clipHeaderID)
                            }
                            ForEach(Array(model.clipRows.enumerated()), id: \.element.id) { offset, row in
                                rowView(row, index: model.pinnedRows.count + offset)
                            }
                        }
                        if model.isEmpty {
                            Text(model.emptyMessage)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.neutral600)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 34)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.selection) { newValue in
                // A hover moved the selection — highlight the row but leave the
                // scroll position where it is, so the list doesn't chase the
                // pointer. Keyboard navigation clears the flag and scrolls.
                if model.suppressAutoScroll {
                    model.suppressAutoScroll = false
                    return
                }
                // Scroll by the row's stable id (the same identity ForEach uses),
                // not a positional index — a second, positional identity would
                // confuse SwiftUI's diffing and leave stale rows highlighted.
                let rows = model.allRows
                guard newValue >= 0, newValue < rows.count else { return }
                // When landing on the first row of a section, target the section
                // header instead of the row, so the label above it is revealed
                // rather than left clipped at the top edge.
                // Headers only exist when unscoped; with a scope active, target the
                // row itself so scrollTo doesn't reference a header that isn't there.
                let targetID: String
                if model.scope == nil, newValue == 0, !model.pinnedRows.isEmpty {
                    targetID = Self.pinnedHeaderID
                } else if model.scope == nil, newValue == model.pinnedRows.count, !model.clipRows.isEmpty {
                    targetID = Self.clipHeaderID
                } else {
                    targetID = rows[newValue].id
                }
                // anchor: nil scrolls the *minimum* amount to keep the target on
                // screen — a fixed anchor re-centers on every keypress and makes
                // the list lurch. No animation, so stepping feels immediate.
                proxy.scrollTo(targetID, anchor: nil)
            }
        }
    }

    // MARK: Preview card

    /// What the detached preview should show for the current selection. `nil`
    /// means no preview — a single-line snippet that already fits in its row
    /// tells you everything, so we don't float an extra card for it.
    private enum PreviewKind {
        case image(DisplayRow)
        case svg(NSImage)    // SVG markup copied as text, rendered
        case text(String)    // multi-line or long-enough-to-be-truncated text
    }

    /// The single-line row can hold roughly this many characters before it
    /// truncates; past it, the preview earns its place.
    private static let truncationThreshold = 58

    private var previewKind: PreviewKind? {
        guard model.showPreview, let row = model.selectedRow else { return nil }
        // Files show name + path in the row itself; no detached preview card.
        if row.isFile { return nil }
        if row.image != nil { return .image(row) }
        // Colours already show a swatch in their row, so they get no preview card.
        let full = row.fullText
        if Self.hexColor(full) != nil { return nil }
        // SVG markup copied as text: render it so you see the graphic, not the XML.
        if let svg = Self.renderSVG(full) { return .svg(svg) }
        if full.contains("\n") || full.count > Self.truncationThreshold { return .text(full) }
        return nil
    }

    /// If the text is SVG markup, decode it and rasterise to a bitmap that
    /// SwiftUI can draw. Returns nil (→ text preview) if it isn't SVG or can't be
    /// decoded. NSImage decodes SVG as a *vector* rep which SwiftUI's Image won't
    /// render, so we draw it into a high-res bitmap first.
    private static func renderSVG(_ s: String) -> NSImage? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<"), t.contains("<svg"), t.contains("</svg>") else { return nil }
        guard let data = t.data(using: .utf8),
              let vector = NSImage(data: data),
              vector.isValid, vector.size.width > 0, vector.size.height > 0 else { return nil }
        return rasterize(vector, scale: 3)
    }

    /// Draw an image (e.g. a vector SVG) into an off-screen bitmap at `scale`× its
    /// point size, so the result is a plain bitmap NSImage SwiftUI can display.
    private static func rasterize(_ image: NSImage, scale: CGFloat) -> NSImage? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }

    /// A detached card, floating to the right of the main panel, whose contents
    /// depend on the selection's type. No title — the content speaks for itself.
    private func previewCard(_ kind: PreviewKind) -> some View {
        previewBody(kind)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                    .strokeBorder(Theme.neutral500.opacity(0.5), lineWidth: 1)
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    // Content area width inside the preview card (card width minus 16pt padding
    // each side).
    private static let previewContentWidth: CGFloat = previewWidth - 32
    private static let imagePreviewMaxHeight: CGFloat = 260

    @ViewBuilder
    private func previewBody(_ kind: PreviewKind) -> some View {
        switch kind {
        case .image(let row):
            // Just the image, sized to an exact fit box so the card hugs it — no
            // dimensions caption (that's in the row).
            if let image = row.image {
                let size = Self.imageFitSize(row)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .svg(let image):
            let size = Self.fitSize(width: image.size.width, height: image.size.height)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .text(let full):
            // Cap the text to a fixed number of *source* lines in Swift rather than
            // with `.lineLimit`: a lineLimit-truncated Text combined with `.fixedSize`
            // under-reports its own height by roughly half a line, so the card was
            // sized just short of what it draws and clipped the last line. Capping
            // the string means the Text lays out all of its (≤ cap) lines with no
            // truncation, so its measured height matches what's drawn exactly.
            // No .textSelection: the panel dismisses on focus loss so a selection
            // isn't usable, and macOS's selection highlight (the system accent)
            // otherwise paints a coloured box over the text.
            Text(Self.cappedLines(full, max: Self.textPreviewMaxLines))
                .font(.system(size: 13))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Truncate `text` to at most `max` lines, appending an ellipsis line when it
    /// was cut, so the preview caps its height without relying on `.lineLimit`.
    private static func cappedLines(_ text: String, max: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > max else { return text }
        return lines.prefix(max).joined(separator: "\n") + "\n…"
    }

    /// The exact display size for an image preview: scaled to fit the content
    /// width and max height while preserving aspect ratio, so the card hugs it
    /// with no letterbox or reserved min-height.
    private static func imageFitSize(_ row: DisplayRow) -> CGSize {
        fitSize(width: CGFloat(row.clip?.imageWidth ?? 0), height: CGFloat(row.clip?.imageHeight ?? 0))
    }

    /// Scale a w×h box to fit the preview content width and max height, preserving
    /// aspect ratio.
    private static func fitSize(width w: CGFloat, height h: CGFloat) -> CGSize {
        guard w > 0, h > 0 else {
            return CGSize(width: previewContentWidth, height: 180)
        }
        let scale = min(previewContentWidth / w, imagePreviewMaxHeight / h)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    /// Recognise a bare 3- or 6-digit hex colour (with leading `#`), so colours
    /// get a swatch instead of being treated as ordinary text.
    static func hexColor(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$", options: .regularExpression) != nil else {
            return nil
        }
        return t.uppercased()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.0)
            .foregroundColor(Theme.neutral600)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func rowView(_ row: DisplayRow, index: Int) -> some View {
        let active = model.isSelected(index)
        // The ⏎ chevron advertises paste, which is disabled while a multi-row
        // range is selected — so only show it in single-select mode.
        let showPaste = active && !model.isMultiSelecting
        let swatch = Self.hexColor(row.fullText).flatMap { Color(hexString: $0) }
        return PickerRow(text: row.text, meta: row.meta, colorSwatch: swatch, slot: row.slot, icon: row.icon,
                         active: active, showPaste: showPaste)
            .contentShape(Rectangle())
            .onTapGesture { onClickRow(index) }
            .onHover { if $0 { onHoverRow(index) } }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 13) {
            // The default verbs always show in these fixed positions, so the
            // footer doesn't reflow as the selection changes.
            hint("⏎", "paste")
            hint("⌘P", "pin")
            hint(model.deleteHintKey, "delete")
            hint("⌘A", "all")
            // Only advertise ⌘n jump when there are pinned slots, sized to how many
            // actually exist ("⌘1", "⌘1–3") rather than a fixed, mostly-empty ⌘1–9.
            if let jump = model.jumpHintKey {
                hint(jump, "jump")
            }
            // Selection-specific verbs append at the tail as accent chips so they
            // read as extra, contextual actions for this row — distinct from the
            // always-on hints. File rows are the only case today, and they don't
            // apply to a multi-row selection.
            if !model.isMultiSelecting, model.selectedRow?.isFile == true {
                actionChip("⌥⏎", "paste path")
                actionChip("⌘R", "reveal")
            }
            Spacer()
            Text(model.countLabel)
                .font(.system(size: 11))
                .foregroundColor(Theme.neutral500)
        }
        // Fixed content height so the chips' padding never makes the footer taller
        // than the plain-text hints — otherwise landing on a file row nudges the
        // whole layout vertically.
        .frame(height: 20)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.neutral400)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.neutral600)
        }
    }

    /// A contextual action rendered as an accent-tinted chip (no border), so
    /// actions specific to the current selection stand out from the muted,
    /// always-on hints.
    private func actionChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.accent300)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent300.opacity(0.9))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent.opacity(0.18))
        )
    }
}

/// Carries the preview surface's laid-out (design) size up to the controller, so
/// the detached panel can be resized to hug it. `onPreferenceChange` fires on
/// every change of the reduced value, which is the reliable way to catch the
/// preview both growing and shrinking as the selection moves.
private struct PreviewSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The visual content of a single picker row — primary text, optional secondary
/// meta, an optional colour swatch, an optional ⌘-slot keycap, and the paste
/// chevron shown when selected. Pure presentation with no interaction, so it can
/// be reused outside the picker (the Settings UI-scale preview renders it) without
/// dragging in selection or hover plumbing. `PickerView.rowView` wraps it with the
/// tap/hover gestures.
struct PickerRow: View {
    let text: String
    var meta: String? = nil
    var colorSwatch: Color? = nil
    var slot: Int? = nil
    var icon: NSImage? = nil
    let active: Bool
    /// Whether to show the ⏎ paste chevron. Defaults to `active` so existing
    /// call sites (e.g. the Settings preview) are unchanged; the picker passes
    /// `false` for rows in a multi-select range, where paste is disabled.
    var showPaste: Bool? = nil

    var body: some View {
        HStack(spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let meta {
                    Text(meta)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.neutral600)
                        .lineLimit(1)
                }
            }
            if let colorSwatch {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(colorSwatch)
                    .frame(width: 14, height: 14)
            }
            Spacer(minLength: 6)
            if let slot {
                KBD("⌘\(slot)")
            }
            Text("⏎")
                .font(.system(size: 13))
                .foregroundColor(Theme.accent300)
                .opacity((showPaste ?? active) ? 1 : 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(active ? Theme.rowSelectedBG : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .strokeBorder(active ? Theme.rowSelectedStroke : Color.clear, lineWidth: 1)
        )
    }
}

/// The active kind-scope indicator shown in the search row (FLT-6), so the mode
/// the list is filtered by is never invisible.
private struct ScopePill: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text("#")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accent300.opacity(0.7))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.accent300)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.accent.opacity(0.18))
        )
    }
}

/// A small keycap, matching the design's <kbd> styling.
private struct KBD: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Theme.neutral500)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
    }
}

/// A blinking text caret drawn after the query, since the field is not a real
/// focused control.
private struct Caret: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 2, height: 20)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
