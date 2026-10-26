// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import SwiftUI

/// The OpenBot window in Vorssaint's frame. OpenBot is an Electron app whose
/// renderer only lives inside its own process, so the window shows the real
/// OpenBot page through Chrome's DevTools protocol: the page is screencast
/// frame by frame into this surface, and the mouse, wheel and keys Vorssaint
/// receives are dispatched straight back into the page — the app's own window
/// is kept exactly one pixel behind Vorssaint's (a hidden window stops
/// painting, a covered one keeps compositing) and is never focused.
///
/// Vorssaint launches OpenBot with `--remote-debugging-port`, which the app
/// accepts as an Electron switch; without it there is nothing to attach to.
final class OpenBotMirrorService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = OpenBotMirrorService()

    enum Phase: Equatable {
        case idle
        case launching
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPinned = false

    /// The surface that is on screen, so frames skip SwiftUI publishing.
    weak var surface: OpenBotMirrorSurface?

    private static let debugPort = 9_222
    private static let appBundleID = "app.openbot.desktop"
    private static let targetURLPrefix = "openbot-app://app/index.html"
    /// The mirrored window sits this far behind Vorssaint's frame: enough of
    /// it stays uncovered that macOS never marks it occluded, which would
    /// stop the page from painting new frames.
    private static let sliver: CGFloat = 1

    private var panel: NSPanel?
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var viewportWidth: Double = 1200
    private var viewportHeight: Double = 820
    private var boundsSyncPending: DispatchWorkItem?
    private var isQuittingOpenBot = false
    private let queue = DispatchQueue(label: "com.vorssaint.openbot.mirror")
    private let hotkey = QuickToolHotkey(id: 19)

    private override init() {
        super.init()
        hotkey.onPress = { [weak self] in self?.toggle() }
    }

    // MARK: - Preferences

    func syncWithPreferences() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.openBotShortcut,
                                            fallback: .openBotDefault)
        _ = hotkey.sync(enabled: true, shortcut: shortcut,
                        storageKey: DefaultsKey.openBotShortcut)
    }

    func suspend() {
        hotkey.unregister()
        hide()
        disconnect()
    }

    // MARK: - Window

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if isVisible {
            panel?.makeKey()
            return
        }
        let panel = ensurePanel()
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            center(panel)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            panel.animator().alphaValue = 1
        }
        begin()
    }

    func hide() {
        guard panel != nil else { return }
        panel?.orderOut(nil)
        isPinned = false
        // Nothing mirrors while the pad is closed, and the app's own window
        // must not linger on the desktop: put it away without quitting it.
        setOpenBotWindow(hidden: true)
    }

    func togglePin() {
        guard isVisible else { return }
        isPinned.toggle()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = OpenBotMirrorPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                                       styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                       backing: .buffered,
                                       defer: false)
        panel.title = "OpenBot"
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentMinSize = NSSize(width: 480, height: 380)
        panel.delegate = self
        let host = NSHostingController(rootView: OpenBotMirrorView())
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 980, height: 660))
        center(panel)
        self.panel = panel
        return panel
    }

    private func center(_ panel: NSPanel) {
        let size = panel.frame.size
        let screen = NSScreen.pointerVisibleFrame
        let x = screen.midX - size.width / 2
        let y = screen.minY + (screen.height - size.height) * 0.5
        panel.setFrame(NSRect(x: max(screen.minX + 16, min(x, screen.maxX - size.width - 16)),
                              y: max(screen.minY + 16, min(y, screen.maxY - size.height - 16)),
                              width: size.width,
                              height: size.height),
                       display: true,
                       animate: false)
    }

    // MARK: - Window delegate: keep the mirrored window glued behind

    func windowDidMove(_ notification: Notification) {
        scheduleBoundsSync()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleBoundsSync()
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    private func scheduleBoundsSync() {
        boundsSyncPending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncBounds() }
        boundsSyncPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Places OpenBot's own window one pixel behind this one, so it keeps
    /// painting while staying invisible, and its viewport matches the mirror.
    private func syncBounds() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }) ?? NSScreen.main else { return }
        let topLeftX = frame.minX
        // AppleScript counts from the screen's top; AppKit from its bottom.
        let topLeftY = screen.frame.maxY - frame.maxY + Self.sliver
        let width = frame.width
        // The mirrored window carries no title bar; its content is the page.
        let height = frame.height
        runAppleScript("""
        tell application "System Events" to tell process "OpenBot"
            set position of window 1 to {\(Int(topLeftX)), \(Int(topLeftY))}
            set size of window 1 to {\(Int(width)), \(Int(height))}
        end tell
        """)
    }

    private func setOpenBotWindow(hidden: Bool) {
        let visible = hidden ? "false" : "true"
        runAppleScript("tell application \"System Events\" to set visible of process \"OpenBot\" to \(visible)")
    }

    // MARK: - Connection

    private func begin() {
        queue.async { [self] in
            portIsOpen { open in
                DispatchQueue.main.async { [self] in
                    if open {
                        connect()
                    } else {
                        launchWithDebugger()
                    }
                }
            }
        }
    }

    private func portIsOpen(_ completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.debugPort)/json/version")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    /// OpenBot only opens the debugger endpoint when launched with the
    /// switch, so an app that is already running without it has to be
    /// relaunched; its state lives on disk, so nothing is lost.
    private func launchWithDebugger() {
        phase = .launching
        let openBotRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleID).first != nil
        if openBotRunning {
            isQuittingOpenBot = true
            runAppleScript("tell application \"OpenBot\" to quit")
        }
        queue.async { [self] in
            if openBotRunning {
                wait(for: { NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleID).isEmpty },
                     timeout: 12)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "OpenBot", "--args",
                                 "--remote-debugging-port=\(Self.debugPort)"]
            try? process.run()
            DispatchQueue.main.async { [self] in
                waitForPort()
            }
        }
    }

    private func waitForPort(tries: Int = 0) {
        portIsOpen { [self] open in
            DispatchQueue.main.async { [self] in
                if open {
                    connect()
                } else if tries < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                        waitForPort(tries: tries + 1)
                    }
                } else {
                    phase = .failed("OpenBot åpnet ikke feilsøkingsporten")
                }
            }
        }
    }

    private func connect() {
        phase = .connecting
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.debugPort)/json/list")!)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [self] data, _, error in
            let webSocketURL = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                .flatMap { targets in
                    targets.first { ($0["url"] as? String)?.hasPrefix(Self.targetURLPrefix) == true }
                }
                .flatMap { $0["webSocketDebuggerUrl"] as? String }
                .flatMap(URL.init(string:))
            DispatchQueue.main.async { [self] in
                guard let webSocketURL else {
                    phase = .failed("Fant ikke OpenBot-siden")
                    return
                }
                attach(to: webSocketURL)
            }
        }.resume()
    }

    private func attach(to url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive()
        send("Page.enable") { [weak self] _ in
            self?.readViewport()
            self?.suppressOpenBotIsland()
            self?.startScreencast()
        }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pending.forEach { $0.value(.failure(URLError(.cancelled))) }
        pending = [:]
        phase = .idle
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handle(text)
                    }
                @unknown default:
                    break
                }
                self.receive()
            case .failure:
                DispatchQueue.main.async {
                    if self.phase != .idle, self.panel?.isVisible == true {
                        self.phase = .failed("Koblingen til OpenBot falt")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                            if panel?.isVisible == true { begin() }
                        }
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any],
               let description = error["message"] as? String {
                completion(.failure(OpenBotError(description)))
            } else {
                completion(.success(message["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        switch method {
        case "Page.screencastFrame":
            guard let params = message["params"] as? [String: Any],
                  let base64 = params["data"] as? String,
                  let metadata = params["metadata"] as? [String: Any],
                  let sessionID = params["sessionId"] as? Int else { return }
            send("Page.screencastFrameAck", params: ["sessionId": sessionID])
            let width = metadata["deviceWidth"] as? Double ?? 0
            let height = metadata["deviceHeight"] as? Double ?? 0
            queue.async { [self] in
                guard let data = Data(base64Encoded: base64),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                DispatchQueue.main.async { [self] in
                    surface?.displayFrame(image, viewportWidth: width, viewportHeight: height)
                    if phase != .streaming { phase = .streaming }
                }
            }
        default:
            break
        }
    }

    private func send(_ method: String,
                      params: [String: Any] = [:],
                      completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard let socket else {
            completion?(.failure(OpenBotError("Ingen tilkobling")))
            return
        }
        let id = nextID
        nextID += 1
        if let completion {
            pending[id] = completion
        }
        var message: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty {
            message["params"] = params
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: - Page setup

    private func readViewport() {
        send("Page.getLayoutMetrics") { [weak self] result in
            guard let self,
                  case .success(let metrics) = result,
                  let viewport = metrics["cssLayoutViewport"] as? [String: Any] else { return }
            viewportWidth = viewport["clientWidth"] as? Double ?? viewportWidth
            viewportHeight = viewport["clientHeight"] as? Double ?? viewportHeight
        }
    }

    /// OpenBot draws its own dynamic island at the notch, exactly where
    /// Vorssaint's island lives; turn the app's off so the two never stack.
    private func suppressOpenBotIsland() {
        let script = """
        (async () => {
          try {
            const current = await window.openbot.dynamicIsland.getPreference();
            if (current && current.enabled !== false) {
              await window.openbot.dynamicIsland.setPreference({...current, enabled: false});
            }
          } catch (e) { /* en fremtidig OpenBot uten øy overlates til seg selv */ }
          return true;
        })()
        """
        send("Runtime.evaluate",
             params: ["expression": script, "awaitPromise": true, "returnByValue": true]) { _ in }
    }

    private func startScreencast() {
        send("Page.startScreencast",
             params: ["format": "png", "maxWidth": 2600, "maxHeight": 1800, "everyNthFrame": 1])
    }

    // MARK: - Input

    private static func cdpModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.option) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.command) { value |= 4 }
        if flags.contains(.shift) { value |= 8 }
        return value
    }

    func sendMouseEvent(_ type: String, x: Double, y: Double,
                        button: String = "left", clickCount: Int = 0,
                        deltaX: Double = 0, deltaY: Double = 0) {
        var params: [String: Any] = ["type": type, "x": x, "y": y,
                                     "button": button, "pointerType": "mouse"]
        if clickCount > 0 { params["clickCount"] = clickCount }
        if type == "mouseWheel" {
            params["deltaX"] = deltaX
            params["deltaY"] = deltaY
        }
        params["modifiers"] = Self.cdpModifiers(NSEvent.modifierFlags)
        send("Input.dispatchMouseEvent", params: params)
    }

    func sendKeyEvent(_ type: String, key: String, code: String, keyCode: Int, text: String? = nil) {
        var params: [String: Any] = ["type": type, "key": key, "code": code,
                                     "windowsVirtualKeyCode": keyCode,
                                     "nativeVirtualKeyCode": keyCode]
        if let text { params["text"] = text }
        params["modifiers"] = Self.cdpModifiers(NSEvent.modifierFlags)
        send("Input.dispatchKeyEvent", params: params)
    }

    func insertText(_ text: String) {
        send("Input.insertText", params: ["text": text])
    }

    // MARK: - Helpers

    private func wait(for condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            try? process.run()
            process.waitUntilExit()
        }
    }

    private struct OpenBotError: LocalizedError {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { description }
    }
}

/// A borderless panel that still takes the keyboard, like the scratchpad's.
final class OpenBotMirrorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
