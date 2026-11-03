import SwiftUI

struct AgentRowView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    private let selected: LaunchAgent
    private var agent: LaunchAgent { manager.current(selected) }

    init(agent: LaunchAgent) { selected = agent }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Animated status indicator
            ZStack {
                if agent.status == .running {
                    Circle()
                        .fill(statusColor.opacity(0.25))
                        .frame(width: 18, height: 18)
                        .scaleEffect(isHovered ? 1.3 : 1.0)
                }
                Image(systemName: agent.status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: agent.status == .running)
            }
            .frame(width: 20)
            .animation(.easeInOut(duration: 0.2), value: isHovered)

            // Agent info
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let program = agent.program {
                        Text(shortenPath(program))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if agent.isKeepAlive {
                        TagView(text: "KeepAlive", color: .blue)
                    }

                    if agent.runAtLoad {
                        TagView(text: "RunAtLoad", color: .purple)
                    }

                    if agent.watchPaths != nil {
                        TagView(text: "WatchPaths", color: .orange)
                    }

                    if agent.startInterval != nil {
                        TagView(text: "Interval", color: .teal)
                    }
                }
            }

            Spacer()

            // Pin indicator
            if manager.isPinned(agent) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(45))
            }

            // PID badge
            if let pid = agent.pid, pid > 0 {
                Text("PID \(pid)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }

            // Status text
            Text(agent.status.rawValue)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .running: return .green
        case .loaded: return .blue
        case .unloaded: return .gray
        case .error: return .red
        case .unknown: return .orange
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct TagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
