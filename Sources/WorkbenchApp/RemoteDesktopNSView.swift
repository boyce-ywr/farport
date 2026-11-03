import AppKit
import IOSurface
import QuartzCore
import WorkbenchCore
import RemoteDesktop

/// 远程桌面画面与输入：画面写入两块 IOSurface 轮流交给 CALayer 显示（系统合成器直接用 GPU 合成，只复制脏区域）；键盘、鼠标、滚轮转为 RFB 事件。
final class RemoteDesktopNSView: NSView {
    private weak var session: RemoteDesktopSession?
    private var surfaces: [IOSurface] = []
    private var surfaceDirty: [CGRect?] = []
    private var front = 0
    private var surfaceGeneration: UInt64 = .max
    private var updateScheduled = false
    private var pressedKeys: [UInt16: UInt32] = [:]
    private var pressedModifiers: [UInt16: UInt32] = [:]
    private var buttons: UInt8 = 0
    private var middleEmulation = false
    private var scrollAccumulator = CGPoint.zero
    private var keyUpMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(session: RemoteDesktopSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1).cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear; layer?.minificationFilter = .trilinear
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            // ⌘ 按住时 AppKit 不把 keyUp 交给视图：在此补发释放。
            guard let self, event.window === window, window?.firstResponder === self, event.modifierFlags.contains(.command) else { return event }
            keyUp(with: event); return nil
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? NSWindow == nil || notification.object as? NSWindow === self.window else { return }
                    self.releaseInput()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.hasKeyboardFocus { self.session?.focusChanged(true) } }
        })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit {
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// 协议线程有新画面时调用（已切回主线程）；同一轮事件循环内的多次更新合并为一次。
    func framebufferChanged() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in self?.updateSurface() }
    }

    /// 把帧缓冲的变化复制进后台 IOSurface 并切换为显示内容；每块 IOSurface 记录自上次写入以来的累计脏区域。
    private func updateSurface() {
        updateScheduled = false
        guard let client = session?.client, session?.phase == .connected else {
            if session?.phase != .connected, layer?.contents != nil { layer?.contents = nil }
            return
        }
        var changed = false
        client.framebuffer.consume { pixels, width, height, dirty, generation in
            guard width > 0, height > 0 else { return }
            if surfaces.count != 2 || generation != surfaceGeneration || surfaces[0].width != width || surfaces[0].height != height {
                let properties: [IOSurfacePropertyKey: Any] = [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: UInt32(0x42475241)] // 'BGRA'
                guard let first = IOSurface(properties: properties), let second = IOSurface(properties: properties) else { return }
                surfaces = [first, second]; surfaceGeneration = generation; front = 1
                let all = CGRect(x: 0, y: 0, width: width, height: height)
                surfaceDirty = [all, all]
            } else if let dirty {
                for index in surfaceDirty.indices { surfaceDirty[index] = surfaceDirty[index].map { $0.union(dirty) } ?? dirty }
            }
            let back = 1 - front
            guard let area = surfaceDirty[back]?.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)), !area.isEmpty else { return }
            let surface = surfaces[back]
            surface.lock(options: [], seed: nil)
            let destination = surface.baseAddress, stride = surface.bytesPerRow
            let x = Int(area.minX), rowBytes = Int(area.width) * 4
            for row in Int(area.minY)..<Int(area.maxY) {
                memcpy(destination + row * stride + x * 4, pixels + row * width + x, rowBytes)
            }
            surface.unlock(options: [], seed: nil)
            surfaceDirty[back] = nil; front = back; changed = true
        }
        if changed { layer?.contents = surfaces[front] }
    }

    /// 测试用：读取当前正在显示的 IOSurface 像素。
    func displayedSnapshot() -> [UInt32]? {
        guard surfaces.count == 2, let shown = layer?.contents as? IOSurface, shown === surfaces[front] else { return nil }
        shown.lock(options: .readOnly, seed: nil); defer { shown.unlock(options: .readOnly, seed: nil) }
        var pixels = [UInt32](repeating: 0, count: shown.width * shown.height)
        for row in 0..<shown.height { memcpy(&pixels[row * shown.width], shown.baseAddress + row * shown.bytesPerRow, shown.width * 4) }
        return pixels
    }

    // MARK: 几何

    private var framebufferSize: CGSize {
        guard let client = session?.client else { return session?.size ?? .zero }
        return CGSize(width: client.framebuffer.width, height: client.framebuffer.height)
    }
    /// 等比适应视图的画面区域（单位：点，原点在左上，与图层 resizeAspect 一致）。
    var fitRect: CGRect {
        let size = framebufferSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    /// 远端一个像素对应的点数（用于缩放光标）。
    var displayScale: CGFloat { framebufferSize.width > 0 ? max(0.05, fitRect.width / framebufferSize.width) : 1 }
    private func remotePoint(_ event: NSEvent) -> (Int, Int)? {
        let point = convert(event.locationInWindow, from: nil), rect = fitRect, size = framebufferSize
        guard rect.width > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * size.width, y = (point.y - rect.minY) / rect.height * size.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    // MARK: 焦点

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var hasKeyboardFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === self && NSApp.isActive }
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in if let self, self.hasKeyboardFocus { self.session?.focusChanged(true) } }
        return true
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    /// 失去焦点时松开所有按住的键和鼠标按钮，避免远端“粘键”。
    func releaseInput() {
        guard let client = session?.client else { pressedKeys = [:]; pressedModifiers = [:]; buttons = 0; return }
        for keysym in pressedKeys.values { client.key(keysym, down: false) }
        for keysym in pressedModifiers.values { client.key(keysym, down: false) }
        pressedKeys = [:]; pressedModifiers = [:]
        if buttons != 0 { buttons = 0; client.pointer(x: 0, y: 0, buttons: 0) }
    }

    // MARK: 键盘

    /// Farport 保留 ⌃⌥ 前缀：⌃⌥F 全屏、⌃⌥Esc 释放键盘、⌃⌥W 关闭桌面。
    private func handleReserved(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard flags == [.control, .option] else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): releaseInput(); window?.makeFirstResponder(nil); session?.show(L10n.text("已释放键盘，点击画面可重新控制。")); return true
        case (_, "f"): RemoteDesktopWindows.shared.toggleFullScreen(session); return true
        case (_, "w"): session?.close(); return true
        default: return false
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if handleReserved(event) { return true }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard let session, let client = session.client, session.phase == .connected else { return }
        if handleReserved(event) { return }
        let keysym: UInt32?
        if let special = RFBKeyboard.special(keyCode: event.keyCode) { keysym = special }
        else {
            let flags = event.modifierFlags
            let text = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
                ? event.characters(byApplyingModifiers: flags.intersection(.shift)) : event.characters
            keysym = text.flatMap(RFBKeyboard.character)
        }
        guard let keysym else { return }
        if let previous = pressedKeys[event.keyCode], previous != keysym { client.key(previous, down: false) }
        pressedKeys[event.keyCode] = keysym
        client.key(keysym, down: true)
    }
    override func keyUp(with event: NSEvent) {
        guard let keysym = pressedKeys.removeValue(forKey: event.keyCode) else { return }
        session?.client?.key(keysym, down: false)
    }
    override func flagsChanged(with event: NSEvent) {
        guard let session, let client = session.client, session.phase == .connected,
              let keysym = RFBKeyboard.modifier(keyCode: event.keyCode, mapping: session.commandMapping) else { return }
        if event.keyCode == 57 { client.key(keysym, down: true); client.key(keysym, down: false); return }
        if let pressed = pressedModifiers.removeValue(forKey: event.keyCode) {
            client.key(pressed, down: false)
            // ⌘ 松开后，补发仍未收到 keyUp 的组合键释放。
            if event.keyCode == 55 || event.keyCode == 54, !event.modifierFlags.contains(.command) {
                for value in pressedKeys.values { client.key(value, down: false) }
                pressedKeys = [:]
            }
        } else {
            pressedModifiers[event.keyCode] = keysym
            client.key(keysym, down: true)
        }
    }

    // MARK: 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func resetCursorRects() {
        if let cursor = session?.cursor { addCursorRect(fitRect, cursor: cursor) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if let cursor = session?.cursor, fitRect.contains(convert(event.locationInWindow, from: nil)) { cursor.set() } else { super.cursorUpdate(with: event) }
    }
    private func sendPointer(_ event: NSEvent) {
        guard let client = session?.client, session?.phase == .connected, let (x, y) = remotePoint(event) else { return }
        client.pointer(x: x, y: y, buttons: buttons)
    }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        // 远端不是 macOS 时 ⌥+点击 作为中键；macOS 远端保留 ⌥+点击 原义。
        middleEmulation = event.modifierFlags.contains(.option) && session?.info?.isMacOS == false
        buttons |= middleEmulation ? 2 : 1; sendPointer(event)
    }
    override func mouseUp(with event: NSEvent) { buttons &= middleEmulation ? ~2 : ~1; middleEmulation = false; sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDown(with event: NSEvent) { if window?.firstResponder !== self { window?.makeFirstResponder(self) }; buttons |= 4; sendPointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { buttons |= 2; sendPointer(event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { buttons &= ~2; sendPointer(event) } }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func scrollWheel(with event: NSEvent) {
        guard let client = session?.client, session?.phase == .connected, let (x, y) = remotePoint(event) else { return }
        // 触控板按像素累计，约 12 点换算为一格滚轮；鼠标滚轮按行。方向沿用本地“自然滚动”设置。
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulator.x += event.scrollingDeltaX; scrollAccumulator.y += event.scrollingDeltaY
        func emit(_ amount: inout CGFloat, positive: UInt8, negative: UInt8) {
            while abs(amount) >= step {
                let button = amount > 0 ? positive : negative
                client.pointer(x: x, y: y, buttons: buttons | button); client.pointer(x: x, y: y, buttons: buttons)
                amount -= amount > 0 ? step : -step
            }
        }
        emit(&scrollAccumulator.y, positive: 8, negative: 16)
        emit(&scrollAccumulator.x, positive: 32, negative: 64)
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = .zero }
    }
}
