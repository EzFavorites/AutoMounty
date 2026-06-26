import Foundation
import Combine
import AppKit

enum LogLevel: Int, CaseIterable, Identifiable {
    case none = 0
    case error = 1
    case info = 2
    case debug = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .error: return "Error"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }
}

@MainActor
class Logger: ObservableObject {
    static let shared = Logger()

    @Published var logLevel: LogLevel = .none {
        didSet {
            UserDefaults.standard.set(logLevel.rawValue, forKey: "LogLevel")
        }
    }

    private let logFileURL: URL
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter

    private static let maxLogFileSize: UInt64 = 5 * 1024 * 1024 // 5 MB
    private static let maxRotatedFiles = 2

    private init() {
        let savedLevel = UserDefaults.standard.integer(forKey: "LogLevel")
        self.logLevel = LogLevel(rawValue: savedLevel) ?? .none

        let paths = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        let logsDir = paths[0].appendingPathComponent("Logs").appendingPathComponent("AutoMounty")

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("automounty.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        do {
            self.fileHandle = try FileHandle(forWritingTo: logFileURL)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            print("Failed to open log file: \(error)")
            self.fileHandle = nil
        }

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        log("Logger initialized. Level: \(logLevel.displayName). Path: \(logFileURL.path)", level: .info)
    }

    func log(_ message: String, level: LogLevel) {
        guard level.rawValue <= logLevel.rawValue && level != .none else { return }

        let timestamp = dateFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] [\(level.displayName.uppercased())] \(message)\n"

        print(logEntry, terminator: "")

        if let data = logEntry.data(using: .utf8) {
            fileHandle?.write(data)
            rotateLogIfNeeded()
        }
    }

    func openLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    nonisolated static func error(_ message: String) {
        Task { @MainActor in
            shared.log(message, level: .error)
        }
    }

    nonisolated static func info(_ message: String) {
        Task { @MainActor in
            shared.log(message, level: .info)
        }
    }

    nonisolated static func debug(_ message: String) {
        Task { @MainActor in
            shared.log(message, level: .debug)
        }
    }

    // MARK: - Log Rotation

    private func rotateLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize >= Logger.maxLogFileSize else { return }

        let logsDir = logFileURL.deletingLastPathComponent()
        let baseName = logFileURL.deletingPathExtension().lastPathComponent

        // Close current file handle
        try? fileHandle?.close()

        // Shift rotated files: .log.2 -> delete, .log.1 -> .log.2, .log -> .log.1
        for i in stride(from: Logger.maxRotatedFiles, through: 1, by: -1) {
            let src = logsDir.appendingPathComponent("\(baseName).log.\(i)")
            let dst = logsDir.appendingPathComponent("\(baseName).log.\(i + 1)")
            if FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.removeItem(at: dst)
            }
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }

        // Rename current log to .log.1
        let rotated = logsDir.appendingPathComponent("\(baseName).log.1")
        try? FileManager.default.moveItem(at: logFileURL, to: rotated)

        // Create fresh log file
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: logFileURL)
        } catch {
            print("Failed to reopen log file after rotation: \(error)")
            fileHandle = nil
        }

        log("Log rotated. Previous log saved as \(baseName).log.1", level: .info)
    }
}
