// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit
import BandejaShared

/// Owned by the agent. Every call, including snapshot(), must use its serial queue.
public final class TrayStore {
    private let root: URL
    private let ghostscript: URL?
    private let database: StateDatabase
    private var state: StoreState
    private var receiverStatus = "Iniciando receptor"
    private var history: [UndoRecord] = []
    private var failurePreserved = false
    private let manager = FileManager.default
    private let marker = "BandejaPDF asset v1\n"

    private struct UndoRecord {
        var inbox: [TrayDocument]
        var waiting: [TrayDocument]
        var affected: Set<String>
    }

    public init(root: URL, ghostscript: URL?) throws {
        self.root = root.standardizedFileURL
        self.ghostscript = ghostscript
        if FileManager.default.fileExists(atPath: root.path),
           (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw TrayError.message("La carpeta de la bandeja no puede ser un enlace simbólico.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["assets", "previews", "failures"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path),
               (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw TrayError.message("Una carpeta de almacenamiento no es válida.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let dbURL = root.appendingPathComponent("tray.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path),
           (try dbURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw TrayError.message("El índice de la bandeja no puede ser un enlace simbólico.")
        }
        self.database = try StateDatabase(url: dbURL)
        self.state = try database.load() ?? StoreState()
        guard state.schema == 1, state.inbox.count <= 10, state.waiting.count <= 10 else {
            throw TrayError.message("La versión o capacidad del almacenamiento no es válida.")
        }
        for document in state.inbox + state.waiting {
            guard !document.pages.isEmpty else { throw TrayError.message("El índice contiene un documento vacío.") }
            for ref in document.pages {
                guard let asset = state.assets[ref.assetID], UUID(uuidString: ref.assetID) != nil,
                      ref.index >= 0, ref.index < asset.pageHasText.count,
                      FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/\(ref.assetID)/content.pdf").path) else {
                    throw TrayError.message("Faltan archivos de la bandeja. Conserva la carpeta y revisa el almacenamiento.")
                }
            }
        }
        // Session undo is deliberately not restored after an agent restart.
    }

    public func setReceiverStatus(_ status: String) { receiverStatus = status }

    public func snapshot() -> TraySnapshot {
        var snapshot = TraySnapshot()
        snapshot.inbox = state.inbox; snapshot.waiting = state.waiting
        snapshot.discarded = state.discarded; snapshot.noticePending = state.noticePending
        snapshot.noticeVersion = state.noticeVersion; snapshot.revision = state.revision
        snapshot.canUndo = !history.isEmpty; snapshot.receiverStatus = receiverStatus
        snapshot.lastError = state.lastError; snapshot.errorID = state.errorID
        return snapshot
    }

    public func execute(_ request: AgentRequest) -> AgentResponse {
        failurePreserved = false
        do {
            switch request.operation {
            case "snapshot": return response()
            case "import", "ingest": return try receive(request)
            case "preview":
                let document = try findDocument(request.documentIDs.first)
                return response(path: try materialize(document).path)
            case "export":
                let document = try findDocument(request.documentIDs.first)
                guard let path = request.path, path.hasPrefix("/") else { throw TrayError.message("Elige dónde guardar el PDF.") }
                let destination = URL(fileURLWithPath: path).standardizedFileURL
                let resolved = destination.resolvingSymlinksInPath().path
                let owned = root.resolvingSymlinksInPath().path
                guard resolved != owned, !resolved.hasPrefix(owned + "/") else { throw TrayError.message("Elige un destino fuera del almacenamiento interno.") }
                try PDFFiles.copyAtomically(materialize(document), to: destination)
                return response(path: destination.path)
            case "ackNotice":
                guard request.noticeVersion == state.noticeVersion else { return response(message: "Hay un aviso más reciente. Revisa el estado actual.") }
                var candidate = state; candidate.noticePending = false; candidate.discarded = 0
                try commit(candidate, undo: history)
                return response()
            case "ackError":
                guard request.errorID == state.errorID, request.errorID != nil else { return response(message: "Hay un error más reciente. Revisa el estado actual.") }
                var candidate = state; candidate.lastError = nil; candidate.errorID = nil
                try commit(candidate, undo: history)
                return response()
            case "delete", "deleteDocuments":
                guard !request.documentIDs.isEmpty else { throw TrayError.message("Selecciona documentos para eliminar.") }
                for id in request.documentIDs { _ = try findDocument(id) }
                var candidate = state
                let ids = Set(request.documentIDs)
                candidate.inbox.removeAll { ids.contains($0.id) }
                candidate.waiting.removeAll { ids.contains($0.id) }
                promote(&candidate)
                try commit(candidate, undo: [])
                return response()
            case "clear":
                var candidate = state
                candidate.inbox = []
                if request.includeWaiting { candidate.waiting = [] }
                promote(&candidate)
                try commit(candidate, undo: [])
                return response()
            case "undo": return try undoLast()
            case "rotate", "reorder", "extract", "deletePages", "merge", "rename", "copyPages":
                return try edit(request)
            default: throw TrayError.message("La operación solicitada no está disponible.")
            }
        } catch {
            if request.operation == "ingest" {
                if !failurePreserved, let path = request.path {
                    let destination = root.appendingPathComponent("failures/\(UUID().uuidString)")
                    do {
                        try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        let original = destination.appendingPathComponent("original.document")
                        try manager.copyItem(at: URL(fileURLWithPath: path), to: original)
                        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
                        try PDFFiles.durable(original)
                        try error.localizedDescription.write(to: destination.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
                    } catch { /* Disk failure cannot be repaired by reporting success. */ }
                }
                var failed = state
                let name = cleanTitle(request.title ?? "Impresión")
                failed.lastError = "No se incorporó \(name): \(error.localizedDescription)"
                failed.errorID = UUID().uuidString
                failed.revision += 1
                // If storage is unavailable, the error remains visible in this session.
                try? database.save(failed)
                state = failed
            }
            return AgentResponse(ok: false, message: error.localizedDescription, snapshot: snapshot(), disposition: "failed")
        }
    }

    private func response(message: String? = nil, path: String? = nil, disposition: String? = nil) -> AgentResponse {
        AgentResponse(message: message, snapshot: snapshot(), path: path, disposition: disposition)
    }
    private func findDocument(_ id: String?) throws -> TrayDocument {
        guard let id, let document = (state.inbox + state.waiting).first(where: { $0.id == id }) else {
            throw TrayError.message("El documento ya no está en la bandeja.")
        }
        return document
    }
    private func cleanTitle(_ title: String) -> String {
        let value = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Documento" : String(value.prefix(240))
    }
    private func promote(_ candidate: inout StoreState) {
        while candidate.inbox.count < 10 && !candidate.waiting.isEmpty { candidate.inbox.append(candidate.waiting.removeFirst()) }
    }
    private func assignOrder(_ id: String, to candidate: inout StoreState) {
        candidate.order[id] = candidate.nextOrder; candidate.nextOrder += 1
    }
    private func textStatus(_ pages: [PageReference], assets: [String: AssetRecord]) -> String {
        let count = pages.filter { ref in
            guard let flags = assets[ref.assetID]?.pageHasText, flags.indices.contains(ref.index) else { return false }
            return flags[ref.index]
        }.count
        return count == 0 ? "none" : count == pages.count ? "text" : "partial"
    }

    private func receive(_ request: AgentRequest) throws -> AgentResponse {
        guard let path = request.path, path.hasPrefix("/") else { throw TrayError.message("Falta el archivo que se debe incorporar.") }
        let source = URL(fileURLWithPath: path)
        let printing = request.operation == "ingest"
        if !printing && state.inbox.count >= 10 { throw TrayError.message("Bandeja llena. Libera espacio antes de añadir un PDF.") }
        if printing && (request.jobKey?.isEmpty ?? true) { throw TrayError.message("La impresión no tiene un identificador de recepción válido.") }
        let kind = try PDFFiles.kind(source)
        if !printing && kind != "pdf" { throw TrayError.message("Añadir documentos admite archivos PDF.") }
        let digest = try PDFFiles.digest(source)
        if printing, let key = request.jobKey, let previous = state.receipts[key] {
            guard previous.digest == digest else { throw TrayError.message("Se repitió un identificador de impresión con contenido diferente.") }
            return response(message: "Este trabajo ya fue procesado.", disposition: previous.disposition)
        }
        var candidate = state
        if printing && candidate.inbox.count == 10 && candidate.waiting.count == 10 {
            candidate.discarded += 1
            candidate.noticePending = true; candidate.noticeVersion += 1
            candidate.receipts[request.jobKey!] = JobReceipt(digest: digest, disposition: "discarded", documentID: nil)
            try commit(candidate, undo: history)
            return response(message: "Se descartó la impresión porque las dos bandejas están llenas.", disposition: "discarded")
        }
        let asset = try createAsset(source: source, kind: kind, expectedDigest: digest)
        let title = cleanTitle(request.title ?? source.deletingPathExtension().lastPathComponent)
        var document = TrayDocument(title: title, pages: asset.pageHasText.indices.map { PageReference(assetID: asset.id, index: $0) }, textStatus: "none")
        candidate.assets[asset.id] = asset
        document.textStatus = textStatus(document.pages, assets: candidate.assets)
        assignOrder(document.id, to: &candidate)
        let waiting = candidate.inbox.count >= 10
        if waiting { candidate.waiting.append(document) } else { candidate.inbox.append(document) }
        let disposition = waiting ? "waiting" : "stored"
        if printing { candidate.receipts[request.jobKey!] = JobReceipt(digest: digest, disposition: disposition, documentID: document.id) }
        if candidate.inbox.count == 10 && candidate.waiting.count == 10 {
            candidate.noticePending = true; candidate.noticeVersion += 1
        }
        do { try commit(candidate, undo: history) }
        catch {
            preserveFailed(root.appendingPathComponent("assets/\(asset.id)"), id: asset.id)
            throw error
        }
        return response(disposition: disposition)
    }

    private func preserveFailed(_ directory: URL, id: String) {
        let destination = root.appendingPathComponent("failures/\(id)")
        if manager.fileExists(atPath: directory.path), !manager.fileExists(atPath: destination.path) {
            do { try manager.moveItem(at: directory, to: destination); failurePreserved = true }
            catch { /* Keep the original in its staging directory if the move fails. */ }
        }
    }
    private func createAsset(source: URL, kind: String, expectedDigest: String) throws -> AssetRecord {
        let id = UUID().uuidString
        let incoming = root.appendingPathComponent("assets/.incoming-\(id)", isDirectory: true)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let original = incoming.appendingPathComponent("original.document")
            try manager.copyItem(at: source, to: original)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
            guard try PDFFiles.digest(original) == expectedDigest else { throw TrayError.message("El archivo cambió mientras se incorporaba. Vuelve a intentarlo.") }
            try PDFFiles.durable(original)
            let content = incoming.appendingPathComponent("content.pdf")
            if kind == "pdf" { try manager.copyItem(at: original, to: content) }
            else { try PDFFiles.convertPS(original, output: content, executable: ghostscript) }
            let asset = try PDFFiles.inspect(content, id: id, sourceKind: kind)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: content.path)
            try marker.write(to: incoming.appendingPathComponent(".owner"), atomically: true, encoding: .utf8)
            try PDFFiles.durable(content)
            try PDFFiles.durable(incoming, directory: true)
            try manager.moveItem(at: incoming, to: root.appendingPathComponent("assets/\(id)"))
            try PDFFiles.durable(root.appendingPathComponent("assets"), directory: true)
            return asset
        } catch { preserveFailed(incoming, id: id); throw error }
    }

    private func validateIndices(_ requested: [Int], count: Int, allIfEmpty: Bool = false) throws -> [Int] {
        let indices = requested.isEmpty && allIfEmpty ? Array(0..<count) : requested
        guard !indices.isEmpty, Set(indices).count == indices.count, indices.allSatisfy({ $0 >= 0 && $0 < count }) else {
            throw TrayError.message("La selección de páginas no es válida.")
        }
        return indices
    }
    private func ensureComposable(_ documents: [TrayDocument]) throws {
        for ref in documents.flatMap(\.pages) {
            guard let asset = state.assets[ref.assetID], !asset.hasWidgets, !asset.hasOutline else {
                throw TrayError.message("Esta versión permite exportar este PDF sin cambios, pero aún no editar sus formularios o marcadores.")
            }
        }
    }
    private func edit(_ request: AgentRequest) throws -> AgentResponse {
        guard let firstID = request.documentIDs.first, let index = state.inbox.firstIndex(where: { $0.id == firstID }) else {
            throw TrayError.message("Selecciona un documento de la bandeja principal.")
        }
        var candidate = state
        let original = candidate.inbox[index]
        if request.operation != "rename" { try ensureComposable([original]) }
        switch request.operation {
        case "rename":
            guard let title = request.title else { throw TrayError.message("Escribe el nombre del documento.") }
            candidate.inbox[index].title = cleanTitle(title)
        case "rotate":
            guard request.degrees % 90 == 0 else { throw TrayError.message("El giro debe ser múltiplo de 90 grados.") }
            for page in try validateIndices(request.pageIndices, count: original.pages.count, allIfEmpty: true) {
                candidate.inbox[index].pages[page].rotation = ((original.pages[page].rotation + request.degrees % 360) % 360 + 360) % 360
            }
        case "reorder":
            let indices = try validateIndices(request.pageIndices, count: original.pages.count)
            guard indices.count == original.pages.count else { throw TrayError.message("El nuevo orden debe incluir todas las páginas una sola vez.") }
            candidate.inbox[index].pages = indices.map { original.pages[$0] }
        case "deletePages":
            let indices = Set(try validateIndices(request.pageIndices, count: original.pages.count))
            candidate.inbox[index].pages = original.pages.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            if candidate.inbox[index].pages.isEmpty { candidate.inbox.remove(at: index) }
        case "extract", "copyPages":
            let indices = try validateIndices(request.pageIndices, count: original.pages.count)
            let selection = indices.map { original.pages[$0] }
            if request.operation == "extract" {
                let selected = Set(indices)
                candidate.inbox[index].pages = original.pages.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
                if candidate.inbox[index].pages.isEmpty { candidate.inbox.remove(at: index) }
            }
            if let targetID = request.targetID {
                guard targetID != original.id, let targetIndex = candidate.inbox.firstIndex(where: { $0.id == targetID }) else {
                    throw TrayError.message("Selecciona otro documento como destino.")
                }
                try ensureComposable([candidate.inbox[targetIndex]])
                candidate.inbox[targetIndex].pages += selection
            } else {
                guard candidate.inbox.count < 10 else { throw TrayError.message("Bandeja llena. Libera espacio para extraer o copiar páginas.") }
                let document = TrayDocument(title: cleanTitle(request.title ?? original.title + " — páginas"), pages: selection, textStatus: "none")
                candidate.inbox.append(document); assignOrder(document.id, to: &candidate)
            }
        case "merge":
            guard request.documentIDs.count >= 2, Set(request.documentIDs).count == request.documentIDs.count else {
                throw TrayError.message("Selecciona al menos dos documentos distintos para unir.")
            }
            let targetID = request.targetID ?? firstID
            guard request.documentIDs.contains(targetID) else { throw TrayError.message("El destino debe estar entre los documentos seleccionados.") }
            let orderedIDs = [targetID] + request.documentIDs.filter { $0 != targetID }
            let documents = try orderedIDs.map { id -> TrayDocument in
                guard let document = candidate.inbox.first(where: { $0.id == id }) else { throw TrayError.message("Solo se pueden unir documentos de la bandeja principal.") }
                return document
            }
            try ensureComposable(documents)
            guard let targetIndex = candidate.inbox.firstIndex(where: { $0.id == targetID }) else { throw TrayError.message("No se encontró el destino.") }
            candidate.inbox[targetIndex].pages = documents.flatMap(\.pages)
            let removed = Set(orderedIDs.dropFirst())
            candidate.inbox.removeAll { removed.contains($0.id) }
        default: throw TrayError.message("Operación de páginas no disponible.")
        }
        for index in candidate.inbox.indices { candidate.inbox[index].textStatus = textStatus(candidate.inbox[index].pages, assets: candidate.assets) }
        promote(&candidate)
        let before = Dictionary(uniqueKeysWithValues: (state.inbox + state.waiting).map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: (candidate.inbox + candidate.waiting).map { ($0.id, $0) })
        var affected = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        let beforeInbox = Set(state.inbox.map(\.id)), afterInbox = Set(candidate.inbox.map(\.id))
        affected.formUnion(beforeInbox.symmetricDifference(afterInbox))
        guard !affected.isEmpty else { return response() }
        let undo = UndoRecord(inbox: state.inbox, waiting: state.waiting, affected: affected)
        try commit(candidate, undo: history + [undo])
        return response()
    }

    private func undoLast() throws -> AgentResponse {
        guard let undo = history.last else { throw TrayError.message("No hay operaciones para deshacer en esta sesión.") }
        var candidate = state
        candidate.inbox.removeAll { undo.affected.contains($0.id) }
        candidate.waiting.removeAll { undo.affected.contains($0.id) }
        for (index, document) in undo.inbox.enumerated() where undo.affected.contains(document.id) {
            candidate.inbox.insert(document, at: min(index, candidate.inbox.count))
        }
        for (index, document) in undo.waiting.enumerated() where undo.affected.contains(document.id) {
            candidate.waiting.insert(document, at: min(index, candidate.waiting.count))
        }
        guard candidate.inbox.count + candidate.waiting.count <= 20 else { throw TrayError.message("Libera espacio para deshacer.") }
        while candidate.inbox.count > 10 { candidate.waiting.append(candidate.inbox.removeLast()) }
        candidate.waiting.sort { (candidate.order[$0.id] ?? 0) < (candidate.order[$1.id] ?? 0) }
        promote(&candidate)
        guard candidate.waiting.count <= 10 else { throw TrayError.message("Libera espacio para deshacer.") }
        try commit(candidate, undo: Array(history.dropLast()))
        return response()
    }

    private func commit(_ proposed: StoreState, undo: [UndoRecord]) throws {
        var candidate = proposed
        guard candidate.inbox.count <= 10, candidate.waiting.count <= 10 else { throw TrayError.message("La operación excede la capacidad de las bandejas.") }
        let wasFull = state.inbox.count == 10 && state.waiting.count == 10
        let isFull = candidate.inbox.count == 10 && candidate.waiting.count == 10
        if isFull && !wasFull && candidate.noticeVersion == state.noticeVersion {
            candidate.noticePending = true
            candidate.noticeVersion += 1
        }
        let documents = candidate.inbox + candidate.waiting
        guard Set(documents.map(\.id)).count == documents.count else { throw TrayError.message("La operación produciría documentos duplicados.") }
        var referenced = Set(documents.flatMap(\.pages).map(\.assetID))
        for record in undo {
            referenced.formUnion((record.inbox + record.waiting).filter { record.affected.contains($0.id) }.flatMap(\.pages).map(\.assetID))
        }
        let removed = Set(candidate.assets.keys).subtracting(referenced)
        candidate.assets = candidate.assets.filter { referenced.contains($0.key) }
        let retainedIDs = Set(documents.map(\.id)).union(undo.flatMap { ($0.inbox + $0.waiting).map(\.id) })
        candidate.order = candidate.order.filter { retainedIDs.contains($0.key) }
        candidate.revision = state.revision + 1
        try database.save(candidate)
        state = candidate; history = undo
        for id in removed where UUID(uuidString: id) != nil {
            let directory = root.appendingPathComponent("assets/\(id)")
            if (try? String(contentsOf: directory.appendingPathComponent(".owner"), encoding: .utf8)) == marker,
               (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                try? manager.removeItem(at: directory)
            }
        }
        // Previews are derived, carry no authoritative state and may be regenerated.
        if let cached = try? manager.contentsOfDirectory(at: root.appendingPathComponent("previews"), includingPropertiesForKeys: [.isRegularFileKey]) {
            for file in cached where file.pathExtension == "pdf" && file.lastPathComponent.hasPrefix("preview-") { try? manager.removeItem(at: file) }
        }
    }

    private func materialize(_ document: TrayDocument) throws -> URL {
        if let first = document.pages.first, let asset = state.assets[first.assetID], document.pages.count == asset.pageHasText.count,
           document.pages.enumerated().allSatisfy({ $0.element.assetID == first.assetID && $0.element.index == $0.offset && $0.element.rotation == 0 }) {
            let content = root.appendingPathComponent("assets/\(first.assetID)/content.pdf")
            guard manager.fileExists(atPath: content.path) else { throw TrayError.message("Falta el PDF original del documento.") }
            return content
        }
        let destination = root.appendingPathComponent("previews/preview-\(document.id)-\(state.revision).pdf")
        if manager.fileExists(atPath: destination.path) { return destination }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? manager.removeItem(at: temporary) }
        try PDFFiles.compose(document, assets: state.assets, root: root, destination: temporary)
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }
}
