// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AppKit
import Darwin
import BandejaShared
import BandejaCore

final class Service: NSObject, AgentProtocol, NSXPCListenerDelegate {
    let store: TrayStore
    let work = DispatchQueue(label: "local.bandejapdf.writer")
    let bundle: URL
    var shownNotice = -1
    var shownError: String?
    init(store: TrayStore, bundle: URL) { self.store = store; self.bundle = bundle }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: AgentProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard data.count < 1_048_576 else {
            reply((try? JSONEncoder().encode(AgentResponse(ok: false, message: "Solicitud demasiado grande."))) ?? Data()); return
        }
        work.async {
            let response: AgentResponse
            do { response = self.store.execute(try JSONDecoder().decode(AgentRequest.self, from: data)) }
            catch { response = AgentResponse(ok: false, message: error.localizedDescription) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
            self.presentPendingNotice()
        }
    }
    func presentPendingNotice() {
        let state = store.snapshot()
        let newNotice = state.noticePending && state.noticeVersion != shownNotice
        let newError = state.errorID != nil && state.errorID != shownError
        guard newNotice || newError else { return }
        if newNotice { shownNotice = state.noticeVersion }
        if newError { shownError = state.errorID }
        DispatchQueue.main.async {
            // App-owned window, independent of Notification Center / Focus permissions.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", self.bundle.path]
            try? open.run()
        }
    }
}

@main
enum AgentMain {
    static var receiver: Process?
    static var signals: [DispatchSourceSignal] = []
    static func main() {
        umask(0o077)
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bundle" else {
                throw NSError(domain: "BandejaPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta la ubicación de la aplicación."])
            }
            let bundle = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let root = Settings.dataDirectory
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lockPath = root.appendingPathComponent("agent.lock").path
            let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw NSError(domain: "BandejaPDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ya hay un agente de Bandeja PDF activo."])
            }
            let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
            let gs = resources.appendingPathComponent("ghostscript/bin/gs")
            let store = try TrayStore(root: root, ghostscript: FileManager.default.isExecutableFile(atPath: gs.path) ? gs : nil)
            let service = Service(store: store, bundle: bundle)
            let listener = NSXPCListener(machServiceName: Settings.service)
            listener.delegate = service
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    if let process = receiver, process.isRunning { process.terminate() }
                    exit(0)
                }
                source.resume(); signals.append(source)
            }
            try startReceiver(bundle: bundle, root: root, store: store)
            listener.resume()
            service.work.async { service.presentPendingNotice() }
            withExtendedLifetime((service, listener, lockFD)) { RunLoop.main.run() }
        } catch {
            fputs("Bandeja PDF: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func startReceiver(bundle: URL, root: URL, store: TrayStore) throws {
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
        process.arguments = ["-n", "localhost", "-r", "off", "-p", String(Settings.port), "--no-web-forms",
                             "-P", bundle.appendingPathComponent("Contents/Resources/BandejaPDF.ppd").path,
                             "-c", bundle.appendingPathComponent("Contents/Helpers/BandejaCLI").path,
                             "-d", spool.path, "Bandeja PDF"]
        var environment = ProcessInfo.processInfo.environment
        environment["BPDF_RECEIVER_SESSION"] = UUID().uuidString
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { child in
            fputs("El receptor se detuvo (\(child.terminationStatus)); launchd reiniciará el servicio.\n", stderr)
            exit(1)
        }
        try process.run()
        receiver = process
        // Verify actual listening addresses instead of relying on the hostname alone.
        for _ in 0..<50 {
            guard process.isRunning else { throw NSError(domain: "BandejaPDF", code: 3) }
            let check = Process(), output = Pipe()
            check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            check.arguments = ["-nP", "-a", "-p", String(process.processIdentifier), "-iTCP", "-sTCP:LISTEN"]
            check.standardOutput = output; check.standardError = FileHandle.nullDevice
            try check.run()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            check.waitUntilExit()
            let lines = text.split(separator: "\n").filter { $0.contains("LISTEN") }
            if !lines.isEmpty {
                guard lines.allSatisfy({ $0.contains("127.0.0.1:\(Settings.port)") || $0.contains("[::1]:\(Settings.port)") }) else {
                    process.terminate()
                    throw NSError(domain: "BandejaPDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "El receptor no está limitado a este Mac."])
                }
                store.setReceiverStatus("Lista para recibir impresiones")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminate()
        throw NSError(domain: "BandejaPDF", code: 5, userInfo: [NSLocalizedDescriptionKey: "El receptor no pudo iniciarse."])
    }
}
