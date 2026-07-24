import AppKit
import SwiftUI

/// Shows a brief, non-modal notice near the top of the active display. Used for
/// the Secure Input case above all — a paste that silently does nothing is the
/// worst outcome this app can produce, so that condition is always explained.
final class NoticePresenter {
    static let shared = NoticePresenter()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(_ message: String, duration: TimeInterval = 2.6) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: NoticeView(message: message))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - 24
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private struct NoticeView: View {
    let message: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(Theme.accent300)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.accent200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
        .fixedSize()
    }
}
