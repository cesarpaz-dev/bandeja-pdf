// SPDX-License-Identifier: AGPL-3.0-only
#if !BANDEJA_STANDALONE_TESTS
import XCTest
#endif
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import BandejaCore
import BandejaShared

#if BANDEJA_STANDALONE_TESTS
// CLT-only runner for the same test methods when the XCTest SDK is unavailable.
// It records failures and exits nonzero; it does not change test expectations.
private var assertionFailures: [String] = []
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { assertionFailures.append("\(file):\(line) \(message())") } }
    catch { assertionFailures.append("\(file):\(line) \(error)") }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { assertionFailures.append("\(file):\(line) \(message())") } }
    catch { assertionFailures.append("\(file):\(line) \(error)") }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() != rhs() { assertionFailures.append("\(file):\(line) equality failed \(message())") } }
    catch { assertionFailures.append("\(file):\(line) \(error)") }
}
func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() <= rhs() { assertionFailures.append("\(file):\(line) comparison failed") } }
    catch { assertionFailures.append("\(file):\(line) \(error)") }
}
func XCTAssertNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() != nil { assertionFailures.append("\(file):\(line) expected nil") }
}
func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() == nil { assertionFailures.append("\(file):\(line) expected non-nil") }
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "CoreTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected nil"]) }
    return value
}

@main struct StandaloneCoreTests {
    static func main() {
        let cases: [(String, (TrayStoreTests) throws -> Void)] = [
            ("capacity-restart-dedup-notice", { try $0.testPersistentCapacityDedupDiscardAndVersionedNotice() }),
            ("manual-and-extraction-capacity", { try $0.testManualImportAndExtractionAreAtomicAtCapacity() }),
            ("byte-identity-and-protected-export", { try $0.testUnmodifiedByteIdentityAndExportProtection() }),
            ("composition-text-rotation-extraction", { try $0.testReorderRotationMergeExtractionPreserveText() }),
            ("undo-blocked-when-full", { try $0.testUndoPreservesArrivalsAndBlocksWithoutCapacity() }),
            ("undo-preserves-arrivals-FIFO", { try $0.testUndoKeepsNewArrivalAndReturnsPromotionToWaiting() }),
            ("failed-ingest-error-notice", { try $0.testInvalidPDFIsFailureNotDiscardAndErrorAckIsVersioned() }),
            ("delete-clear-promotion", { try $0.testDeleteClearsUndoAndClearPromotesFIFO() }),
            ("duplicate-key-and-invalid-reorder", { try $0.testDuplicateKeyWithDifferentContentFailsAndBadReorderIsAtomic() })
            ,("PostScript-private-runtime-and-failure", { try $0.testPostScriptPrivateRuntimeAndFailedOriginal() })
            ,("undo-refills-full-notice", { try $0.testUndoRefillsFullNotice() })
        ]
        var results: [[String: Any]] = []
        for (name, body) in cases {
            let initial = assertionFailures.count
            let test = TrayStoreTests()
            do { try test.setUpWithError(); try body(test) }
            catch { assertionFailures.append("\(name): \(error)") }
            do { try test.tearDownWithError() } catch { assertionFailures.append("\(name) cleanup: \(error)") }
            results.append(["case": name, "passed": assertionFailures.count == initial])
        }
        let output: [String: Any] = ["runner": "CLT standalone; same methods as XCTest", "passed": assertionFailures.isEmpty, "cases": results, "failures": assertionFailures]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(assertionFailures.isEmpty ? 0 : 1)
    }
}
#endif

final class TrayStoreTests: XCTestCase {
    var temporary: URL!
    var source: URL!
    var store: TrayStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bandeja-core-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        source = temporary.appendingPathComponent("source.pdf")
        try fixture(source, texts: ["PAGE1 DUA 000123 acción café niño 1.234,56", "PAGE2 Fecha 01/11/2026 pingüino ÁÉÍÓÚ"])
        store = try TrayStore(root: temporary.appendingPathComponent("store"), ghostscript: nil)
    }
    override func tearDownWithError() throws {
        store = nil
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }
    func fixture(_ url: URL, texts: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for text in texts {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 36, y: 780)
            let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(value), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    @discardableResult func add(_ key: String? = nil, to target: TrayStore? = nil) -> AgentResponse {
        var request = AgentRequest(key == nil ? "import" : "ingest")
        request.path = source.path; request.jobKey = key; request.title = key ?? "Manual"
        return (target ?? store!).execute(request)
    }
    func operation(_ name: String, ids: [String] = [], pages: [Int] = []) -> AgentRequest {
        var request = AgentRequest(name); request.documentIDs = ids; request.pageIndices = pages; return request
    }
    func testPersistentCapacityDedupDiscardAndVersionedNotice() throws {
        for index in 0..<20 { XCTAssertTrue(add("job-\(index)").ok) }
        var snapshot = store.snapshot()
        XCTAssertEqual(snapshot.inbox.count, 10); XCTAssertEqual(snapshot.waiting.count, 10)
        XCTAssertTrue(snapshot.noticePending)
        let fullVersion = snapshot.noticeVersion
        var ack = AgentRequest("ackNotice"); ack.noticeVersion = fullVersion
        XCTAssertTrue(store.execute(ack).ok); XCTAssertFalse(store.snapshot().noticePending)
        XCTAssertEqual(add("overflow").disposition, "discarded")
        XCTAssertEqual(add("overflow").disposition, "discarded")
        snapshot = store.snapshot()
        XCTAssertEqual(snapshot.discarded, 1)
        XCTAssertTrue(snapshot.noticePending); XCTAssertGreaterThan(snapshot.noticeVersion, fullVersion)
        _ = store.execute(ack)
        XCTAssertTrue(store.snapshot().noticePending, "Stale acknowledgement must not hide a later discard")
        store = nil
        store = try TrayStore(root: temporary.appendingPathComponent("store"), ghostscript: nil)
        XCTAssertEqual(store.snapshot().discarded, 1)
        XCTAssertTrue(store.snapshot().noticePending)
        XCTAssertEqual(add("overflow").disposition, "discarded")
        XCTAssertEqual(store.snapshot().discarded, 1)
        XCTAssertEqual(add("job-0").disposition, "stored")
        XCTAssertEqual(store.snapshot().inbox.count, 10)
        ack.noticeVersion = store.snapshot().noticeVersion
        XCTAssertTrue(store.execute(ack).ok)
        XCTAssertEqual(store.snapshot().discarded, 0, "Recognizing the notice clears the pending loss count")
        XCTAssertFalse(store.snapshot().noticePending)
        XCTAssertEqual(add("overflow").disposition, "discarded")
        XCTAssertEqual(store.snapshot().discarded, 0, "A retry is not a new lost print")
        let firstWaiting = store.snapshot().waiting.first!.id
        let removed = store.snapshot().inbox.first!.id
        XCTAssertTrue(store.execute(operation("delete", ids: [removed])).ok)
        XCTAssertEqual(store.snapshot().inbox.last!.id, firstWaiting)
        XCTAssertEqual(store.snapshot().waiting.count, 9)
    }
    func testManualImportAndExtractionAreAtomicAtCapacity() throws {
        let sourceBytes = try Data(contentsOf: source)
        for _ in 0..<10 { XCTAssertTrue(add().ok) }
        let before = store.snapshot()
        XCTAssertFalse(add().ok)
        XCTAssertEqual(store.snapshot().waiting.count, 0)
        let result = store.execute(operation("extract", ids: [before.inbox[0].id], pages: [0]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(store.snapshot().inbox, before.inbox)
        XCTAssertEqual(store.snapshot().revision, before.revision)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
    func testUnmodifiedByteIdentityAndExportProtection() throws {
        let original = try Data(contentsOf: source)
        XCTAssertTrue(add().ok)
        let document = store.snapshot().inbox[0]
        XCTAssertEqual(document.textStatus, "text")
        var export = operation("export", ids: [document.id])
        export.path = temporary.appendingPathComponent("export.pdf").path
        let response = store.execute(export)
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: response.path!)), original)
        export.path = temporary.appendingPathComponent("store/tray.sqlite").path
        XCTAssertFalse(store.execute(export).ok)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testReorderRotationMergeExtractionPreserveText() throws {
        let sourceBytes = try Data(contentsOf: source)
        XCTAssertTrue(add().ok)
        let first = store.snapshot().inbox[0].id
        XCTAssertTrue(store.execute(operation("reorder", ids: [first], pages: [1, 0])).ok)
        var rotate = operation("rotate", ids: [first], pages: [0]); rotate.degrees = 90
        XCTAssertTrue(store.execute(rotate).ok)
        let secondSource = temporary.appendingPathComponent("second.pdf")
        try fixture(secondSource, texts: ["PAGE3 NÚMERO 000007"])
        var request = AgentRequest("import"); request.path = secondSource.path; request.title = "Second"
        XCTAssertTrue(store.execute(request).ok)
        let second = store.snapshot().inbox[1].id
        XCTAssertTrue(store.execute(operation("merge", ids: [first, second])).ok)
        let merged = store.snapshot().inbox[0]
        XCTAssertEqual(merged.pages.count, 3); XCTAssertEqual(merged.title, "Manual")
        let preview = store.execute(operation("preview", ids: [first]))
        XCTAssertTrue(preview.ok, preview.message ?? "")
        let pdf = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: preview.path!)))
        XCTAssertEqual(pdf.pageCount, 3); XCTAssertEqual(pdf.page(at: 0)?.rotation, 90)
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("PAGE2"))
        XCTAssertTrue((pdf.page(at: 1)?.string ?? "").contains("000123"))
        XCTAssertTrue((pdf.page(at: 1)?.string ?? "").contains("acción"))
        XCTAssertTrue((pdf.page(at: 2)?.string ?? "").contains("000007"))
        XCTAssertTrue(store.execute(operation("extract", ids: [first], pages: [2])).ok)
        XCTAssertEqual(store.snapshot().inbox.map { $0.pages.count }, [2, 1])
        XCTAssertTrue(store.execute(AgentRequest("undo")).ok)
        XCTAssertEqual(store.snapshot().inbox.count, 1)
        XCTAssertEqual(store.snapshot().inbox[0].pages, merged.pages)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
    func testUndoPreservesArrivalsAndBlocksWithoutCapacity() throws {
        for index in 0..<20 { XCTAssertTrue(add("j-\(index)").ok) }
        let before = store.snapshot()
        XCTAssertTrue(store.execute(operation("merge", ids: [before.inbox[0].id, before.inbox[1].id])).ok)
        XCTAssertEqual(store.snapshot().waiting.count, 9)
        XCTAssertTrue(add("new-arrival").ok)
        let after = store.snapshot()
        let blocked = store.execute(AgentRequest("undo"))
        XCTAssertFalse(blocked.ok)
        XCTAssertTrue(blocked.message?.contains("Libera espacio") == true)
        XCTAssertEqual(store.snapshot().inbox, after.inbox)
        XCTAssertEqual(store.snapshot().waiting, after.waiting)
        XCTAssertTrue(store.snapshot().canUndo)
    }
    func testUndoKeepsNewArrivalAndReturnsPromotionToWaiting() throws {
        for index in 0..<12 { XCTAssertTrue(add("j-\(index)").ok) }
        let original = store.snapshot()
        XCTAssertTrue(store.execute(operation("merge", ids: [original.inbox[0].id, original.inbox[1].id])).ok)
        XCTAssertTrue(add("arrival").ok)
        let arrival = store.snapshot().waiting.last!.id
        XCTAssertTrue(store.execute(AgentRequest("undo")).ok)
        XCTAssertEqual(store.snapshot().inbox, original.inbox)
        XCTAssertEqual(store.snapshot().waiting.map(\.id), original.waiting.map(\.id) + [arrival])
        XCTAssertFalse(store.snapshot().canUndo)
    }
    func testInvalidPDFIsFailureNotDiscardAndErrorAckIsVersioned() throws {
        let invalid = temporary.appendingPathComponent("bad.pdf")
        try Data("%PDF-1.7\nnot a PDF".utf8).write(to: invalid)
        var request = AgentRequest("ingest"); request.path = invalid.path; request.jobKey = "bad-1"
        XCTAssertFalse(store.execute(request).ok)
        let initialError = store.snapshot().errorID
        XCTAssertNotNil(initialError)
        XCTAssertEqual(store.snapshot().discarded, 0); XCTAssertEqual(store.snapshot().inbox.count, 0)
        let failures = temporary.appendingPathComponent("store/failures")
        let originals = FileManager.default.enumerator(at: failures, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "original.document" }
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(try Data(contentsOf: originals[0]), try Data(contentsOf: invalid))
        request.jobKey = "bad-2"
        XCTAssertFalse(store.execute(request).ok)
        var ack = AgentRequest("ackError"); ack.errorID = initialError
        _ = store.execute(ack)
        XCTAssertNotNil(store.snapshot().lastError)
        store = nil; store = try TrayStore(root: temporary.appendingPathComponent("store"), ghostscript: nil)
        XCTAssertNotNil(store.snapshot().lastError)
        ack.errorID = store.snapshot().errorID
        XCTAssertTrue(store.execute(ack).ok); XCTAssertNil(store.snapshot().lastError)
        request.path = source.path
        XCTAssertTrue(store.execute(request).ok, "Failed ingestion must not create a successful dedup receipt")
    }
    func testDeleteClearsUndoAndClearPromotesFIFO() throws {
        for index in 0..<12 { XCTAssertTrue(add("j-\(index)").ok) }
        let before = store.snapshot()
        XCTAssertTrue(store.execute(operation("rotate", ids: [before.inbox[0].id], pages: [0])).ok)
        XCTAssertTrue(store.snapshot().canUndo)
        XCTAssertTrue(store.execute(operation("delete", ids: [before.inbox[0].id])).ok)
        XCTAssertFalse(store.snapshot().canUndo)
        let remainingWait = store.snapshot().waiting.map(\.id)
        XCTAssertTrue(store.execute(AgentRequest("clear")).ok)
        XCTAssertEqual(store.snapshot().inbox.map(\.id), remainingWait)
        XCTAssertTrue(store.snapshot().waiting.isEmpty)
        var clear = AgentRequest("clear"); clear.includeWaiting = true
        XCTAssertTrue(store.execute(clear).ok)
        XCTAssertTrue(store.snapshot().inbox.isEmpty)
    }
    func testDuplicateKeyWithDifferentContentFailsAndBadReorderIsAtomic() throws {
        XCTAssertTrue(add("same-key").ok)
        let before = store.snapshot()
        XCTAssertFalse(store.execute(operation("reorder", ids: [before.inbox[0].id], pages: [0, 0])).ok)
        XCTAssertEqual(store.snapshot().inbox, before.inbox)
        let alternate = temporary.appendingPathComponent("alternate.pdf")
        try fixture(alternate, texts: ["Different 000999"])
        var request = AgentRequest("ingest"); request.path = alternate.path; request.jobKey = "same-key"
        XCTAssertFalse(store.execute(request).ok)
        XCTAssertEqual(store.snapshot().inbox, before.inbox)
        XCTAssertEqual(store.snapshot().discarded, 0)
    }
    func testPostScriptPrivateRuntimeAndFailedOriginal() throws {
        var project = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { project.deleteLastPathComponent() }
        let executable = ProcessInfo.processInfo.environment["BANDEJA_TEST_GS"].map(URL.init(fileURLWithPath:))
            ?? project.appendingPathComponent("build/runtime/bin/gs")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "CoreTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Build the private Ghostscript runtime or set BANDEJA_TEST_GS for the conversion test."])
        }
        store = nil
        store = try TrayStore(root: temporary.appendingPathComponent("store"), ghostscript: executable)
        let postscript = temporary.appendingPathComponent("fixture.ps")
        try "%!PS-Adobe-3.0\n<</PageSize [595 842]>>setpagedevice\n/Helvetica findfont 12 scalefont setfont\n72 700 moveto (PS 000123 CODE_01) show\nshowpage\n%%EOF\n".write(to: postscript, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: postscript)
        var request = AgentRequest("ingest"); request.path = postscript.path; request.jobKey = "postscript-1"
        let accepted = store.execute(request)
        XCTAssertTrue(accepted.ok, accepted.message ?? "")
        let document = try XCTUnwrap(store.snapshot().inbox.first)
        XCTAssertEqual(document.textStatus, "text")
        let preview = store.execute(operation("preview", ids: [document.id]))
        let path = try XCTUnwrap(preview.path)
        let pdf = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        XCTAssertTrue((pdf.string ?? "").contains("000123"))
        var export = operation("export", ids: [document.id]); export.path = temporary.appendingPathComponent("ps-export.pdf").path
        XCTAssertTrue(store.execute(export).ok)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: export.path!)), try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(try Data(contentsOf: postscript), original)
        let malformed = temporary.appendingPathComponent("malformed.ps")
        try "%!PS-Adobe-3.0\nBandejaUndefinedOperator\n".write(to: malformed, atomically: true, encoding: .utf8)
        request.path = malformed.path; request.jobKey = "postscript-bad"
        XCTAssertFalse(store.execute(request).ok)
        XCTAssertEqual(store.snapshot().discarded, 0); XCTAssertEqual(store.snapshot().inbox.count, 1)
        XCTAssertNotNil(store.snapshot().lastError)
        let failures = FileManager.default.enumerator(at: temporary.appendingPathComponent("store/failures"), includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "original.document" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: failures[0]), try Data(contentsOf: malformed))
    }
    func testUndoRefillsFullNotice() throws {
        for index in 0..<20 { XCTAssertTrue(add("refill-\(index)").ok) }
        let full = store.snapshot()
        var acknowledge = AgentRequest("ackNotice")
        acknowledge.noticeVersion = full.noticeVersion
        XCTAssertTrue(store.execute(acknowledge).ok)
        XCTAssertFalse(store.snapshot().noticePending)
        XCTAssertTrue(store.execute(operation("merge", ids: [full.inbox[0].id, full.inbox[1].id])).ok)
        XCTAssertEqual(store.snapshot().inbox.count + store.snapshot().waiting.count, 19)
        XCTAssertFalse(store.snapshot().noticePending)
        XCTAssertTrue(store.execute(AgentRequest("undo")).ok)
        let restored = store.snapshot()
        XCTAssertEqual(restored.inbox.count, 10)
        XCTAssertEqual(restored.waiting.count, 10)
        XCTAssertTrue(restored.noticePending)
        XCTAssertEqual(restored.noticeVersion, full.noticeVersion + 1)
        XCTAssertEqual(restored.discarded, 0)
    }
}
