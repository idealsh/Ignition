# Ignition

A modern, native macOS launch agent manager built with SwiftUI. Browse, control, create, and monitor launchd agents and daemons — all from one app.

Ignition is a free, open-source alternative to LaunchControl.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/License-MIT-green)
[![Release](https://img.shields.io/github/v/release/Acelogic/Ignition)](https://github.com/Acelogic/Ignition/releases/latest)

## Download

**[Download Ignition v1.0.0](https://github.com/Acelogic/Ignition/releases/latest/download/Ignition-1.0.0.dmg)** — Open the DMG and drag Ignition to your Applications folder.

To check the app's signature and Gatekeeper status before running it:

```bash
codesign -dv --verbose=4 /Applications/Ignition.app
spctl -a -vv /Applications/Ignition.app
```

## Screenshots

### Agent List
Browse agents across all launchd domains with status indicators, tags, and search filtering.

![Agent List](docs/screenshots/agent-list.png)

### Agent Detail
Full agent detail view with action buttons, configuration properties, activity history, and plist editor.

![Agent Detail](docs/screenshots/agent-detail.png)

### Health Dashboard
At-a-glance system health with overview cards, problem agent detection, and resource monitoring for running agents.

![Health Dashboard](docs/screenshots/health-dashboard.png)

## Features

### Agent Management
- **Browse all domains** — User Agents, Global Agents/Daemons, System Agents/Daemons
- **Start, Stop, Load, Unload** — Full launchctl control with one click
- **Search & Filter** — Quickly find agents by label or program path
- **Bulk Operations** — Multi-select agents for batch load/unload/start/stop

### Live Log Viewer
- Real-time log tailing using kqueue file monitoring
- Supports both stdout and stderr paths
- Auto-scroll, search filtering, copy, and clear
- Stderr lines highlighted in red

### In-App Plist Editor
- Recursive key-value editor with type-aware controls
- Add/remove keys, edit nested dictionaries and arrays
- Automatic backup before saving
- Read-only mode for system domains
- Admin password prompt for global domains (via AppleScript)

### Create Agent Wizard
- 5 templates: Run Script, Watch Folder, Run at Login, Scheduled Task, Blank
- 3-step workflow: Template → Configure → Review XML → Create
- Automatic plist validation and loading

### Menu Bar Quick Access
- Pin frequently-used agents to the menu bar
- Status dots and load/unload toggles for pinned agents
- Always-accessible flame icon in the menu bar

### Health Dashboard
- Overview cards: total agents, running count, problems, crash loops
- CPU and memory monitoring for running agents (via `ps`)
- Crash loop detection (3+ crashes in the last hour)
- Problem agents list with actionable details

### Activity History
- SQLite-backed event log tracking start/stop/crash/load/unload events
- Per-agent timeline in the detail view
- Global timeline in the Health Dashboard
- Automatic state change detection on each refresh cycle

### Notifications
- macOS notifications when pinned agents crash or stop
- Configurable: crash alerts, stop alerts, or both
- Uses native `UserNotifications` framework

### Import / Export
- Export single agents or bulk export with manifest
- Import plist files or Ignition export bundles
- One-click backup of all user agents

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16+ (to build from source)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the Xcode project)

## Building

```bash
# Install XcodeGen if you haven't already
brew install xcodegen

# Clone and build
git clone https://github.com/Acelogic/Ignition.git
cd Ignition
xcodegen generate
xcodebuild -scheme Ignition -derivedDataPath build build
```

To run the built app:

```bash
open build/Build/Products/Debug/Ignition.app
```

Building into `./build` means you always open the app you just built, not an older copy left in Xcode's shared DerivedData folder.

The build has no script phases or package dependencies. Build settings live in both `project.yml` and the generated `Ignition.xcodeproj`, so review both when pulling changes.

Or open `Ignition.xcodeproj` in Xcode and press **Cmd+R**.

## Architecture

```
Ignition/
├── IgnitionApp.swift              # App entry point, scene setup
├── Models/
│   ├── LaunchAgent.swift          # Agent model, domain & status enums
│   ├── PlistValue.swift           # Recursive typed plist representation
│   └── AgentTemplate.swift        # Wizard templates & form data
├── Services/
│   ├── LaunchDService.swift       # Core agent manager (launchctl wrapper)
│   ├── LogTailService.swift       # kqueue-based file tailing
│   ├── PlistWriteService.swift    # Plist validation & atomic writing
│   ├── ActivityHistoryService.swift # SQLite event store
│   ├── HealthMonitorService.swift # CPU/memory polling & crash detection
│   ├── NotificationService.swift  # macOS notification delivery
│   └── ImportExportService.swift  # Plist import/export/backup
└── Views/
    ├── ContentView.swift          # 3-column NavigationSplitView + sidebar
    ├── AgentListView.swift        # Agent list with bulk operations
    ├── AgentRowView.swift         # List row with status, tags, pin icon
    ├── AgentDetailView.swift      # Full agent detail with all sections
    ├── LogViewerView.swift        # Live log viewer UI
    ├── PlistEditorView.swift      # Recursive plist key-value editor
    ├── CreateAgentView.swift      # 3-step creation wizard
    ├── MenuBarView.swift          # Menu bar popover
    ├── HealthDashboardView.swift  # Health overview + resource table
    └── ActivityHistoryView.swift  # Event timeline
```

## License

MIT License. See [LICENSE](LICENSE) for details.
