import Foundation
import SQLite3

/// Tells SQLite to copy bound text. Swift strings passed to C are only valid
/// during the call, so binding them with a nil destructor (SQLITE_STATIC)
/// can leave SQLite reading freed memory.
private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

struct ActivityEvent: Identifiable, Equatable {
    let id: Int64
    let label: String
    let eventType: EventType
    let exitCode: Int?
    let timestamp: Date
    let detail: String?

    enum EventType: String {
        case started = "started"
        case stopped = "stopped"
        case crashed = "crashed"
        case loaded = "loaded"
        case unloaded = "unloaded"

        var icon: String {
            switch self {
            case .started: return "play.circle.fill"
            case .stopped: return "stop.circle.fill"
            case .crashed: return "exclamationmark.triangle.fill"
            case .loaded: return "arrow.down.circle.fill"
            case .unloaded: return "arrow.up.circle.fill"
            }
        }

        var colorName: String {
            switch self {
            case .started: return "green"
            case .stopped: return "gray"
            case .crashed: return "red"
            case .loaded: return "blue"
            case .unloaded: return "orange"
            }
        }
    }
}

@MainActor
class ActivityHistoryService: ObservableObject {
    @Published var recentEvents: [ActivityEvent] = []

    nonisolated(unsafe) private var db: OpaquePointer?
    private let dbPath: String

    // Track previous state to detect transitions
    private var previousStates: [String: AgentStatus] = [:]
    private var previousPIDs: [String: Int] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Ignition", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("activity.db").path
        openDatabase()
        createTable()
        loadRecentEvents()
    }

    func recordEvent(label: String, type: ActivityEvent.EventType, exitCode: Int? = nil, detail: String? = nil) {
        let now = Date()
        insertEvent(label: label, type: type, exitCode: exitCode, timestamp: now, detail: detail)
        loadRecentEvents()
    }

    func detectChanges(agents: [LaunchAgent]) {
        for agent in agents {
            let prev = previousStates[agent.label]
            let prevPID = previousPIDs[agent.label]

            if let prev = prev {
                // Detect transitions
                if prev != .running && agent.status == .running {
                    recordEvent(label: agent.label, type: .started, detail: agent.pid.map { "PID \($0)" })
                } else if prev == .running && agent.status != .running {
                    if let exit = agent.lastExitStatus, exit != 0 {
                        recordEvent(label: agent.label, type: .crashed, exitCode: exit)
                    } else {
                        recordEvent(label: agent.label, type: .stopped, exitCode: agent.lastExitStatus)
                    }
                } else if prev == .unloaded && agent.status == .loaded {
                    recordEvent(label: agent.label, type: .loaded)
                } else if prev != .unloaded && agent.status == .unloaded {
                    recordEvent(label: agent.label, type: .unloaded)
                }
                // Detect PID change (crash-restart)
                else if agent.status == .running,
                        let newPID = agent.pid, let oldPID = prevPID,
                        newPID != oldPID {
                    recordEvent(label: agent.label, type: .crashed, exitCode: agent.lastExitStatus, detail: "Restarted: PID \(oldPID) → \(newPID)")
                    recordEvent(label: agent.label, type: .started, detail: "PID \(newPID)")
                }
            }

            previousStates[agent.label] = agent.status
            if let pid = agent.pid { previousPIDs[agent.label] = pid }
        }
    }

    func eventsForAgent(_ label: String, limit: Int = 100) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let query = "SELECT id, label, event_type, exit_code, timestamp, detail FROM activity WHERE label = ? ORDER BY timestamp DESC LIMIT ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, label, -1, sqliteTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = eventFromRow(stmt) {
                events.append(event)
            }
        }
        return events
    }

    func allRecentEvents(limit: Int = 200) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let query = "SELECT id, label, event_type, exit_code, timestamp, detail FROM activity ORDER BY timestamp DESC LIMIT ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = eventFromRow(stmt) {
                events.append(event)
            }
        }
        return events
    }

    /// Agents that have crashed 3+ times in the last hour
    func crashLoopAgents() -> [String: Int] {
        let query = """
            SELECT label, COUNT(*) as crash_count FROM activity
            WHERE event_type = 'crashed' AND timestamp > ?
            GROUP BY label HAVING crash_count >= 3
            ORDER BY crash_count DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        let oneHourAgo = Date().timeIntervalSince1970 - 3600
        sqlite3_bind_double(stmt, 1, oneHourAgo)

        var results: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let labelCStr = sqlite3_column_text(stmt, 0) {
                let label = String(cString: labelCStr)
                let count = Int(sqlite3_column_int(stmt, 1))
                results[label] = count
            }
        }
        return results
    }

    func clearHistory() {
        let query = "DELETE FROM activity"
        sqlite3_exec(db, query, nil, nil, nil)
        loadRecentEvents()
    }

    func clearHistory(for label: String) {
        let query = "DELETE FROM activity WHERE label = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, label, -1, sqliteTransient)
        sqlite3_step(stmt)
        loadRecentEvents()
    }

    // MARK: - Private

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTable() {
        let query = """
            CREATE TABLE IF NOT EXISTS activity (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                label TEXT NOT NULL,
                event_type TEXT NOT NULL,
                exit_code INTEGER,
                timestamp REAL NOT NULL,
                detail TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_activity_label ON activity(label);
            CREATE INDEX IF NOT EXISTS idx_activity_timestamp ON activity(timestamp);
        """
        sqlite3_exec(db, query, nil, nil, nil)
    }

    private func insertEvent(label: String, type: ActivityEvent.EventType, exitCode: Int?, timestamp: Date, detail: String?) {
        let query = "INSERT INTO activity (label, event_type, exit_code, timestamp, detail) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, label, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, sqliteTransient)
        if let code = exitCode {
            sqlite3_bind_int(stmt, 3, Int32(code))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, timestamp.timeIntervalSince1970)
        if let detail = detail {
            sqlite3_bind_text(stmt, 5, detail, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        sqlite3_step(stmt)
    }

    private func loadRecentEvents() {
        recentEvents = allRecentEvents(limit: 50)
    }

    private func eventFromRow(_ stmt: OpaquePointer?) -> ActivityEvent? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        guard let labelCStr = sqlite3_column_text(stmt, 1),
              let typeCStr = sqlite3_column_text(stmt, 2) else { return nil }

        let label = String(cString: labelCStr)
        let typeStr = String(cString: typeCStr)
        guard let eventType = ActivityEvent.EventType(rawValue: typeStr) else { return nil }

        let exitCode = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let detail: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5))

        return ActivityEvent(id: id, label: label, eventType: eventType, exitCode: exitCode, timestamp: timestamp, detail: detail)
    }

    deinit {
        sqlite3_close(db)
    }
}
