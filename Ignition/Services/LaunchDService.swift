import Foundation
import Combine
import AppKit

@MainActor
class LaunchAgentManager: ObservableObject {
    @Published var agents: [LaunchAgent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedDomain: AgentDomain? = .userAgents
    @Published var searchText = ""
    @Published var pinnedLabels: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(pinnedLabels), forKey: "pinnedAgentLabels")
        }
    }

    private var refreshTimer: Timer?

    // External services wired up from app level
    var historyService: ActivityHistoryService?
    var notificationService: NotificationService?
    var healthMonitor: HealthMonitorService?

    // Bulk selection
    @Published var selectedLabels: Set<String> = []

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "pinnedAgentLabels") ?? []
        self.pinnedLabels = Set(saved)
        startPeriodicRefresh()
    }

    var pinnedAgents: [LaunchAgent] {
        agents.filter { pinnedLabels.contains($0.label) }.sorted { $0.label < $1.label }
    }

    var runningCount: Int {
        agents.filter { $0.status == .running }.count
    }

    func togglePin(_ agent: LaunchAgent) {
        if pinnedLabels.contains(agent.label) {
            pinnedLabels.remove(agent.label)
        } else {
            pinnedLabels.insert(agent.label)
        }
    }

    func isPinned(_ agent: LaunchAgent) -> Bool {
        pinnedLabels.contains(agent.label)
    }

    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStatus()
            }
        }
    }

    var filteredAgents: [LaunchAgent] {
        guard let selectedDomain else { return [] }
        let domainFiltered = agents.filter { $0.domain == selectedDomain }
        if searchText.isEmpty {
            return domainFiltered.sorted { $0.label < $1.label }
        }
        return domainFiltered.filter {
            $0.label.localizedCaseInsensitiveContains(searchText) ||
            ($0.program?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.sorted { $0.label < $1.label }
    }

    var domainCounts: [AgentDomain: Int] {
        var counts: [AgentDomain: Int] = [:]
        for domain in AgentDomain.allCases {
            counts[domain] = agents.filter { $0.domain == domain }.count
        }
        return counts
    }

    func loadAllAgents() async {
        isLoading = true
        errorMessage = nil

        var allAgents: [LaunchAgent] = []
        let runningServices = await fetchRunningServices()

        for domain in AgentDomain.allCases {
            let domainAgents = await loadAgents(from: domain, runningServices: runningServices)
            allAgents.append(contentsOf: domainAgents)
        }

        agents = allAgents
        isLoading = false
    }

    func refreshStatus() async {
        let runningServices = await fetchRunningServices()

        for i in agents.indices {
            let label = agents[i].label
            if let info = runningServices.info(label, in: agents[i].domain) {
                agents[i].pid = info.pid
                agents[i].lastExitStatus = info.exitStatus
                if let pid = info.pid, pid > 0 {
                    agents[i].status = .running
                } else {
                    agents[i].status = .loaded
                }
            } else {
                agents[i].status = .unloaded
                agents[i].pid = nil
            }
        }

        // Detect state changes and record history
        historyService?.detectChanges(agents: agents)

        // Forward crash/stop events to notifications
        if let notif = notificationService, let history = historyService {
            for event in history.recentEvents.prefix(5) {
                // Only handle very recent events (last 15 seconds)
                if Date().timeIntervalSince(event.timestamp) < 15 {
                    notif.handleEvent(event, pinnedLabels: pinnedLabels)
                }
            }
        }

        // Update crash loop detection
        if let history = historyService {
            healthMonitor?.updateCrashLoops(from: history)
        }
    }

    // MARK: - Bulk Operations

    func isSelected(_ agent: LaunchAgent) -> Bool {
        selectedLabels.contains(agent.label)
    }

    func toggleSelection(_ agent: LaunchAgent) {
        if selectedLabels.contains(agent.label) {
            selectedLabels.remove(agent.label)
        } else {
            selectedLabels.insert(agent.label)
        }
    }

    func selectAll() {
        selectedLabels = Set(filteredAgents.map(\.label))
    }

    func deselectAll() {
        selectedLabels.removeAll()
    }

    var selectedAgents: [LaunchAgent] {
        agents.filter { selectedLabels.contains($0.label) }
    }

    func bulkLoad() async {
        for agent in selectedAgents where agent.status == .unloaded {
            _ = await loadAgent(agent)
        }
        deselectAll()
    }

    func bulkUnload() async {
        for agent in selectedAgents where agent.status != .unloaded {
            if agent.status == .running {
                _ = await stopAgent(agent)
            }
            _ = await unloadAgent(agent)
        }
        deselectAll()
    }

    func bulkStart() async {
        for agent in selectedAgents where agent.status == .loaded {
            _ = await startAgent(agent)
        }
        deselectAll()
    }

    func bulkStop() async {
        for agent in selectedAgents where agent.status == .running {
            _ = await stopAgent(agent)
        }
        deselectAll()
    }

    @discardableResult
    func loadAgent(_ agent: LaunchAgent) async -> Bool {
        let result = await control(agent, ["load", agent.plistPath])
        if result.success {
            await refreshStatus()
        }
        return result.success
    }

    @discardableResult
    func unloadAgent(_ agent: LaunchAgent) async -> Bool {
        let result = await control(agent, ["unload", agent.plistPath])
        if result.success {
            await refreshStatus()
        }
        return result.success
    }

    @discardableResult
    func startAgent(_ agent: LaunchAgent) async -> Bool {
        let result = await control(agent, ["start", agent.label])
        if result.success {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshStatus()
        }
        return result.success
    }

    @discardableResult
    func stopAgent(_ agent: LaunchAgent) async -> Bool {
        let result = await control(agent, ["stop", agent.label])
        if result.success {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshStatus()
        }
        return result.success
    }

    /// Run launchctl for an agent: as root for daemons, as the user otherwise.
    /// A failure is surfaced through `errorMessage`.
    private func control(_ agent: LaunchAgent, _ arguments: [String]) async -> LaunchctlResult {
        let result = agent.domain.isDaemon
            ? runLaunchctlAsRoot(arguments)
            : await runLaunchctl(arguments)
        if !result.success, !result.error.isEmpty {
            errorMessage = "\(arguments[0].capitalized) \(agent.label) failed: \(result.error)"
        }
        return result
    }

    /// Run launchctl as root through the macOS admin prompt. macOS remembers
    /// the password for a few minutes, so bulk actions prompt once.
    private func runLaunchctlAsRoot(_ arguments: [String]) -> LaunchctlResult {
        let command = (["/bin/launchctl"] + arguments)
            .map(PlistWriteService.shellQuoted)
            .joined(separator: " ")
        let script = "do shell script \(PlistWriteService.appleScriptQuoted(command)) with administrator privileges"

        var errorInfo: NSDictionary?
        let output = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128: the user cancelled the password prompt, nothing to report.
            let cancelled = errorInfo[NSAppleScript.errorNumber] as? Int == -128
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Admin command failed"
            return LaunchctlResult(success: false, output: "", error: cancelled ? "" : message)
        }
        return LaunchctlResult(success: true, output: output?.stringValue ?? "", error: "")
    }

    func revealInFinder(_ agent: LaunchAgent) {
        let url = URL(fileURLWithPath: agent.plistPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInEditor(_ agent: LaunchAgent) {
        let url = URL(fileURLWithPath: agent.plistPath)
        NSWorkspace.shared.open(url)
    }

    func reloadAgent(_ agent: LaunchAgent) async {
        _ = await runLaunchctl(["unload", agent.plistPath])
        try? await Task.sleep(for: .milliseconds(500))
        _ = await runLaunchctl(["load", agent.plistPath])
        try? await Task.sleep(for: .milliseconds(500))
        await refreshStatus()
    }

    func reloadPlistContents(for agent: LaunchAgent) async {
        guard let data = FileManager.default.contents(atPath: agent.plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx].plistContents = plist
        }
    }

    func createAgent(from formData: AgentFormData, andLoad: Bool) async throws {
        let dict = formData.toPlistDictionary()
        try PlistWriteService.create(dict)
        await loadAllAgents()
        if andLoad {
            if let agent = agents.first(where: { $0.label == formData.label }) {
                _ = await loadAgent(agent)
            }
        }
    }

    // MARK: - Private

    private struct ServiceInfo {
        let pid: Int?
        let exitStatus: Int?
    }

    /// Loaded services in the user's domain and in the system domain (daemons).
    private struct Services {
        var user: [String: ServiceInfo]
        var system: [String: ServiceInfo]

        func info(_ label: String, in domain: AgentDomain) -> ServiceInfo? {
            domain.isDaemon ? system[label] : user[label]
        }
    }

    private func fetchRunningServices() async -> Services {
        Services(user: await fetchUserServices(), system: await fetchSystemServices())
    }

    /// `launchctl print system` is readable without root. Its services block
    /// has one "pid  last-exit  label" row per loaded daemon; pid 0 = not running.
    private func fetchSystemServices() async -> [String: ServiceInfo] {
        let result = await runLaunchctl(["print", "system"])
        guard result.success else { return [:] }

        var services: [String: ServiceInfo] = [:]
        var inServices = false
        for line in result.output.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if row == "}" { break }

            let cols = row.split(whereSeparator: \.isWhitespace)
            guard cols.count == 3, let pid = Int(cols[0]) else { continue }
            services[String(cols[2])] = ServiceInfo(pid: pid > 0 ? pid : nil, exitStatus: Int(cols[1]))
        }
        return services
    }

    private func fetchUserServices() async -> [String: ServiceInfo] {
        let result = await runLaunchctl(["list"])
        guard result.success else { return [:] }

        var services: [String: ServiceInfo] = [:]
        let lines = result.output.split(separator: "\n").dropFirst() // skip header

        for line in lines {
            let cols = line.split(separator: "\t", maxSplits: 2)
            guard cols.count == 3 else { continue }

            let pidStr = String(cols[0]).trimmingCharacters(in: .whitespaces)
            let exitStr = String(cols[1]).trimmingCharacters(in: .whitespaces)
            let label = String(cols[2]).trimmingCharacters(in: .whitespaces)

            let pid = pidStr == "-" ? nil : Int(pidStr)
            let exitStatus = exitStr == "-" ? nil : Int(exitStr)

            services[label] = ServiceInfo(pid: pid, exitStatus: exitStatus)
        }

        return services
    }

    private func loadAgents(from domain: AgentDomain, runningServices: Services) async -> [LaunchAgent] {
        let path = domain.path
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        var agents: [LaunchAgent] = []

        for file in files where file.hasSuffix(".plist") {
            let fullPath = (path as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: fullPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }

            var status: AgentStatus = .unloaded
            var pid: Int?
            var exitStatus: Int?

            if let info = runningServices.info(label, in: domain) {
                pid = info.pid
                exitStatus = info.exitStatus
                if let p = info.pid, p > 0 {
                    status = .running
                } else {
                    status = .loaded
                }
            }

            if plist["Disabled"] as? Bool == true {
                status = .unloaded
            }

            let agent = LaunchAgent(
                id: "\(domain.rawValue):\(label)",
                label: label,
                domain: domain,
                plistPath: fullPath,
                status: status,
                pid: pid,
                lastExitStatus: exitStatus,
                plistContents: plist
            )
            agents.append(agent)
        }

        return agents
    }

    private struct LaunchctlResult {
        let success: Bool
        let output: String
        let error: String
    }

    private func runLaunchctl(_ arguments: [String]) async -> LaunchctlResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()

                    // Read before waiting: output over the 64 KB pipe buffer
                    // (e.g. `print system`) would block launchctl forever.
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let result = LaunchctlResult(
                        success: process.terminationStatus == 0,
                        output: String(data: outData, encoding: .utf8) ?? "",
                        error: String(data: errData, encoding: .utf8) ?? ""
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(returning: LaunchctlResult(
                        success: false, output: "", error: error.localizedDescription
                    ))
                }
            }
        }
    }
}
