// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLite3
import BandejaShared

struct AssetRecord: Codable {
    var id: String
    var pageHasText: [Bool]
    var hasWidgets: Bool
    var hasOutline: Bool
    var sourceKind: String
}

struct JobReceipt: Codable {
    var digest: String
    var disposition: String
    var documentID: String?
}

struct StoreState: Codable {
    var schema = 1
    var inbox: [TrayDocument] = []
    var waiting: [TrayDocument] = []
    var assets: [String: AssetRecord] = [:]
    var receipts: [String: JobReceipt] = [:]
    var order: [String: Int] = [:]
    var nextOrder = 0
    var discarded = 0
    var noticePending = false
    var noticeVersion = 0
    var revision = 0
    var lastError: String?
    var errorID: String?
}

enum TrayError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

final class StateDatabase {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw TrayError.message("No se pudo abrir el almacenamiento de la bandeja.")
        }
        do {
            sqlite3_busy_timeout(handle, 5000)
            try sql("PRAGMA journal_mode=WAL")
            try sql("PRAGMA synchronous=FULL")
            try sql("CREATE TABLE IF NOT EXISTS tray_state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    private func sql(_ statement: String) throws {
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
            throw TrayError.message("Error al guardar la bandeja: \(String(cString: sqlite3_errmsg(handle))).")
        }
    }
    func load() throws -> StoreState? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT data FROM tray_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else {
            throw TrayError.message("No se pudo leer la bandeja.")
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else {
            throw TrayError.message("El índice de la bandeja no es válido.")
        }
        let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(StoreState.self, from: data)
    }
    func save(_ state: StoreState) throws {
        let data = try JSONEncoder().encode(state)
        try sql("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO tray_state(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", -1, &statement, nil) == SQLITE_OK else {
                throw TrayError.message("No se pudo preparar el guardado de la bandeja.")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bound = data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw TrayError.message("No se pudo guardar la bandeja; comprueba el espacio disponible.")
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
}
