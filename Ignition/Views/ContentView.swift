import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var historyService: ActivityHistoryService
    @EnvironmentObject var healthMonitor: HealthMonitorService
    @EnvironmentObject var notificationService: NotificationService
    @State private var selectedAgent: LaunchAgent?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCreateSheet = false
    @State private var showingImportAlert = false
    @State private var importMessage = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedAgent: $selectedAgent)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            if manager.selectedDomain != nil {
                AgentListView(selectedAgent: $selectedAgent)
                    .navigationSplitViewColumnWidth(min: 350, ideal: 450, max: 600)
            } else {
                // Health dashboard takes full width
                Text("")
                    .navigationSplitViewColumnWidth(min: 0, ideal: 0, max: 0)
            }
        } detail: {
            Group {
                if manager.selectedDomain == nil {
                    HealthDashboardView()
                } else if let agent = selectedAgent {
                    AgentDetailView(agent: agent)
                        .id(agent.id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    EmptyDetailView()
                }
            }
            .animation(.smooth(duration: 0.25), value: selectedAgent?.id)
        }
        .searchable(text: $manager.searchText, prompt: "Filter agents...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create new agent")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Plists...") { importPlists() }
                    Button("Export Selected...") { exportSelected() }
                    Divider()
                    Button("Backup User Agents") { backupUserAgents() }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .help("Import / Export")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateAgentView()
                .environmentObject(manager)
        }
        .alert("Import", isPresented: $showingImportAlert) {
            Button("OK") {}
        } message: {
            Text(importMessage)
        }
        .alert("Action Failed", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(manager.errorMessage ?? "")
        }
        .task {
            await manager.loadAllAgents()
        }
    }

    private func importPlists() {
        guard let imports = ImportExportService.importPlists() else { return }
        guard confirmImport(imports) else { return }
        var imported = 0
        var failures: [String] = []
        for item in imports {
            do {
                try PlistWriteService.create(item.dict)
                imported += 1
            } catch {
                failures.append("\(item.suggestedLabel): \(error.localizedDescription)")
            }
        }
        importMessage = (["Imported \(imported) of \(imports.count) agent(s)."] + failures)
            .joined(separator: "\n")
        showingImportAlert = true
        Task { await manager.loadAllAgents() }
    }

    /// Imported agents run at every login, so show exactly what each one runs
    /// and make the user confirm before anything is written.
    private func confirmImport(_ imports: [(dict: [String: Any], suggestedLabel: String)]) -> Bool {
        let summary = imports.map { item in
            let command = [item.dict["Program"] as? String].compactMap { $0 }
                + (item.dict["ProgramArguments"] as? [String] ?? [])
            return "\(item.suggestedLabel)\n    \(command.joined(separator: " "))"
        }.joined(separator: "\n\n")

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 220)
        if let text = scroll.documentView as? NSTextView {
            text.string = summary
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import \(imports.count) agent(s)?"
        alert.informativeText = "These agents will be added to your user LaunchAgents and loaded at every login, running the commands below. Only import plists from sources you trust."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func exportSelected() {
        let agentsToExport = manager.selectedAgents.isEmpty ? manager.filteredAgents : manager.selectedAgents
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose export destination"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let exportURL = try ImportExportService.exportAgents(agentsToExport, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            } catch {
                importMessage = "Export failed: \(error.localizedDescription)"
                showingImportAlert = true
            }
        }
    }

    private func backupUserAgents() {
        do {
            let backupURL = try ImportExportService.backupUserAgents()
            importMessage = "Backed up to:\n\(backupURL.path)"
            showingImportAlert = true
        } catch {
            importMessage = "Backup failed: \(error.localizedDescription)"
            showingImportAlert = true
        }
    }
}

enum SidebarSelection: Hashable {
    case domain(AgentDomain)
    case healthDashboard
}

struct SidebarView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var healthMonitor: HealthMonitorService
    @Binding var selectedAgent: LaunchAgent?
    @State private var isRefreshing = false
    @State private var sidebarSelection: SidebarSelection? = .domain(.userAgents)

    var body: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label {
                    HStack {
                        Text("Health Dashboard")
                        Spacer()
                        if !healthMonitor.problemAgents.isEmpty {
                            Text("\(healthMonitor.problemAgents.count)")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.red, in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "heart.text.square")
                        .foregroundColor(.red)
                }
                .tag(SidebarSelection.healthDashboard)
            }

            Section("Domains") {
                ForEach(AgentDomain.allCases) { domain in
                    SidebarRow(domain: domain, count: manager.domainCounts[domain] ?? 0)
                        .tag(SidebarSelection.domain(domain))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Ignition")
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isRefreshing = true
                    }
                    Task {
                        await manager.loadAllAgents()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isRefreshing = false
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .help("Refresh all agents")
            }
        }
        .onChange(of: sidebarSelection) {
            syncSelection()
        }
        .onAppear {
            syncSelection()
        }
        .animation(.smooth, value: sidebarSelection)
    }

    private func syncSelection() {
        switch sidebarSelection {
        case .domain(let domain):
            manager.selectedDomain = domain
        case .healthDashboard:
            manager.selectedDomain = nil
        case nil:
            break
        }
    }
}

struct SidebarRow: View {
    let domain: AgentDomain
    let count: Int
    @State private var isHovered = false

    var body: some View {
        Label {
            HStack {
                Text(domain.rawValue)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        } icon: {
            Image(systemName: domain.icon)
                .foregroundColor(domain.isEditable ? .accentColor : .secondary)
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }
}

struct EmptyDetailView: View {
    @State private var flameScale: CGFloat = 0.9
    @State private var flameOpacity: Double = 0.3

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "flame")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
                .scaleEffect(flameScale)
                .opacity(flameOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        flameScale = 1.05
                        flameOpacity = 0.5
                    }
                }
            Text("Select an agent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Choose a launch agent from the list to view its details")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
