// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PDFKit
import BandejaShared

final class ImportPDFView: PDFView {
    var didReceiveFiles: (([URL]) -> Void)?

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !fileURLs(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        didReceiveFiles?(urls)
        return true
    }
}

final class PDFDropView: NSView {
    var didReceiveFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !fileURLs(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        didReceiveFiles?(urls)
        return true
    }
}

final class DocumentCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ document: TrayDocument) {
        titleLabel.stringValue = document.title
        detailLabel.stringValue = "\(document.pages.count) \(document.pages.count == 1 ? "página" : "páginas")"
        toolTip = document.title
        setAccessibilityLabel("\(document.title), \(detailLabel.stringValue)")
    }
}

func makeLabel(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: size, weight: weight)
    return label
}

func makeButton(_ title: String, target: AnyObject, action: Selector, symbol: String? = nil) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    if let symbol {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    return button
}
