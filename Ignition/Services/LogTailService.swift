import Foundation

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
    let timestamp: Date

    static func == (lhs: LogLine, rhs: LogLine) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class LogTailService: ObservableObject {
    @Published var lines: [LogLine] = []
    @Published var isActive = false
    @Published var errorMessage: String?

    private var stdoutSource: DispatchSourceFileSystemObject?
    private var stderrSource: DispatchSourceFileSystemObject?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private let maxLines = 5000

    func startTailing(stdoutPath: String?, stderrPath: String?) {
        stop()
        lines = []
        errorMessage = nil
        isActive = true

        if let path = stdoutPath {
            startTailingFile(path: path, isError: false)
        }
        if let path = stderrPath {
            startTailingFile(path: path, isError: true)
        }

        if stdoutSource == nil && stderrSource == nil {
            errorMessage = "Could not open any log files"
            isActive = false
        }
    }

    func stop() {
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil

        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        stdoutHandle = nil
        stderrHandle = nil

        isActive = false
    }

    func clear() {
        lines = []
    }

    private func startTailingFile(path: String, isError: Bool) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: expandedPath),
              fm.isReadableFile(atPath: expandedPath) else {
            return
        }

        guard let handle = FileHandle(forReadingAtPath: expandedPath) else {
            return
        }

        // Seek to last 100KB for initial content
        let fileSize = handle.seekToEndOfFile()
        let seekOffset = fileSize > 102400 ? fileSize - 102400 : 0
        handle.seek(toFileOffset: seekOffset)

        // Read initial content
        let initialData = handle.readDataToEndOfFile()
        if let text = String(data: initialData, encoding: .utf8) {
            var initialLines = text.components(separatedBy: .newlines)
            // If we seeked past the start, drop partial first line
            if seekOffset > 0 {
                initialLines = Array(initialLines.dropFirst())
            }
            for line in initialLines where !line.isEmpty {
                appendLine(line, isError: isError)
            }
        }

        // Set up kqueue monitoring
        let fd = Darwin.open(expandedPath, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .delete, .rename],
            // Handlers made here are main-actor code (this class is @MainActor),
            // and Swift traps if they run on any other queue.
            queue: .main
        )

        source.setEventHandler { [weak self] in
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File rotated — re-open after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.handleFileRotation(path: expandedPath, isError: isError)
                }
                return
            }

            let newData = handle.readDataToEndOfFile()
            if let text = String(data: newData, encoding: .utf8) {
                let newLines = text.components(separatedBy: .newlines)
                Task { @MainActor [weak self] in
                    for line in newLines where !line.isEmpty {
                        self?.appendLine(line, isError: isError)
                    }
                }
            }
        }

        // The only place fd is closed: closing it elsewhere too could close
        // an unrelated file that reused the number.
        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()

        if isError {
            stderrSource = source
            stderrHandle = handle
        } else {
            stdoutSource = source
            stdoutHandle = handle
        }
    }

    private func handleFileRotation(path: String, isError: Bool) {
        if isError {
            stderrSource?.cancel()
            stderrSource = nil
            stderrHandle?.closeFile()
            stderrHandle = nil
        } else {
            stdoutSource?.cancel()
            stdoutSource = nil
            stdoutHandle?.closeFile()
            stdoutHandle = nil
        }
        // Try to reopen
        startTailingFile(path: path, isError: isError)
    }

    private func appendLine(_ text: String, isError: Bool) {
        let line = LogLine(text: text, isError: isError, timestamp: Date())
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    deinit {
        stdoutSource?.cancel()
        stderrSource?.cancel()
    }
}
