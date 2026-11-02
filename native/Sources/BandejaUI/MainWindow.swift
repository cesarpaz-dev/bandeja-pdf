// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PDFKit
import UniformTypeIdentifiers
import BandejaShared

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private enum Tray { case inbox, waiting }
    private var client = AgentClient()
    private var state = TraySnapshot()
    private var lastRevision: Int?
    private var connected = false
    private var polling = false
    private var busy = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var selectedTray: Tray = .inbox
    private var selectedIDs: [String] = []
    private var suppressSelection = false
    private var previewToken = UUID()
    private var previewDocument: TrayDocument?
    private var desiredPage: Int?
    private var pendingImports: [URL] = []
    private var searchMatches: [PDFSelection] = []
    private var matchIndex = 0
    private let notice = CapacityNoticeController()

    private let inboxTable = NSTableView()
    private let waitingTable = NSTableView()
    private let inboxHeading = makeLabel("Bandeja · 0/10", size: 14, weight: .semibold)
    private let waitingHeading = makeLabel("Espera · 0/10", size: 14, weight: .semibold)
    private let documentHeading = makeLabel("Tus documentos, a mano", size: 18, weight: .semibold)
    private let documentDetail = makeLabel("", size: 12)
    private let connectionLabel = makeLabel("Conectando…", size: 12)
    private let activityLabel = makeLabel("", size: 12)
    private let pageLabel = makeLabel("", size: 11)
    private let searchLabel = makeLabel("", size: 11)
    private let searchField = NSSearchField()
    private let receiverErrorLabel = NSTextField(wrappingLabelWithString: "")
    private var receiverErrorBanner: NSStackView!
    private var receiverErrorButton: NSButton!
    private let pdfView = ImportPDFView()
    private let thumbnails = PageThumbnailList()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Abre un PDF, arrástralo aquí o imprime hacia Bandeja PDF.")
    private var importButton: NSButton!
    private var exportButton: NSButton!
    private var mergeButton: NSButton!
    private var deleteButton: NSButton!
    private var clearButton: NSButton!
    private var undoButton: NSButton!
    private var printButton: NSButton!
    private var pageButtons: [NSButton] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1190, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bandeja PDF"
        window.minSize = NSSize(width: 1080, height: 630)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BandejaPDFMainWindow")
        super.init(window: window)
        buildInterface()
        notice.acknowledge = { [weak self] version in self?.acknowledgeNotice(version) }
        notice.showTrays = { [weak self] in self?.present(showNotice: false) }
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in self?.updatePageLabel() })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.fetchSnapshot() }
        updateControls()
        fetchSnapshot()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func present(showNotice: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if showNotice { notice.update(state, forcePresentation: true) }
        fetchSnapshot()
    }

    private func buildInterface() {
        guard let window else { return }
        let content = PDFDropView(frame: .zero)
        content.didReceiveFiles = { [weak self] urls in self?.importFiles(urls) }
        window.contentView = content

        importButton = makeButton("Abrir PDF…", target: self, action: #selector(openPDF(_:)), symbol: "plus")
        exportButton = makeButton("Guardar PDF…", target: self, action: #selector(exportPDF(_:)), symbol: "square.and.arrow.up")
        mergeButton = makeButton("Unir", target: self, action: #selector(mergeDocuments(_:)), symbol: "doc.on.doc")
        mergeButton.toolTip = "Unir los documentos seleccionados, en el orden de la bandeja, dentro del primero."
        deleteButton = makeButton("Eliminar…", target: self, action: #selector(deleteDocuments(_:)), symbol: "trash")
        clearButton = makeButton("Vaciar…", target: self, action: #selector(clearTrays(_:)))
        undoButton = makeButton("Deshacer", target: self, action: #selector(undoPages(_:)), symbol: "arrow.uturn.backward")
        printButton = makeButton("Imprimir…", target: self, action: #selector(printPDF(_:)), symbol: "printer")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [importButton, exportButton, mergeButton, undoButton, spacer, deleteButton, clearButton, printButton])
        actions.orientation = .horizontal
        actions.spacing = 9
        actions.edgeInsets = NSEdgeInsets(top: 11, left: 15, bottom: 11, right: 15)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebar = makeSidebar()
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(makePreview())
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let initialSidebar = sidebar.widthAnchor.constraint(equalToConstant: 270)
        initialSidebar.priority = .defaultLow
        initialSidebar.isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        connectionLabel.textColor = .secondaryLabelColor
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingMiddle
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [connectionLabel, statusSpacer, activityLabel])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        receiverErrorLabel.font = .systemFont(ofSize: 13)
        receiverErrorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        receiverErrorLabel.maximumNumberOfLines = 3
        receiverErrorButton = makeButton("Entendido", target: self, action: #selector(acknowledgeReceiverError(_:)))
        receiverErrorBanner = NSStackView(views: [receiverErrorLabel, receiverErrorButton])
        receiverErrorBanner.orientation = .horizontal
        receiverErrorBanner.spacing = 14
        receiverErrorBanner.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        receiverErrorBanner.wantsLayer = true
        receiverErrorBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        receiverErrorBanner.isHidden = true
        let layout = NSStackView(views: [actions, receiverErrorBanner, split, footer])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        for view in layout.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            layout.topAnchor.constraint(equalTo: content.topAnchor),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        let helper = NSTextField(wrappingLabelWithString: "Selecciona varios documentos con ⌘ o ⇧ para unirlos.")
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        let waitingHelper = NSTextField(wrappingLabelWithString: "Los documentos en espera entran al liberar espacio en la bandeja.")
        waitingHelper.font = .systemFont(ofSize: 11)
        waitingHelper.textColor = .secondaryLabelColor
        let inboxScroll = makeTable(inboxTable, name: "Bandeja principal")
        let waitingScroll = makeTable(waitingTable, name: "Documentos en espera")
        sidebar.addArrangedSubview(inboxHeading)
        sidebar.addArrangedSubview(helper)
        sidebar.addArrangedSubview(inboxScroll)
        sidebar.addArrangedSubview(waitingHeading)
        sidebar.addArrangedSubview(waitingHelper)
        sidebar.addArrangedSubview(waitingScroll)
        for view in sidebar.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
        }
        inboxScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        waitingScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
        let proportion = inboxScroll.heightAnchor.constraint(equalTo: waitingScroll.heightAnchor, multiplier: 1.65)
        proportion.priority = .defaultLow
        proportion.isActive = true
        return sidebar
    }

    private func makeTable(_ table: NSTableView, name: String) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 55
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(name)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    private func makePreview() -> NSView {
        documentHeading.lineBreakMode = .byTruncatingMiddle
        documentHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        documentDetail.textColor = .secondaryLabelColor
        searchField.placeholderString = "Buscar texto en el PDF"
        searchField.target = self
        searchField.action = #selector(searchPDF(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(equalToConstant: 215).isActive = true
        let previous = makeButton("", target: self, action: #selector(previousMatch(_:)), symbol: "chevron.up")
        previous.toolTip = "Coincidencia anterior"
        let next = makeButton("", target: self, action: #selector(nextMatch(_:)), symbol: "chevron.down")
        next.toolTip = "Siguiente coincidencia"
        let search = NSStackView(views: [searchField, previous, next])
        search.orientation = .horizontal
        search.spacing = 3
        let title = NSStackView(views: [documentHeading, documentDetail])
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 4
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, search])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 14)

        let rotate = makeButton("Girar", target: self, action: #selector(rotatePages(_:)), symbol: "rotate.right")
        rotate.toolTip = "Girar 90° las páginas seleccionadas en las miniaturas."
        let extract = makeButton("Extraer", target: self, action: #selector(extractPages(_:)), symbol: "doc.badge.plus")
        extract.toolTip = "Mover las páginas seleccionadas a un documento nuevo."
        let transfer = makeButton("Agregar a…", target: self, action: #selector(transferPages(_:)))
        transfer.toolTip = "Mover o copiar las páginas seleccionadas a otro documento de la bandeja."
        let remove = makeButton("Quitar páginas…", target: self, action: #selector(deletePages(_:)))
        let before = makeButton("", target: self, action: #selector(movePagesEarlier(_:)), symbol: "arrow.up")
        before.toolTip = "Mover las páginas seleccionadas una posición antes."
        let after = makeButton("", target: self, action: #selector(movePagesLater(_:)), symbol: "arrow.down")
        after.toolTip = "Mover las páginas seleccionadas una posición después."
        pageButtons = [rotate, extract, transfer, remove, before, after]
        let plus = makeButton("", target: self, action: #selector(zoomIn(_:)), symbol: "plus.magnifyingglass")
        plus.toolTip = "Aumentar vista"
        let minus = makeButton("", target: self, action: #selector(zoomOut(_:)), symbol: "minus.magnifyingglass")
        minus.toolTip = "Reducir vista"
        let fit = makeButton("Ajustar", target: self, action: #selector(fitPage(_:)))
        let pageSpacer = NSView()
        pageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pageActions = NSStackView(views: [rotate, extract, transfer, remove, before, after, pageSpacer, minus, plus, fit])
        pageActions.orientation = .horizontal
        pageActions.spacing = 6
        pageActions.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 10, right: 12)
        pageActions.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        pageActions.setContentCompressionResistancePriority(.required, for: .vertical)

        pdfView.autoScales = true
        pdfView.didReceiveFiles = { [weak self] urls in self?.importFiles(urls) }
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .underPageBackgroundColor
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 78, height: 105)
        thumbnails.widthAnchor.constraint(equalToConstant: 108).isActive = true
        let viewer = NSStackView(views: [thumbnails, pdfView])
        viewer.orientation = .horizontal
        viewer.alignment = .top
        viewer.spacing = 1
        viewer.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.addSubview(viewer)
        for view in viewer.arrangedSubviews {
            view.heightAnchor.constraint(equalTo: viewer.heightAnchor).isActive = true
        }
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 16)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            viewer.topAnchor.constraint(equalTo: host.topAnchor),
            viewer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 430)
        ])
        let hint = makeLabel("Miniaturas: ⌘ o ⇧ para seleccionar varias páginas.", size: 11)
        hint.textColor = .secondaryLabelColor
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let details = NSStackView(views: [hint, bottomSpacer, searchLabel, pageLabel])
        details.orientation = .horizontal
        details.spacing = 12
        details.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        let preview = NSStackView(views: [header, pageActions, host, details])
        preview.orientation = .vertical
        preview.alignment = .leading
        preview.spacing = 0
        preview.setCustomSpacing(4, after: pageActions)
        for view in preview.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        }
        return preview
    }

    private var selectedDocuments: [TrayDocument] {
        documents(in: selectedTray).filter { selectedIDs.contains($0.id) }
    }
    private var currentDocument: TrayDocument? { selectedDocuments.first }
    private var canEditPages: Bool { connected && busy == 0 && selectedTray == .inbox && selectedIDs.count == 1 && pdfView.document != nil && previewDocument?.id == currentDocument?.id }
    private func documents(in tray: Tray) -> [TrayDocument] { tray == .inbox ? state.inbox : state.waiting }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === inboxTable ? state.inbox.count : state.waiting.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let documents = tableView === inboxTable ? state.inbox : state.waiting
        guard documents.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DocumentCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DocumentCell ?? DocumentCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(documents[row])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let table = notification.object as? NSTableView else { return }
        selectedTray = table === inboxTable ? .inbox : .waiting
        selectedIDs = table.selectedRowIndexes.compactMap { index in
            let docs = documents(in: selectedTray)
            return docs.indices.contains(index) ? docs[index].id : nil
        }
        suppressSelection = true
        (table === inboxTable ? waitingTable : inboxTable).deselectAll(nil)
        suppressSelection = false
        desiredPage = nil
        updatePreview()
        updateControls()
    }

    private func fetchSnapshot() {
        guard !polling else { return }
        polling = true
        if !connected { client = AgentClient() }
        client.send(AgentRequest("snapshot")) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                if response.ok, let snapshot = response.snapshot {
                    self.connected = true
                    self.apply(snapshot)
                    self.processNextImport()
                } else {
                    self.connected = false
                    self.connectionLabel.stringValue = "Sin conexión. Volviendo a intentar…"
                    self.connectionLabel.toolTip = response.message
                    self.updateControls()
                }
            }
        }
    }

    private func apply(_ snapshot: TraySnapshot) {
        if let lastRevision, snapshot.revision < lastRevision { return }
        connected = true
        connectionLabel.stringValue = snapshot.receiverStatus
        connectionLabel.toolTip = nil
        notice.update(snapshot)
        receiverErrorBanner.isHidden = snapshot.lastError == nil
        receiverErrorLabel.stringValue = snapshot.lastError ?? ""
        receiverErrorLabel.toolTip = snapshot.lastError
        receiverErrorButton.isEnabled = true
        guard lastRevision != snapshot.revision else {
            state = snapshot
            updateControls()
            return
        }
        state = snapshot
        lastRevision = snapshot.revision
        inboxHeading.stringValue = "Bandeja · \(snapshot.inbox.count)/10"
        waitingHeading.stringValue = "Espera · \(snapshot.waiting.count)/10"
        selectedIDs = selectedIDs.filter { id in documents(in: selectedTray).contains { $0.id == id } }
        if selectedIDs.isEmpty {
            if let first = snapshot.inbox.first { selectedTray = .inbox; selectedIDs = [first.id] }
            else if let first = snapshot.waiting.first { selectedTray = .waiting; selectedIDs = [first.id] }
        }
        refreshTables()
        updatePreview()
        updateControls()
    }

    private func refreshTables() {
        suppressSelection = true
        inboxTable.reloadData()
        waitingTable.reloadData()
        inboxTable.deselectAll(nil)
        waitingTable.deselectAll(nil)
        let docs = documents(in: selectedTray)
        let indices = IndexSet(docs.indices.filter { selectedIDs.contains(docs[$0].id) })
        (selectedTray == .inbox ? inboxTable : waitingTable).selectRowIndexes(indices, byExtendingSelection: false)
        suppressSelection = false
    }

    private func selectDocument(id: String) {
        if state.inbox.contains(where: { $0.id == id }) { selectedTray = .inbox }
        else if state.waiting.contains(where: { $0.id == id }) { selectedTray = .waiting }
        else { return }
        selectedIDs = [id]
        refreshTables()
        updatePreview()
        updateControls()
    }

    private func updatePreview() {
        guard let document = currentDocument else {
            previewToken = UUID()
            previewDocument = nil
            thumbnails.pdfView = nil
            pdfView.document = nil
            emptyLabel.stringValue = "Abre un PDF, arrástralo aquí o imprime hacia Bandeja PDF."
            emptyLabel.isHidden = false
            documentHeading.stringValue = "Tus documentos, a mano"
            documentDetail.stringValue = ""
            pageLabel.stringValue = ""
            return
        }
        documentHeading.stringValue = selectedIDs.count > 1 ? "\(selectedIDs.count) documentos seleccionados" : document.title
        documentHeading.toolTip = document.title
        let status: String
        switch document.textStatus {
        case "text": status = "Texto seleccionable"
        case "partial": status = "Texto parcial"
        default: status = "Sin texto seleccionable"
        }
        documentDetail.stringValue = "\(document.pages.count) \(document.pages.count == 1 ? "página" : "páginas") · \(status)" + (selectedTray == .waiting ? " · En espera" : "")
        documentDetail.toolTip = document.textStatus == "none" ? "El documento recibido no contiene texto extraíble. La vista conserva su contenido." : "Describe la disponibilidad de texto extraíble; no verifica su exactitud."
        if let previewDocument, previewDocument.id == document.id, previewDocument.pages == document.pages, pdfView.document != nil { return }
        let previousPage = desiredPage ?? currentPageIndex()
        desiredPage = nil
        let token = UUID()
        previewToken = token
        previewDocument = nil
        thumbnails.pdfView = nil
        pdfView.document = nil
        emptyLabel.stringValue = "Preparando vista previa…"
        emptyLabel.isHidden = false
        searchMatches = []
        searchLabel.stringValue = ""
        var request = AgentRequest("preview")
        request.documentIDs = [document.id]
        client.send(request) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.previewToken == token, self.currentDocument?.id == document.id else { return }
                guard response.ok, let path = response.path, let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else {
                    self.emptyLabel.stringValue = response.message ?? "No se pudo abrir la vista previa."
                    self.updateControls()
                    return
                }
                self.previewDocument = document
                // Rebind to discard the previous document's thumbnail cache.
                self.thumbnails.pdfView = nil
                self.pdfView.document = pdf
                self.pdfView.autoScales = true
                self.emptyLabel.isHidden = true
                if let page = pdf.page(at: min(max(0, previousPage), max(0, pdf.pageCount - 1))) { self.pdfView.go(to: page) }
                self.thumbnails.pdfView = self.pdfView
                self.thumbnails.needsLayout = true
                self.thumbnails.needsDisplay = true
                self.updatePageLabel()
                self.updateControls()
            }
        }
    }

    private func updateControls() {
        let ready = connected && busy == 0
        importButton?.isEnabled = ready
        exportButton?.isEnabled = ready && selectedIDs.count == 1
        mergeButton?.isEnabled = ready && selectedTray == .inbox && selectedIDs.count >= 2
        deleteButton?.isEnabled = ready && !selectedIDs.isEmpty
        clearButton?.isEnabled = ready && (!state.inbox.isEmpty || !state.waiting.isEmpty)
        undoButton?.isEnabled = ready && state.canUndo
        printButton?.isEnabled = ready && selectedIDs.count == 1 && pdfView.document != nil
        pageButtons.forEach { $0.isEnabled = canEditPages }
        searchField.isEnabled = pdfView.document != nil
        if busy > 0 { activityLabel.stringValue = "Procesando…" }
    }

    private func currentPageIndex() -> Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        let index = document.index(for: page)
        return index == NSNotFound ? 0 : index
    }
    private func selectedPageIndices() -> [Int] {
        guard let document = pdfView.document else { return [] }
        let selected = (thumbnails.selectedPages ?? []).map { document.index(for: $0) }.filter { $0 >= 0 && $0 < document.pageCount }
        return selected.isEmpty ? [currentPageIndex()] : Array(Set(selected)).sorted()
    }
    private func updatePageLabel() {
        guard let document = pdfView.document else { pageLabel.stringValue = ""; return }
        pageLabel.stringValue = "Página \(currentPageIndex() + 1) de \(document.pageCount)"
    }

    private func perform(_ request: AgentRequest, selectNewDocument: Bool = false, completion: ((AgentResponse) -> Void)? = nil) {
        let existing = Set(state.inbox.map(\.id) + state.waiting.map(\.id))
        busy += 1
        updateControls()
        client.send(request) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = max(0, self.busy - 1)
                self.activityLabel.stringValue = ""
                if let snapshot = response.snapshot {
                    self.apply(snapshot)
                    if selectNewDocument, let added = (snapshot.inbox + snapshot.waiting).first(where: { !existing.contains($0.id) }) { self.selectDocument(id: added.id) }
                } else { self.fetchSnapshot() }
                if !response.ok { self.showError(response.message ?? "No se pudo completar la operación.") }
                self.updateControls()
                completion?(response)
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { showError("Selecciona archivos PDF."); return }
        pendingImports.append(contentsOf: pdfs)
        processNextImport()
        if !connected { fetchSnapshot() }
    }
    private func processNextImport() {
        guard connected, busy == 0, !pendingImports.isEmpty else { return }
        let url = pendingImports.removeFirst()
        var request = AgentRequest("import")
        request.path = url.path
        request.title = url.deletingPathExtension().lastPathComponent
        perform(request, selectNewDocument: true) { [weak self] response in
            guard let self else { return }
            if response.ok { self.processNextImport() }
            else { self.pendingImports.removeAll() }
        }
    }

    @objc func openPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Añadir documentos a la bandeja"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importFiles(panel.urls) }
        }
    }
    @objc func exportPDF(_ sender: Any?) {
        guard selectedIDs.count == 1, let document = currentDocument, let window else { return }
        let panel = NSSavePanel()
        panel.title = "Guardar PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.title.hasSuffix(".pdf") ? document.title : document.title + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            var request = AgentRequest("export")
            request.documentIDs = [document.id]
            request.path = url.path
            self.perform(request) { response in if response.ok { self.activityLabel.stringValue = "PDF guardado" } }
        }
    }
    @objc func mergeDocuments(_ sender: Any?) {
        guard connected, busy == 0, selectedTray == .inbox, selectedIDs.count >= 2 else { return }
        let ids = selectedDocuments.map(\.id)
        var request = AgentRequest("merge")
        request.documentIDs = ids
        request.targetID = ids.first
        desiredPage = 0
        perform(request) { [weak self] response in
            if response.ok, let first = ids.first { self?.selectDocument(id: first) }
        }
    }
    @objc func rotatePages(_ sender: Any?) {
        guard canEditPages, let document = currentDocument else { return }
        var request = AgentRequest("rotate")
        request.documentIDs = [document.id]
        request.pageIndices = selectedPageIndices()
        request.degrees = 90
        desiredPage = request.pageIndices.first
        perform(request)
    }
    @objc func extractPages(_ sender: Any?) {
        guard canEditPages, let document = currentDocument else { return }
        var request = AgentRequest("extract")
        request.documentIDs = [document.id]
        request.pageIndices = selectedPageIndices()
        request.title = document.title + " — páginas extraídas"
        desiredPage = 0
        perform(request, selectNewDocument: true)
    }
    @objc private func transferPages(_ sender: Any?) {
        guard canEditPages, let document = currentDocument else { return }
        let destinations = state.inbox.filter { $0.id != document.id }
        guard !destinations.isEmpty else {
            showError("Añade otro documento a la bandeja para recibir estas páginas. También puedes usar Extraer para crear uno nuevo.")
            return
        }
        let pages = selectedPageIndices()
        let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28), pullsDown: false)
        for destination in destinations {
            chooser.addItem(withTitle: destination.title)
            chooser.lastItem?.representedObject = destination.id
        }
        let copy = NSButton(checkboxWithTitle: "Conservar las páginas en el documento original", target: nil, action: nil)
        let accessory = NSStackView(views: [chooser, copy])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 12
        accessory.frame = NSRect(x: 0, y: 0, width: 370, height: 75)
        let alert = NSAlert()
        alert.messageText = "Agregar \(pages.count) \(pages.count == 1 ? "página" : "páginas") a otro documento"
        alert.informativeText = "Se añadirán al final del documento elegido. Puedes deshacer el cambio."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Agregar páginas")
        alert.addButton(withTitle: "Cancelar")
        confirm(alert) { [weak self] answer in
            guard answer == .alertFirstButtonReturn, let self, let targetID = chooser.selectedItem?.representedObject as? String else { return }
            var request = AgentRequest(copy.state == .on ? "copyPages" : "extract")
            request.documentIDs = [document.id]
            request.pageIndices = pages
            request.targetID = targetID
            let targetStart = self.state.inbox.first(where: { $0.id == targetID })?.pages.count ?? 0
            self.perform(request) { [weak self] response in
                if response.ok {
                    self?.desiredPage = targetStart
                    self?.selectDocument(id: targetID)
                }
            }
        }
    }
    @objc func deletePages(_ sender: Any?) {
        guard canEditPages, let document = currentDocument else { return }
        let pages = selectedPageIndices()
        let alert = NSAlert()
        alert.messageText = "¿Quitar \(pages.count) \(pages.count == 1 ? "página" : "páginas")?"
        alert.informativeText = "Puedes revertir este cambio con Deshacer. Si el documento queda sin páginas, se retirará de la bandeja."
        alert.addButton(withTitle: "Quitar páginas")
        alert.addButton(withTitle: "Cancelar")
        confirm(alert) { [weak self] answer in
            guard answer == .alertFirstButtonReturn, let self else { return }
            var request = AgentRequest("deletePages")
            request.documentIDs = [document.id]
            request.pageIndices = pages
            self.desiredPage = pages.first
            self.perform(request)
        }
    }
    @objc func movePagesEarlier(_ sender: Any?) { movePages(direction: -1) }
    @objc func movePagesLater(_ sender: Any?) { movePages(direction: 1) }
    private func movePages(direction: Int) {
        guard canEditPages, let document = currentDocument else { return }
        let selected = Set(selectedPageIndices())
        var order = Array(document.pages.indices)
        let positions = direction < 0 ? Array(order.indices) : Array(order.indices.reversed())
        for index in positions {
            let neighbor = index + direction
            if order.indices.contains(neighbor), selected.contains(order[index]), !selected.contains(order[neighbor]) { order.swapAt(index, neighbor) }
        }
        guard order != Array(document.pages.indices) else { return }
        var request = AgentRequest("reorder")
        request.documentIDs = [document.id]
        request.pageIndices = order
        desiredPage = order.firstIndex(where: { selected.contains($0) })
        perform(request)
    }
    @objc func deleteDocuments(_ sender: Any?) {
        guard connected, busy == 0, !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Eliminar \(ids.count) \(ids.count == 1 ? "documento" : "documentos")?"
        alert.informativeText = "Se eliminarán definitivamente de la app y se borrará todo el historial de Deshacer. Los PDF que hayas guardado fuera de la app no se borrarán."
        alert.addButton(withTitle: "Eliminar definitivamente")
        alert.addButton(withTitle: "Cancelar")
        confirm(alert) { [weak self] answer in
            guard answer == .alertFirstButtonReturn else { return }
            var request = AgentRequest("delete")
            request.documentIDs = ids
            self?.perform(request)
        }
    }
    @objc func clearTrays(_ sender: Any?) {
        guard connected, busy == 0, !state.inbox.isEmpty || !state.waiting.isEmpty else { return }
        let inboxIDs = state.inbox.map(\.id)
        let waitingIDs = state.waiting.map(\.id)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Vaciar los documentos?"
        alert.informativeText = "Bandeja: \(inboxIDs.count) documentos. Espera: \(waitingIDs.count). La eliminación es definitiva dentro de la app y borra todo el historial de Deshacer. Al vaciar solo la bandeja, los documentos en espera pasarán a ella. Las nuevas llegadas se conservarán."
        alert.addButton(withTitle: "Vaciar solo la bandeja")
        alert.addButton(withTitle: "Cancelar")
        if !waitingIDs.isEmpty { alert.addButton(withTitle: "Vaciar bandeja y espera") }
        confirm(alert) { [weak self] answer in
            guard answer == .alertFirstButtonReturn || answer == .alertThirdButtonReturn else { return }
            // Delete exactly the documents shown in the confirmation. A new print
            // arriving while the sheet is open must not be swept into this action.
            var request = AgentRequest("delete")
            request.documentIDs = inboxIDs + (answer == .alertThirdButtonReturn ? waitingIDs : [])
            guard !request.documentIDs.isEmpty else { return }
            self?.perform(request)
        }
    }
    @objc func undoPages(_ sender: Any?) {
        guard connected, busy == 0, state.canUndo else { return }
        perform(AgentRequest("undo"))
    }
    private func acknowledgeNotice(_ version: Int) {
        var request = AgentRequest("ackNotice")
        request.noticeVersion = version
        client.send(request) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot = response.snapshot { self.apply(snapshot) }
                if !response.ok {
                    self.notice.acknowledgementFailed()
                    self.showError(response.message ?? "No se pudo confirmar el aviso. Se conserva pendiente.")
                } else { self.fetchSnapshot() }
            }
        }
    }

    @objc private func acknowledgeReceiverError(_ sender: Any?) {
        guard let errorID = state.errorID else { return }
        var request = AgentRequest("ackError")
        request.errorID = errorID
        receiverErrorButton.isEnabled = false
        client.send(request) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                self.receiverErrorButton.isEnabled = true
                if let snapshot = response.snapshot { self.apply(snapshot) }
                else { self.fetchSnapshot() }
                if !response.ok { self.showError(response.message ?? "No se pudo confirmar el aviso de error.") }
            }
        }
    }

    @objc func showTrays(_ sender: Any?) { present() }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func fitPage(_ sender: Any?) { pdfView.autoScales = true }
    @objc func focusSearch(_ sender: Any?) { window?.makeFirstResponder(searchField) }
    @objc private func searchPDF(_ sender: Any?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = pdfView.document, !query.isEmpty else {
            searchMatches = []; searchLabel.stringValue = ""; pdfView.clearSelection(); return
        }
        searchMatches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matchIndex = 0
        showMatch()
    }
    @objc private func previousMatch(_ sender: Any?) {
        guard !searchMatches.isEmpty else { searchPDF(sender); return }
        matchIndex = (matchIndex - 1 + searchMatches.count) % searchMatches.count
        showMatch()
    }
    @objc private func nextMatch(_ sender: Any?) {
        guard !searchMatches.isEmpty else { searchPDF(sender); return }
        matchIndex = (matchIndex + 1) % searchMatches.count
        showMatch()
    }
    private func showMatch() {
        guard !searchMatches.isEmpty else { searchLabel.stringValue = "Sin coincidencias"; pdfView.clearSelection(); return }
        let selection = searchMatches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        searchLabel.stringValue = "\(matchIndex + 1) de \(searchMatches.count)"
    }

    @objc func printPDF(_ sender: Any?) {
        guard connected, busy == 0, selectedIDs.count == 1, let document = pdfView.document else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let panel = NSPrintPanel()
        guard panel.runModal(with: info) == NSApplication.ModalResponse.OK.rawValue else { return }
        // Validate the printer chosen in the dialog, before starting any print operation.
        let name = info.printer.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let compact = name.filter { $0.isLetter || $0.isNumber }
        guard !compact.contains("bandejapdf") else {
            showError("Elige otra impresora. Imprimir hacia Bandeja PDF desde esta misma app crearía una nueva entrada en la bandeja.")
            return
        }
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            showError("No se pudo preparar la impresión."); return
        }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = true
        if !operation.run() { activityLabel.stringValue = "La impresión no se completó" }
    }

    private func confirm(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo completar la acción"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { activityLabel.stringValue = message; activityLabel.toolTip = message }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let ready = connected && busy == 0
        switch menuItem.action {
        case #selector(openPDF(_:)): return ready
        case #selector(exportPDF(_:)): return ready && selectedIDs.count == 1
        case #selector(printPDF(_:)): return ready && selectedIDs.count == 1 && pdfView.document != nil
        case #selector(mergeDocuments(_:)): return ready && selectedTray == .inbox && selectedIDs.count >= 2
        case #selector(deleteDocuments(_:)): return ready && !selectedIDs.isEmpty
        case #selector(undoPages(_:)): return ready && state.canUndo
        case #selector(focusSearch(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(fitPage(_:)): return pdfView.document != nil
        default: return true
        }
    }
}
