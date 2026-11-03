import Foundation
import AppKit

struct ImportExportService {

    /// Export agent plists to a directory as a bundle.
    static func exportAgents(_ agents: [LaunchAgent], to directory: URL) throws -> URL {
        let fm = FileManager.default
        let bundleName = "Ignition-Export-\(dateString())"
        let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)

        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Write manifest
        var manifest: [[String: String]] = []

        for agent in agents {
            let fileName = "\(agent.label).plist"
            let destURL = bundleURL.appendingPathComponent(fileName)

            // Copy plist
            if fm.fileExists(atPath: agent.plistPath) {
                try fm.copyItem(atPath: agent.plistPath, toPath: destURL.path)
            } else {
                // Generate from in-memory contents
                let data = try PropertyListSerialization.data(
                    fromPropertyList: agent.plistContents,
                    format: .xml,
                    options: 0
                )
                try data.write(to: destURL)
            }

            manifest.append([
                "label": agent.label,
                "domain": agent.domain.rawValue,
                "file": fileName
            ])
        }

        // Write manifest
        let manifestData = try PropertyListSerialization.data(
            fromPropertyList: manifest,
            format: .xml,
            options: 0
        )
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.plist"))

        return bundleURL
    }

    /// Export a single agent plist.
    static func exportSingleAgent(_ agent: LaunchAgent) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(agent.label).plist"
        panel.allowedContentTypes = [.xml]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: agent.plistContents,
                    format: .xml,
                    options: 0
                )
                try data.write(to: url)
            } catch {
                // Silently fail — could show alert in future
            }
        }
    }

    /// Import plist files, returning the parsed dictionaries and intended paths.
    static func importPlists() -> [(dict: [String: Any], suggestedLabel: String)]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.xml, .propertyList]
        panel.message = "Select .plist files or an Ignition export folder"

        guard panel.runModal() == .OK else { return nil }

        var results: [(dict: [String: Any], suggestedLabel: String)] = []

        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Import all plists in directory
                if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                    for file in files where file.hasSuffix(".plist") && file != "manifest.plist" {
                        let filePath = (url.path as NSString).appendingPathComponent(file)
                        if let parsed = parsePlist(at: filePath) {
                            results.append(parsed)
                        }
                    }
                }
            } else {
                if let parsed = parsePlist(at: url.path) {
                    results.append(parsed)
                }
            }
        }

        return results.isEmpty ? nil : results
    }

    /// Backup all user agents to a timestamped directory.
    static func backupUserAgents() throws -> URL {
        let fm = FileManager.default
        let backupDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ignition/Backups/\(dateString())", isDirectory: true)

        // Plists can hold secrets, so keep backups private to this user.
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let userAgentsPath = AgentDomain.userAgents.path
        guard let files = try? fm.contentsOfDirectory(atPath: userAgentsPath) else {
            return backupDir
        }

        for file in files where file.hasSuffix(".plist") {
            let src = (userAgentsPath as NSString).appendingPathComponent(file)
            let dst = backupDir.appendingPathComponent(file)
            try fm.copyItem(atPath: src, toPath: dst.path)
        }

        return backupDir
    }

    // MARK: - Private

    private static func parsePlist(at path: String) -> (dict: [String: Any], suggestedLabel: String)? {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else {
            return nil
        }
        return (dict: dict, suggestedLabel: label)
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
