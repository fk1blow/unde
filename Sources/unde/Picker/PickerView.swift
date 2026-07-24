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

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().overlay(Theme.divider)
            list
            Divider().overlay(Theme.divider)
            footer
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Theme.neutral500.opacity(0.5), lineWidth: 1)
        )
        .frame(width: 600)
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
                        ForEach(Array(model.pinnedRows.enumerated()), id: \.element.id) { offset, row in
                            rowView(row, index: offset)
                                .id(offset)
                        }
                    }
                    if !model.clipRows.isEmpty {
                        sectionHeader("Clipboard history")
                            .padding(.top, model.pinnedRows.isEmpty ? 0 : 6)
                        ForEach(Array(model.clipRows.enumerated()), id: \.element.id) { offset, row in
                            let index = model.pinnedRows.count + offset
                            rowView(row, index: index)
                                .id(index)
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
            .frame(minHeight: 120, maxHeight: 340)
            .onChange(of: model.selection) { newValue in
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
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
        return HStack(spacing: 11) {
            icon(for: row)
            Text(row.text)
                .font(.system(size: 14))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let slot = row.slot {
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
        .contentShape(Rectangle())
        .onTapGesture { onClickRow(index) }
        .onHover { if $0 { onHoverRow(index) } }
    }

    @ViewBuilder
    private func icon(for row: DisplayRow) -> some View {
        switch row.kind {
        case .pinned:
            Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.accent300)
                .frame(width: 16)
        case .clip:
            if let image = row.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.neutral500)
                    .frame(width: 16)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 13) {
            hint("↑↓", "navigate")
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
        .padding(.vertical, 10)
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
