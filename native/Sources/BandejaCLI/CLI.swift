// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import BandejaShared

@main
enum CLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        var request: AgentRequest
        let printerJob = environment["IPP_JOB_ID"] != nil
        do {
            if printerJob {
                guard let input = arguments.first, let session = environment["BPDF_RECEIVER_SESSION"], let job = environment["IPP_JOB_ID"] else {
                    throw NSError(domain: "BandejaPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Trabajo sin identidad de recepción."])
                }
                request = AgentRequest("ingest")
                request.path = input
                request.jobKey = session + ":" + job
                request.title = environment["IPP_JOB_NAME"] ?? "Impresión"
            } else if arguments == ["request"] {
                request = try JSONDecoder().decode(AgentRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
            } else if arguments == ["snapshot"] {
                request = AgentRequest("snapshot")
            } else {
                fputs("Uso: BandejaCLI snapshot | request < solicitud.json\n", stderr)
                exit(64)
            }
            let client = AgentClient()
            let semaphore = DispatchSemaphore(value: 0)
            var result: AgentResponse?
            client.send(request) { response in result = response; semaphore.signal() }
            guard semaphore.wait(timeout: .now() + 185) == .success, let response = result else {
                fputs("ERROR: Tiempo de espera agotado; comprueba la bandeja antes de repetir.\n", stderr)
                exit(1)
            }
            if printerJob {
                if !response.ok { fputs("ERROR: \(response.message ?? "No se pudo guardar la impresión.")\n", stderr) }
                else { fputs("INFO: Bandeja PDF: \(response.disposition ?? "guardado")\n", stderr) }
            } else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(response))
                FileHandle.standardOutput.write(Data([10]))
            }
            withExtendedLifetime(client) { exit(response.ok ? 0 : 1) }
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
