import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var manager: LaunchAgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "flame")
                    .foregroundStyle(.orange)
                Text("Ignition")
                    .font(.system(.headline, weight: .bold))
                Spacer()
                Text("\(manager.runningCount) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if manager.pinnedAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No pinned agents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Right-click agents in Ignition to pin them here")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(manager.pinnedAgents) { agent in
                            MenuBarAgentRow(agent: agent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer actions
            HStack {
                Button("Open Ignition") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .medium))

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
    }
}

struct MenuBarAgentRow: View {
    @EnvironmentObject var manager: LaunchAgentManager
    private let selected: LaunchAgent
    private var agent: LaunchAgent { manager.current(selected) }

    init(agent: LaunchAgent) { selected = agent }
    @State private var isHovered = false
    @State private var isToggling = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.system(.caption, weight: .medium))
                    .lineLimit(1)
                Text(agent.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { agent.status == .running || agent.status == .loaded },
                    set: { shouldLoad in
                        isToggling = true
                        Task {
                            if shouldLoad {
                                _ = await manager.loadAgent(agent)
                            } else {
                                if agent.status == .running {
                                    _ = await manager.stopAgent(agent)
                                }
                                _ = await manager.unloadAgent(agent)
                            }
                            isToggling = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.gray.opacity(0.1) : .clear)
        .onHover { isHovered = $0 }
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
}
