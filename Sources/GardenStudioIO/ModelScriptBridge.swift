import Foundation
import Darwin
import GardenStudioCore

/// Interoperability through an explicit user-installed SketchUp Ruby bridge, plus
/// a small local Ruby creation API. No proprietary SketchUp libraries are loaded.
public enum ModelScriptBridge {
    public enum BridgeError: Error, LocalizedError {
        case unavailable(String), failed(String), timedOut, excessiveOutput
        public var errorDescription: String? {
            switch self {
            case let .unavailable(message), let .failed(message): return message
            case .timedOut: return "Ruby script exceeded its time limit and was stopped."
            case .excessiveOutput: return "Ruby script exceeded the output limit and was stopped."
            }
        }
    }

    private static func resource(_ name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "rb") { return url }
        // Enables source-package tests and `swift run`; packaged apps use Resources.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("scripts/\(name).rb")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BridgeError.unavailable("The bundled \(name).rb resource is missing. Rebuild the app using scripts/build.sh.")
        }
        return url
    }

    public static func extensionScriptURL() throws -> URL { try resource("garden_studio_bridge") }

    /// Writes the bridge to a user-selected .rb location, without changing SketchUp settings.
    public static func writeExtension(to url: URL) throws {
        try Data(contentsOf: extensionScriptURL()).write(to: url, options: .atomic)
    }

    /// Runs trusted local Ruby code. This API is deliberately NOT a sandbox or a
    /// complete SketchUp Ruby runtime. Call off the main thread for responsive UI.
    /// The timeout/output limits bound this process, not arbitrary child processes
    /// a trusted script may explicitly spawn.
    public static func runRubyScript(at scriptURL: URL, document: ModelDocument, timeout: TimeInterval = 10) throws -> ModelDocument {
        try document.validate()
        guard timeout.isFinite, timeout >= 0.1, timeout <= 60 else { throw BridgeError.failed("Ruby timeout must be between 0.1 and 60 seconds.") }
        guard scriptURL.isFileURL, FileManager.default.isReadableFile(atPath: scriptURL.path) else { throw BridgeError.failed("Choose a readable local Ruby script.") }
        let runner = try resource("ruby_runner")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") else { throw BridgeError.unavailable("Ruby is not available at /usr/bin/ruby.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gardenstudio-ruby-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.json")
        let outputURL = directory.appendingPathComponent("output.json")
        let errorsURL = directory.appendingPathComponent("errors.txt")
        let encoded = try JSONEncoder().encode(document)
        guard encoded.count <= 16 * 1024 * 1024 else { throw BridgeError.failed("Ruby input document exceeds the 16 MB limit.") }
        try encoded.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [runner.path, scriptURL.path]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: BridgeError?
        func fileSize(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        }
        while process.isRunning {
            if Date() >= deadline { failure = .timedOut; break }
            if fileSize(outputURL) > 16 * 1024 * 1024 || fileSize(errorsURL) > 256 * 1024 { failure = .excessiveOutput; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let failure {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < graceDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw failure
        }
        process.waitUntilExit()
        guard fileSize(outputURL) <= 16 * 1024 * 1024, fileSize(errorsURL) <= 256 * 1024 else { throw BridgeError.excessiveOutput }
        if process.terminationStatus != 0 {
            let message = (try? String(contentsOf: errorsURL, encoding: .utf8)) ?? "Ruby script failed."
            throw BridgeError.failed(String(message.prefix(4000)))
        }
        let result: ModelDocument
        do { result = try JSONDecoder().decode(ModelDocument.self, from: Data(contentsOf: outputURL)) }
        catch { throw BridgeError.failed("Ruby did not return a valid Garden Studio document: \(error.localizedDescription)") }
        try result.validate()
        return result
    }
}
