// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PDFKit

/// Renders only the requested rows. Core Graphics applies the PDF's /Rotate;
/// no thumbnail image is written into the document or used during export.
enum PageThumbnailRenderer {
    static func size(for page: PDFPage, maximum: NSSize) -> NSSize {
        guard let reference = page.pageRef else { return maximum }
        let box = reference.getBoxRect(.cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let turnsSideways = rotation == 90 || rotation == 270
        let width = turnsSideways ? box.height : box.width
        let height = turnsSideways ? box.width : box.height
        guard width > 0, height > 0 else { return maximum }
        let scale = min(maximum.width / width, maximum.height / height)
        return NSSize(width: width * scale, height: height * scale)
    }

    static func image(for page: PDFPage, maximum: NSSize) -> NSImage? {
        guard let reference = page.pageRef else { return nil }
        let size = size(for: page, maximum: maximum)
        let pixelWidth = max(1, Int(ceil(size.width * 2)))
        let pixelHeight = max(1, Int(ceil(size.height * 2)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let target = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        // getDrawingTransform already includes the CGPDFPage's /Rotate. Only add
        // a delta when PDFKit holds a different in-memory rotation.
        let extraRotation = Int32(page.rotation) - reference.rotationAngle
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: target, rotate: extraRotation, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let bitmap = context.makeImage() else { return nil }
        return NSImage(cgImage: bitmap, size: size)
    }
}

final class PageThumbnailList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var document: PDFDocument?
    private let cache = NSCache<NSNumber, NSImage>()
    private var pageObserver: NSObjectProtocol?
    private var suppressSelection = false
    private var navigatingFromSelection = false

    weak var pdfView: PDFView? {
        didSet { bindDocument() }
    }
    var thumbnailSize = NSSize(width: 78, height: 105) {
        didSet { cache.removeAllObjects(); table.reloadData() }
    }
    var selectedPages: [PDFPage]? {
        guard let document else { return nil }
        return table.selectedRowIndexes.compactMap { document.page(at: $0) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = false
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Páginas del documento")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        cache.countLimit = 40
        cache.totalCostLimit = 16 * 1024 * 1024
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) } }

    private func bindDocument() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        document = pdfView?.document
        cache.removeAllObjects()
        suppressSelection = true
        table.reloadData()
        table.deselectAll(nil)
        suppressSelection = false
        if let pdfView {
            pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                self?.synchronizeCurrentPage()
            }
        }
        synchronizeCurrentPage()
    }

    private func synchronizeCurrentPage() {
        guard !navigatingFromSelection, let document, let page = pdfView?.currentPage else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, index < document.pageCount else { return }
        // Scrolling or searching should follow the current page, while a Cmd/Shift
        // selection already containing that page must keep its other pages selected.
        if !table.selectedRowIndexes.contains(index) {
            suppressSelection = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            suppressSelection = false
        }
        table.scrollRowToVisible(index)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document?.pageCount ?? 0 }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let page = document?.page(at: row) else { return 35 }
        return PageThumbnailRenderer.size(for: page, maximum: thumbnailSize).height + 32
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let page = document?.page(at: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("PageThumbnailCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PageThumbnailCell ?? PageThumbnailCell(frame: .zero)
        cell.identifier = identifier
        let key = NSNumber(value: row)
        var image = cache.object(forKey: key)
        if image == nil {
            image = PageThumbnailRenderer.image(for: page, maximum: thumbnailSize)
            if let image { cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 16)) }
        }
        cell.configure(image: image, size: PageThumbnailRenderer.size(for: page, maximum: thumbnailSize), number: row + 1)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let document, let pdfView else { return }
        let row = table.clickedRow >= 0 && table.selectedRowIndexes.contains(table.clickedRow) ? table.clickedRow : table.selectedRow
        guard row >= 0, let page = document.page(at: row) else { return }
        navigatingFromSelection = true
        pdfView.go(to: page)
        navigatingFromSelection = false
    }
}

private final class PageThumbnailCell: NSTableCellView {
    private let pageImage = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private var imageWidth: NSLayoutConstraint!
    private var imageHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pageImage.translatesAutoresizingMaskIntoConstraints = false
        pageImage.imageScaling = .scaleProportionallyUpOrDown
        pageImage.wantsLayer = true
        pageImage.layer?.borderWidth = 0.5
        pageImage.layer?.borderColor = NSColor.separatorColor.cgColor
        number.translatesAutoresizingMaskIntoConstraints = false
        number.font = .systemFont(ofSize: 11)
        number.alignment = .center
        addSubview(pageImage)
        addSubview(number)
        imageWidth = pageImage.widthAnchor.constraint(equalToConstant: 78)
        imageHeight = pageImage.heightAnchor.constraint(equalToConstant: 105)
        NSLayoutConstraint.activate([
            pageImage.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageImage.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageWidth, imageHeight,
            number.topAnchor.constraint(equalTo: pageImage.bottomAnchor, constant: 4),
            number.centerXAnchor.constraint(equalTo: centerXAnchor),
            number.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: NSImage?, size: NSSize, number page: Int) {
        pageImage.image = image
        imageWidth.constant = size.width
        imageHeight.constant = size.height
        number.stringValue = String(page)
        toolTip = "Página \(page)"
        setAccessibilityLabel("Página \(page)")
    }
}
