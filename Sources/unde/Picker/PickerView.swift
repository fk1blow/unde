import SwiftUI

/// The picker's SwiftUI content. A faithful build of the Nocturne "Snippet Bar"
/// design: a search row, a pinned-snippets section above a clipboard-history
/// section, and a footer of keyboard hints. Purely a view — all keyboard input
/// and selection is handled by `PickerController`.
struct PickerView: View {
    @ObservedObject var model: PickerModel

    /// Called when a row is clicked, with its global index.
    var onClickRow: (Int) -> Void
    /// Called when the pointer enters a row, with its global index.
    var onHoverRow: (Int) -> Void

    /// Measured natural height of the text preview, so its card hugs the content
    /// instead of standing at a fixed box height.
    @State private var textPreviewHeight: CGFloat = 0
    /// Past this the text preview stops growing and scrolls instead.
    private static let textPreviewMaxHeight: CGFloat = 320

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
        HStack(alignment: .top, spacing: Self.cardGap) {
            mainCard
                .frame(width: Self.mainWidth, height: Self.baseHeight)
            if let kind = previewKind {
                previewCard(kind)
                    .frame(width: Self.previewWidth)
            }
        }
        .frame(width: Self.windowWidth, height: Self.baseHeight, alignment: .topLeading)
        // Uniform UI scale: lay the whole thing out at design size, scale it from
        // the top-left, then claim the scaled footprint so the hosting view (and
        // the panel it fills) match exactly.
        .scaleEffect(model.uiScale, anchor: .topLeading)
        .frame(width: Self.windowWidth * model.uiScale,
               height: Self.baseHeight * model.uiScale,
               alignment: .topLeading)
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
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Search snippets and clipboard…")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.neutral500)
                }
                HStack(spacing: 1) {
                    Text(model.query)
                        .font(.system(size: 17))
                        .foregroundColor(Theme.text)
                    Caret()
                }
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
                    if !model.pinnedRows.isEmpty {
                        sectionHeader("Pinned snippets")
                            .id(Self.pinnedHeaderID)
                        ForEach(Array(model.pinnedRows.enumerated()), id: \.element.id) { offset, row in
                            rowView(row, index: offset)
                        }
                    }
                    if !model.clipRows.isEmpty {
                        sectionHeader("Clipboard history")
                            .padding(.top, model.pinnedRows.isEmpty ? 0 : 6)
                            .id(Self.clipHeaderID)
                        ForEach(Array(model.clipRows.enumerated()), id: \.element.id) { offset, row in
                            rowView(row, index: model.pinnedRows.count + offset)
                        }
                    }
                    if model.isEmpty {
                        Text("No matches for “\(model.query)”")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.neutral600)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 34)
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
                let targetID: String
                if newValue == 0, !model.pinnedRows.isEmpty {
                    targetID = Self.pinnedHeaderID
                } else if newValue == model.pinnedRows.count, !model.clipRows.isEmpty {
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
            ScrollView {
                Text(full)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TextHeightKey.self, value: geo.size.height)
                    })
            }
            // Hug the measured text height, capping (and scrolling) past the max.
            .frame(height: min(max(textPreviewHeight, 1), Self.textPreviewMaxHeight))
            .onPreferenceChange(TextHeightKey.self) { textPreviewHeight = $0 }
        }
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
        let active = index == model.selection
        let swatch = Self.hexColor(row.fullText).flatMap { Color(hexString: $0) }
        return PickerRow(text: row.text, meta: row.meta, colorSwatch: swatch, slot: row.slot, active: active)
            .contentShape(Rectangle())
            .onTapGesture { onClickRow(index) }
            .onHover { if $0 { onHoverRow(index) } }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 13) {
            hint("⏎", "paste")
            hint("⌘P", "pin")
            hint("⌘⌫", "delete")
            hint("⌘1–9", "jump")
            Spacer()
            Text(model.countLabel)
                .font(.system(size: 11))
                .foregroundColor(Theme.neutral500)
        }
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
}

/// Reports the natural height of the text preview's content up the view tree.
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    let active: Bool

    var body: some View {
        HStack(spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                .opacity(active ? 1 : 0)
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
