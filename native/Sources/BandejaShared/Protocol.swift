// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum Settings {
    public static let service = "local.bandejapdf.agent"
    public static let queue = "bandeja_pdf"
    public static let port = 18633
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BandejaPDF", isDirectory: true)
    }
}

@objc public protocol AgentProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

public struct PageReference: Codable, Equatable {
    public var assetID: String
    public var index: Int
    public var rotation: Int
    public init(assetID: String, index: Int, rotation: Int = 0) {
        self.assetID = assetID; self.index = index; self.rotation = rotation
    }
}

public struct TrayDocument: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var pages: [PageReference]
    /// "text", "partial", or "none"; only describes extractable text, not its correctness.
    public var textStatus: String
    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), pages: [PageReference], textStatus: String) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.pages = pages; self.textStatus = textStatus
    }
}

public struct TraySnapshot: Codable {
    public var inbox: [TrayDocument] = []
    public var waiting: [TrayDocument] = []
    public var discarded: Int = 0
    public var noticePending: Bool = false
    public var noticeVersion: Int = 0
    public var canUndo: Bool = false
    public var revision: Int = 0
    public var receiverStatus: String = "Iniciando receptor"
    public var lastError: String?
    public var errorID: String?
    public init() {}
}

/// Paths are local to the signed-in account; every mutation is performed by the agent.
public struct AgentRequest: Codable {
    public var operation: String
    public var documentIDs: [String] = []
    public var pageIndices: [Int] = []
    public var targetID: String?
    public var path: String?
    public var title: String?
    public var jobKey: String?
    public var noticeVersion: Int?
    public var errorID: String?
    public var degrees: Int = 90
    public var includeWaiting: Bool = false
    public init(_ operation: String) { self.operation = operation }
    private enum CodingKeys: String, CodingKey {
        case operation, documentIDs, pageIndices, targetID, path, title, jobKey, noticeVersion, errorID, degrees, includeWaiting
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(String.self, forKey: .operation)
        documentIDs = try c.decodeIfPresent([String].self, forKey: .documentIDs) ?? []
        pageIndices = try c.decodeIfPresent([Int].self, forKey: .pageIndices) ?? []
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        jobKey = try c.decodeIfPresent(String.self, forKey: .jobKey)
        noticeVersion = try c.decodeIfPresent(Int.self, forKey: .noticeVersion)
        errorID = try c.decodeIfPresent(String.self, forKey: .errorID)
        degrees = try c.decodeIfPresent(Int.self, forKey: .degrees) ?? 90
        includeWaiting = try c.decodeIfPresent(Bool.self, forKey: .includeWaiting) ?? false
    }
}

public struct AgentResponse: Codable {
    public var ok: Bool
    public var message: String?
    public var snapshot: TraySnapshot?
    public var path: String?
    public var disposition: String?
    public init(ok: Bool = true, message: String? = nil, snapshot: TraySnapshot? = nil, path: String? = nil, disposition: String? = nil) {
        self.ok = ok; self.message = message; self.snapshot = snapshot
        self.path = path; self.disposition = disposition
    }
}

public final class AgentClient {
    private let connection: NSXPCConnection
    public init() {
        connection = NSXPCConnection(machServiceName: Settings.service, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentProtocol.self)
        connection.resume()
    }
    deinit { connection.invalidate() }
    public func send(_ request: AgentRequest, completion: @escaping (AgentResponse) -> Void) {
        let lock = NSLock()
        var completed = false
        func finish(_ response: AgentResponse) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true; lock.unlock()
            completion(response)
        }
        guard let encoded = try? JSONEncoder().encode(request) else {
            finish(AgentResponse(ok: false, message: "No se pudo preparar la solicitud.")); return
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(AgentResponse(ok: false, message: "No se pudo contactar al agente: \(error.localizedDescription)"))
        }) as? AgentProtocol else {
            finish(AgentResponse(ok: false, message: "El agente no está disponible.")); return
        }
        proxy.request(encoded) { data in
            do { finish(try JSONDecoder().decode(AgentResponse.self, from: data)) }
            catch { finish(AgentResponse(ok: false, message: "Respuesta del agente no válida.")) }
        }
        // A timeout must not be presented as a rejected mutation: it may still finish.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            finish(AgentResponse(ok: false, message: "La operación sigue sin confirmar. Revisa la bandeja antes de repetirla."))
        }
    }
}
