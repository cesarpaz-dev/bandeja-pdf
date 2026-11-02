// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit
import CryptoKit
import Darwin
import BandejaShared

enum PDFFiles {
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func kind(_ source: URL) throws -> String {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard attributes.isRegularFile == true else { throw TrayError.message("Selecciona un archivo PDF válido.") }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 1024) ?? Data()
        if prefix.starts(with: Data("%PDF-".utf8)) { return "pdf" }
        if prefix.starts(with: Data("%!PS".utf8)) { return "postscript" }
        throw TrayError.message("Formato no admitido. Se requiere PDF o PostScript.")
    }
    static func inspect(_ url: URL, id: String, sourceKind: String) throws -> AssetRecord {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw TrayError.message("El archivo no contiene un PDF válido con páginas.")
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw TrayError.message("El PDF está cifrado o protegido. Guarda una copia sin protección para incorporarlo.")
        }
        var text: [Bool] = []
        var widgets = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw TrayError.message("No se pudo leer una página del PDF.") }
            text.append(!(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            widgets = widgets || page.annotations.contains { ($0.type ?? "").lowercased().contains("widget") }
        }
        return AssetRecord(id: id, pageHasText: text, hasWidgets: widgets,
                           hasOutline: (document.outlineRoot?.numberOfChildren ?? 0) > 0, sourceKind: sourceKind)
    }
    static func durable(_ url: URL, directory: Bool = false) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw TrayError.message("No se pudo comprobar el archivo guardado.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw TrayError.message("No se pudo confirmar el guardado en disco.") }
        if !directory { _ = fcntl(descriptor, F_FULLFSYNC) }
    }
    static func convertPS(_ input: URL, output: URL, executable: URL?) throws {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TrayError.message("El conversor PostScript no está disponible.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dAutoRotatePages=/None", "-sOutputFile=\(output.path)", "-f", input.path]
        var environment = ProcessInfo.processInfo.environment
        // Never accept ambient GS_OPTIONS, which could change the output or SAFER.
        environment.removeValue(forKey: "GS_OPTIONS")
        environment.removeValue(forKey: "GS_FONTPATH")
        environment.removeValue(forKey: "GS_LIB")
        let runtime = executable.deletingLastPathComponent().deletingLastPathComponent()
        let share = runtime.appendingPathComponent("share/ghostscript")
        let versions = (try? FileManager.default.contentsOfDirectory(at: share, includingPropertiesForKeys: nil)) ?? []
        let version = FileManager.default.fileExists(atPath: share.appendingPathComponent("Resource/Init").path) ? share : versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Resource/Init").path)
        }
        if let version {
            environment["GS_LIB"] = [version.appendingPathComponent("Resource/Init").path,
                                     version.appendingPathComponent("lib").path,
                                     version.appendingPathComponent("Resource/Font").path,
                                     share.appendingPathComponent("fonts").path].joined(separator: ":")
        }
        process.environment = environment
        let log = output.deletingLastPathComponent().appendingPathComponent("conversion.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardError = handle; process.standardOutput = handle
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw TrayError.message("La conversión PostScript excedió el tiempo permitido.")
        }
        guard process.terminationStatus == 0 else {
            throw TrayError.message("No se pudo convertir el PostScript. El trabajo no se incorporó.")
        }
    }
    static func compose(_ document: TrayDocument, assets: [String: AssetRecord], root: URL, destination: URL) throws {
        let output = PDFDocument()
        var sources: [String: PDFDocument] = [:]
        for ref in document.pages {
            guard let asset = assets[ref.assetID], ref.index >= 0, ref.index < asset.pageHasText.count else {
                throw TrayError.message("Falta una página del documento.")
            }
            guard !asset.hasWidgets, !asset.hasOutline else {
                throw TrayError.message("Esta versión conserva formularios y marcadores al exportar sin cambios, pero aún no permite componer sus páginas.")
            }
            if sources[ref.assetID] == nil {
                sources[ref.assetID] = PDFDocument(url: root.appendingPathComponent("assets/\(ref.assetID)/content.pdf"))
            }
            guard let page = sources[ref.assetID]?.page(at: ref.index)?.copy() as? PDFPage else {
                throw TrayError.message("No se pudo abrir una página para exportarla.")
            }
            page.rotation = ((page.rotation + ref.rotation) % 360 + 360) % 360
            output.insert(page, at: output.pageCount)
        }
        guard output.write(to: destination), let checked = PDFDocument(url: destination), checked.pageCount == document.pages.count else {
            throw TrayError.message("No se pudo escribir el PDF completo.")
        }
        try durable(destination)
    }
    static func copyAtomically(_ source: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".bandeja-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try durable(temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            throw TrayError.message("No se pudo guardar el PDF en el destino elegido.")
        }
        try durable(parent, directory: true)
    }
}
