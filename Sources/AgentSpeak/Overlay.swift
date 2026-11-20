import AppKit
import Combine
import SwiftUI

// Kleines Overlay am Bildschirmrand (wie Wispr Flow): eingeklappt ein schmaler Griff,
// bei Hover eine Spalte mit Buttons. Es folgt dem Bildschirm, auf dem der Mauszeiger ist.

enum OverlayButton: Hashable, CaseIterable {
    case toggle, stop, replay, settings
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var expanded = false
    @Published var hovered: OverlayButton?
    @Published var dragging = false
    var frames: [OverlayButton: CGRect] = [:]
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    static let collapsedSize = NSSize(width: 34, height: 80)
    static let expandedSize = NSSize(width: 360, height: 240)

    private let panel: OverlayPanel
    private let model = OverlayModel()
    private let state: AppState
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var collapseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var dragStart: NSPoint?

    init(state: AppState) {
        self.state = state
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = OverlayView(model: model, state: state) { button in
            MainActor.assumeIsolated { OverlayController.current?.perform(button) }
        }
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        Self.current = self

        let handler: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated { OverlayController.current?.handleMouse(NSEvent.mouseLocation) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) {
            monitors.append(m)
        }
        // Drag & Drop: Overlay greifen und an den linken oder rechten Rand ziehen
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { e in
            MainActor.assumeIsolated { OverlayController.current?.handleDrag(e) ?? e }
        }) {
            monitors.append(m)
        }
        // Fallback, falls keine Mausereignisse ankommen (z. B. Bildschirmwechsel per Tastatur)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { OverlayController.current?.handleMouse(NSEvent.mouseLocation) }
        }

        state.$showOverlay.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }.store(in: &cancellables)
        state.$overlaySide.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        state.$overlayY.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.screen = nil; self?.layout() } }
            .store(in: &cancellables)

        screen = Self.screenUnderMouse()
        layout()
        updateVisibility()
    }

    private static weak var current: OverlayController?

    private static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    private func updateVisibility() {
        if state.showOverlay { layout(); panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func layout(animated: Bool = false) {
        guard !model.dragging, let screen = screen ?? Self.screenUnderMouse() else { return }
        let vf = screen.visibleFrame
        let size = model.expanded ? Self.expandedSize : Self.collapsedSize
        let x = state.overlaySide == .left ? vf.minX : vf.maxX - size.width
        let center = vf.minY + vf.height * CGFloat(state.overlayY)
        let y = min(max(center - size.height / 2, vf.minY), vf.maxY - size.height).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: animated)
    }

    // MARK: Drag & Drop

    /// Gibt `nil` zurück, wenn das Ereignis vom Ziehen verbraucht wurde (dann löst kein Button aus).
    fileprivate func handleDrag(_ e: NSEvent) -> NSEvent? {
        let p = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown:
            dragStart = e.window === panel ? p : nil
            return e
        case .leftMouseDragged:
            guard let start = dragStart else { return e }
            if !model.dragging {
                guard hypot(p.x - start.x, p.y - start.y) > 4 else { return e }
                collapseTimer?.invalidate()
                collapseTimer = nil
                model.hovered = nil
                model.expanded = false
                model.dragging = true
            }
            let size = Self.collapsedSize
            panel.setFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                  width: size.width, height: size.height), display: true)
            return nil
        case .leftMouseUp:
            dragStart = nil
            guard model.dragging else { return e }
            model.dragging = false
            let target = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? screen ?? NSScreen.main
            if let target {
                screen = target
                let vf = target.visibleFrame
                state.overlaySide = p.x < vf.midX ? .left : .right
                state.overlayY = Double(min(max((p.y - vf.minY) / vf.height, 0.05), 0.95))
            }
            layout(animated: true)
            return nil
        default:
            return e
        }
    }

    fileprivate func handleMouse(_ p: NSPoint) {
        guard state.showOverlay, !model.dragging else { return }
        if !model.expanded, let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }), s != screen {
            screen = s
            layout()
        }
        let zone = model.expanded ? panel.frame : panel.frame.insetBy(dx: -4, dy: -4)
        if zone.contains(p) {
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !model.expanded { setExpanded(true) }
            updateHover(p)
        } else if model.expanded {
            if model.hovered != nil { model.hovered = nil }
            if collapseTimer == nil {
                collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let c = OverlayController.current else { return }
                        c.collapseTimer = nil
                        c.setExpanded(false)
                    }
                }
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        if expanded {
            model.expanded = true
            layout()
        } else {
            model.hovered = nil
            model.expanded = false
            layout()
        }
    }

    private func updateHover(_ p: NSPoint) {
        guard model.expanded else { return }
        let local = panel.convertPoint(fromScreen: p)
        let pt = CGPoint(x: local.x, y: panel.frame.height - local.y)   // SwiftUI: Ursprung oben links
        let hit = model.frames.first { $0.value.insetBy(dx: -4, dy: -4).contains(pt) }?.key
        if model.hovered != hit { model.hovered = hit }
    }

    fileprivate func perform(_ button: OverlayButton) {
        switch button {
        case .toggle: state.toggleEnabled()
        case .stop: state.stopPlayback()
        case .replay: state.replay()
        case .settings:
            setExpanded(false)
            SettingsWindowController.shared.show()
        }
    }
}

// MARK: - SwiftUI

private struct FramesKey: PreferenceKey {
    static var defaultValue: [OverlayButton: CGRect] = [:]
    static func reduce(value: inout [OverlayButton: CGRect], nextValue: () -> [OverlayButton: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private enum Palette {
    static let fill = Color(white: 0.11).opacity(0.94)
    static let fillHover = Color(white: 0.22).opacity(0.96)
    static let stroke = Color.white.opacity(0.22)
    static let accent = Color(red: 0.45, green: 0.62, blue: 1.0)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var state: AppState
    let action: (OverlayButton) -> Void

    private var left: Bool { state.overlaySide == .left }

    var body: some View {
        ZStack(alignment: model.dragging ? .center : (left ? .leading : .trailing)) {
            Color.clear
            Group {
                if model.expanded {
                    expanded
                } else {
                    Handle(state: state, dragging: model.dragging)
                }
            }
            .padding(left ? .leading : .trailing, model.dragging ? 0 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "overlay")
        .onPreferenceChange(FramesKey.self) { model.frames = $0 }
    }

    private var expanded: some View {
        VStack(alignment: left ? .leading : .trailing, spacing: 8) {
            row(.toggle) { ToggleCapsule(state: state, hovered: model.hovered == .toggle) }
            row(.stop) { RoundButton(symbol: "stop.fill", enabled: state.busy, hovered: model.hovered == .stop) }
            row(.replay) { RoundButton(symbol: "arrow.counterclockwise", enabled: state.hasLastText, hovered: model.hovered == .replay) }
            row(.settings) { RoundButton(symbol: "gearshape.fill", enabled: true, hovered: model.hovered == .settings) }
        }
    }

    /// Der Tooltip hängt als Overlay neben dem Button und beeinflusst das Layout nicht –
    /// sonst verschiebt ein langer Text die ganze Spalte und das Overlay springt.
    private func row<C: View>(_ b: OverlayButton, @ViewBuilder content: () -> C) -> some View {
        Button { action(b) } label: { content() }
            .buttonStyle(.plain)
            .frame(width: 40)
            .background(GeometryReader { g in
                Color.clear.preference(key: FramesKey.self, value: [b: g.frame(in: .named("overlay"))])
            })
            .overlay(alignment: left ? .leading : .trailing) {
                tooltip(b)
                    .fixedSize()
                    .alignmentGuide(left ? .leading : .trailing) { d in left ? -48 : d.width + 48 }
            }
    }

    @ViewBuilder
    private func tooltip(_ b: OverlayButton) -> some View {
        if model.hovered == b {
            Text(title(b))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.9)))
                .lineLimit(1)
                .fixedSize()
                .allowsHitTesting(false)
        }
    }

    private func title(_ b: OverlayButton) -> String {
        switch b {
        case .toggle:
            if state.speaking { return tr("Spricht gerade · Vorlesen ausschalten", "Speaking · turn off read aloud") }
            if state.summarizing { return tr("Fasst zusammen · Vorlesen ausschalten", "Summarizing · turn off read aloud") }
            return state.enabled ? tr("Vorlesen an · klicken zum Ausschalten", "Read aloud on · click to turn off")
                                 : tr("Vorlesen aus · klicken zum Einschalten", "Read aloud off · click to turn on")
        case .stop: return state.busy ? tr("Ansage stoppen", "Stop speaking") : tr("Gerade keine Ansage", "Nothing playing")
        case .replay: return state.hasLastText ? tr("Letzte Ansage wiederholen", "Repeat last summary") : tr("Noch keine Ansage", "No summary yet")
        case .settings: return tr("Einstellungen · zum Verschieben ziehen", "Settings · drag to move")
        }
    }
}

/// Eingeklappter Griff am Bildschirmrand.
private struct Handle: View {
    @ObservedObject var state: AppState
    var dragging = false

    var body: some View {
        let active = state.enabled && state.busy
        ZStack {
            Capsule()
                .fill(Palette.fill)
                .overlay(Capsule().strokeBorder(state.speaking ? Palette.accent.opacity(0.9) : Palette.stroke, lineWidth: 1))
            if state.enabled && state.speaking {
                WaveBars(count: 3, height: 18, width: 2.5)
            } else if state.enabled && state.summarizing {
                PulsingDots()
            }
        }
        .frame(width: active || dragging ? 22 : 8, height: active || dragging ? 46 : 40)
        .overlay(dragging ? Capsule().strokeBorder(Palette.accent, lineWidth: 1.5) : nil)
        .shadow(color: .black.opacity(dragging ? 0.4 : 0), radius: 6)
        .opacity(state.enabled || dragging ? 1 : 0.45)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
    }
}

private struct ToggleCapsule: View {
    @ObservedObject var state: AppState
    let hovered: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(hovered ? Palette.fillHover : Palette.fill)
                .overlay(Capsule().strokeBorder(state.speaking ? Palette.accent : Palette.stroke, lineWidth: 1))
            if state.enabled && state.speaking {
                WaveBars(count: 4, height: 22, width: 3)
            } else if state.enabled && state.summarizing {
                PulsingDots()
            } else {
                Image(systemName: state.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.enabled ? Color.white : Color.white.opacity(0.45))
            }
        }
        .frame(width: 40, height: 64)
        .contentShape(Capsule())
    }
}

private struct RoundButton: View {
    let symbol: String
    let enabled: Bool
    let hovered: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(hovered && enabled ? Palette.fillHover : Palette.fill)
                .overlay(Circle().strokeBorder(Palette.stroke, lineWidth: 1))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(enabled ? 0.95 : 0.3))
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
}

private struct WaveBars: View {
    let count: Int
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: width * 0.8) {
                ForEach(0..<count, id: \.self) { i in
                    let phase = sin(t * 7 + Double(i) * 1.3) * 0.5 + 0.5
                    Capsule()
                        .fill(Color.white)
                        .frame(width: width, height: max(width, height * (0.3 + 0.7 * phase)))
                }
            }
            .frame(height: height)
        }
    }
}

private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.65 * (sin(t * 5 - Double(i) * 0.9) * 0.5 + 0.5)))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }
}
