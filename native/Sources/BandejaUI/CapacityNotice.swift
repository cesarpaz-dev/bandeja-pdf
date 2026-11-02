// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import BandejaShared

/// Its state is stored by the agent. This window never uses macOS notifications.
final class CapacityNoticeController: NSWindowController, NSWindowDelegate {
    private let heading = makeLabel("Las dos bandejas están llenas", size: 21, weight: .semibold)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let count = makeLabel("", size: 13, weight: .medium)
    private var displayedVersion = -1
    private var acceptedButton: NSButton!
    var acknowledge: ((Int) -> Void)?
    var showTrays: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 245), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Bandeja PDF — capacidad"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        message.font = .systemFont(ofSize: 14)
        message.maximumNumberOfLines = 0
        count.textColor = .secondaryLabelColor
        let showButton = makeButton("Ver bandejas", target: self, action: #selector(showDocuments))
        acceptedButton = makeButton("Aceptar", target: self, action: #selector(acceptNotice))
        acceptedButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [showButton, acceptedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [heading, message, count, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 17
        stack.edgeInsets = NSEdgeInsets(top: 25, left: 25, bottom: 25, right: 25)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                message.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -50)
            ])
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: TraySnapshot, forcePresentation: Bool = false) {
        guard snapshot.noticePending else {
            window?.orderOut(nil)
            return
        }
        let changed = displayedVersion != snapshot.noticeVersion
        displayedVersion = snapshot.noticeVersion
        acceptedButton.isEnabled = true
        let isFull = snapshot.inbox.count >= 10 && snapshot.waiting.count >= 10
        if snapshot.discarded > 0 {
            heading.stringValue = "Se descartaron impresiones"
            message.stringValue = "Se descartaron \(snapshot.discarded) \(snapshot.discarded == 1 ? "impresión" : "impresiones") porque las dos bandejas estaban llenas. Libera espacio y vuelve a imprimir esos documentos. Aceptar este aviso no los recupera."
        } else {
            heading.stringValue = "Las dos bandejas están llenas"
            message.stringValue = "Libera espacio; las nuevas impresiones se descartarán mientras las dos bandejas estén llenas."
        }
        count.stringValue = "Bandeja: \(snapshot.inbox.count)/10 · Espera: \(snapshot.waiting.count)/10" + (isFull ? "" : " · Ya hay espacio disponible")
        if changed || forcePresentation {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func acknowledgementFailed() { acceptedButton.isEnabled = true }
    @objc private func acceptNotice() {
        acceptedButton.isEnabled = false
        acknowledge?(displayedVersion)
    }
    @objc private func showDocuments() {
        window?.orderOut(nil)
        showTrays?()
    }
}
