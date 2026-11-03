import Foundation

enum AgentDomain: String, CaseIterable, Identifiable {
    case userAgents = "User Agents"
    case globalAgents = "Global Agents"
    case globalDaemons = "Global Daemons"
    case systemAgents = "System Agents"
    case systemDaemons = "System Daemons"

    var id: String { rawValue }

    var path: String {
        switch self {
        case .userAgents: return "\(NSHomeDirectory())/Library/LaunchAgents"
        case .globalAgents: return "/Library/LaunchAgents"
        case .globalDaemons: return "/Library/LaunchDaemons"
        case .systemAgents: return "/System/Library/LaunchAgents"
        case .systemDaemons: return "/System/Library/LaunchDaemons"
        }
    }

    var icon: String {
        switch self {
        case .userAgents: return "person.fill"
        case .globalAgents: return "person.2.fill"
        case .globalDaemons: return "gearshape.2.fill"
        case .systemAgents: return "apple.logo"
        case .systemDaemons: return "cpu"
        }
    }

    var isEditable: Bool {
        switch self {
        case .userAgents: return true
        case .globalAgents, .globalDaemons: return true
        case .systemAgents, .systemDaemons: return false
        }
    }

    /// Daemons live in launchd's system domain, so controlling them needs root.
    var isDaemon: Bool { self == .globalDaemons || self == .systemDaemons }
}

enum AgentStatus: String {
    case loaded = "Loaded"
    case unloaded = "Unloaded"
    case running = "Running"
    case error = "Error"
    case unknown = "Unknown"

    var color: String {
        switch self {
        case .running: return "green"
        case .loaded: return "blue"
        case .unloaded: return "gray"
        case .error: return "red"
        case .unknown: return "orange"
        }
    }

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .loaded: return "circle.lefthalf.filled"
        case .unloaded: return "circle"
        case .error: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct LaunchAgent: Identifiable, Hashable {
    let id: String
    let label: String
    let domain: AgentDomain
    let plistPath: String
    var status: AgentStatus
    var pid: Int?
    var lastExitStatus: Int?
    var plistContents: [String: Any]

    var program: String? {
        if let prog = plistContents["Program"] as? String {
            return prog
        }
        if let args = plistContents["ProgramArguments"] as? [String], let first = args.first {
            return first
        }
        return nil
    }

    var programArguments: [String]? {
        plistContents["ProgramArguments"] as? [String]
    }

    var isKeepAlive: Bool {
        if let keepAlive = plistContents["KeepAlive"] as? Bool {
            return keepAlive
        }
        if plistContents["KeepAlive"] is [String: Any] {
            return true
        }
        return false
    }

    var runAtLoad: Bool {
        plistContents["RunAtLoad"] as? Bool ?? false
    }

    var startInterval: Int? {
        plistContents["StartInterval"] as? Int
    }

    var watchPaths: [String]? {
        plistContents["WatchPaths"] as? [String]
    }

    var standardOutPath: String? {
        plistContents["StandardOutPath"] as? String
    }

    var standardErrorPath: String? {
        plistContents["StandardErrorPath"] as? String
    }

    var isDisabled: Bool {
        plistContents["Disabled"] as? Bool ?? false
    }

    var displayName: String {
        // Try to make a friendly name from the label
        let parts = label.split(separator: ".")
        if parts.count >= 3 {
            return String(parts.last!)
        }
        return label
    }

    static func == (lhs: LaunchAgent, rhs: LaunchAgent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
