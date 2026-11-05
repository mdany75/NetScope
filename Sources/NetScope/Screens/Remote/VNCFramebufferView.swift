import AppKit
import NetScopeCore
import SwiftUI

/// Affichage du bureau distant et capture du clavier et de la souris (NSView : les touches de
/// commande, les modificateurs et la molette doivent arriver tels quels).
/// « Ajuster » : l'image entière, proportions gardées ; « 100 % » : un pixel distant par point,
/// et la vue se décale quand le pointeur approche d'un bord (comme Partage d'écran).
final class VNCFramebufferNSView: NSView {
    var session: VNCSession? {
        didSet { needsDisplay = true }
    }
    var image: CGImage? {
        didSet {
            if image?.width != oldValue?.width || image?.height != oldValue?.height { clampPan() }
            needsDisplay = true
        }
    }
    var scaleMode: VNCScaleMode = .fit {
        didSet {
            if scaleMode != oldValue {
                pan = .zero
                needsDisplay = true
            }
        }
    }
    var remoteCursor: NSCursor? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// Décalage de l'image en mode 100 % (points, origine en haut à gauche).
    private var pan = CGPoint.zero
    private var buttons: RFBButtons = []
    private var pressedKeys: [UInt16: UInt32] = [:]
    private var modifierKeys: Set<UInt16> = []
    private var scrollAccumulator = CGPoint.zero
    private var trackingArea: NSTrackingArea?
    private var edgeTimer: Timer?
    private var lastLocation: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Géométrie

    /// Rectangle de l'image dans la vue.
    var imageRect: CGRect {
        guard let image else { return .zero }
        let size = CGSize(width: image.width, height: image.height)
        switch scaleMode {
        case .fit:
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                          width: fitted.width, height: fitted.height)
        case .actual:
            // Image plus petite que la vue : centrée ; sinon décalée par `pan`.
            let x = size.width <= bounds.width ? (bounds.width - size.width) / 2 : -pan.x
            let y = size.height <= bounds.height ? (bounds.height - size.height) / 2 : -pan.y
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    /// Point de la vue → pixel du bureau distant.
    func remotePoint(_ point: NSPoint) -> (x: Int, y: Int)? {
        guard let image else { return nil }
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) * CGFloat(image.width) / rect.width
        let y = (point.y - rect.minY) * CGFloat(image.height) / rect.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private func clampPan() {
        guard let image else { return }
        pan.x = min(max(0, pan.x), max(0, CGFloat(image.width) - bounds.width))
        pan.y = min(max(0, pan.y), max(0, CGFloat(image.height) - bounds.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampPan()
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        // Fond transparent : celui de la vue SwiftUI (Theme.console) reste visible autour de l'image.
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return }
        let rect = imageRect
        context.saveGState()
        context.interpolationQuality = scaleMode == .fit ? .high : .none
        // Vue retournée : l'image se dessine dans un repère remis à l'endroit.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    // MARK: Curseur

    override func resetCursorRects() {
        let cursor = session?.viewOnly == true ? NSCursor.operationNotAllowed : (remoteCursor ?? NSCursor.crosshair)
        addCursorRect(imageRect.intersection(bounds), cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Souris

    private func sendPointer(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastLocation = location
        guard let point = remotePoint(location) else { return }
        session?.pointer(x: point.x, y: point.y, buttons: buttons)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session?.syncClipboardIfChanged()
        // Ctrl-clic : clic droit, comme ailleurs sur le Mac.
        buttons.insert(event.modifierFlags.contains(.control) ? .right : .left)
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttons.remove(.left)
        buttons.remove(.right)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons.insert(.right)
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttons.remove(.right)
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttons.insert(.middle)
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttons.remove(.middle)
        sendPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event)
        updateEdgePanning()
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event)
        updateEdgePanning()
    }

    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseExited(with event: NSEvent) {
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    /// Molette : un « cran » par ligne (souris) ou par 12 points (trackpad), en appui-relâche.
    override func scrollWheel(with event: NSEvent) {
        guard let location = Optional(convert(event.locationInWindow, from: nil)), let point = remotePoint(location) else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulator.x += event.scrollingDeltaX / factor
        scrollAccumulator.y += event.scrollingDeltaY / factor
        func pulse(_ button: RFBButtons, count: Int) {
            for _ in 0..<min(count, 10) {
                session?.pointer(x: point.x, y: point.y, buttons: buttons.union(button))
                session?.pointer(x: point.x, y: point.y, buttons: buttons)
            }
        }
        let vertical = Int(scrollAccumulator.y.rounded(.towardZero))
        if vertical != 0 {
            pulse(vertical > 0 ? .wheelUp : .wheelDown, count: abs(vertical))
            scrollAccumulator.y -= CGFloat(vertical)
        }
        let horizontal = Int(scrollAccumulator.x.rounded(.towardZero))
        if horizontal != 0 {
            pulse(horizontal > 0 ? .wheelLeft : .wheelRight, count: abs(horizontal))
            scrollAccumulator.x -= CGFloat(horizontal)
        }
    }

    /// Mode 100 % : le pointeur à moins de 24 points d'un bord fait défiler l'image.
    private func updateEdgePanning() {
        guard scaleMode == .actual, let image, CGFloat(image.width) > bounds.width || CGFloat(image.height) > bounds.height else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        guard edgeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private func panStep() {
        guard let location = lastLocation else { return }
        let margin: CGFloat = 24, speed: CGFloat = 14
        var delta = CGPoint.zero
        if location.x < margin { delta.x = -speed } else if location.x > bounds.width - margin { delta.x = speed }
        if location.y < margin { delta.y = -speed } else if location.y > bounds.height - margin { delta.y = speed }
        guard delta != .zero else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        let before = pan
        pan.x += delta.x
        pan.y += delta.y
        clampPan()
        if pan != before {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: Clavier

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Touches Commande envoyées à l'ordinateur distant quand la session a le focus, sauf
        // Commande-Q (quitter) et Ctrl-Commande-F (plein écran).
        guard window?.firstResponder === self, session?.phase == .connected else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command), key == "q" { return super.performKeyEquivalent(with: event) }
        if flags.contains([.command, .control]), key == "f" { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let keysym = RFBKeysym.forMacKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else { return }
        pressedKeys[event.keyCode] = keysym
        session?.key(keysym, down: true)
        // Les touches Commande ne reçoivent pas toujours de keyUp : relâchées tout de suite.
        if event.modifierFlags.contains(.command) {
            session?.key(keysym, down: false)
            pressedKeys[event.keyCode] = nil
        }
    }

    override func keyUp(with event: NSEvent) {
        let keysym = pressedKeys.removeValue(forKey: event.keyCode)
            ?? RFBKeysym.forMacKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard let keysym else { return }
        session?.key(keysym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let keysym = RFBKeysym.macModifierKeyCodes[event.keyCode] else { return }
        if event.keyCode == 0x39 {
            // Verr. maj. : un appui-relâche à chaque changement d'état.
            session?.key(keysym, down: true)
            session?.key(keysym, down: false)
            return
        }
        if modifierKeys.contains(event.keyCode) {
            modifierKeys.remove(event.keyCode)
            session?.key(keysym, down: false)
        } else {
            modifierKeys.insert(event.keyCode)
            session?.key(keysym, down: true)
        }
    }

    /// Focus perdu : toutes les touches et tous les boutons sont relâchés à distance.
    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    func releaseAll() {
        for keysym in pressedKeys.values { session?.key(keysym, down: false) }
        for code in modifierKeys { if let keysym = RFBKeysym.macModifierKeyCodes[code] { session?.key(keysym, down: false) } }
        pressedKeys = [:]
        modifierKeys = []
        if !buttons.isEmpty, let location = lastLocation, let point = remotePoint(location) {
            buttons = []
            session?.pointer(x: point.x, y: point.y, buttons: [])
        }
    }
}

/// Pont SwiftUI de l'affichage.
struct VNCFramebufferView: NSViewRepresentable {
    @ObservedObject var session: VNCSession
    var focusOnAppear = false

    func makeNSView(context: Context) -> VNCFramebufferNSView {
        let view = VNCFramebufferNSView()
        view.session = session
        if focusOnAppear {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        return view
    }

    func updateNSView(_ view: VNCFramebufferNSView, context: Context) {
        view.session = session
        if view.image !== session.image { view.image = session.image }
        view.scaleMode = session.scale
        view.remoteCursor = session.cursor
        view.window?.invalidateCursorRects(for: view)
    }

    static func dismantleNSView(_ view: VNCFramebufferNSView, coordinator: ()) {
        view.releaseAll()
    }
}
