import Foundation
import AppKit

struct PlistWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PlistWriteService {

    /// Validate plist contents before writing.
    static func validate(_ dict: [String: Any]) throws {
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            throw PlistWriteError(message: "Plist must contain a non-empty 'Label' key.")
        }

        // Must have Program or ProgramArguments
        let hasProgram = dict["Program"] is String
        let hasArgs = (dict["ProgramArguments"] as? [String])?.isEmpty == false
        if !hasProgram && !hasArgs {
            throw PlistWriteError(message: "Plist must contain 'Program' or 'ProgramArguments'.")
        }
    }

    /// Write plist to disk. Creates backup of existing file. Uses admin prompt for non-user domains.
    static func write(_ dict: [String: Any], to path: String, requiresAdmin: Bool) throws {
        try validate(dict)

        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )

        let fm = FileManager.default

        if requiresAdmin {
            try writeWithAdmin(data: data, to: path)
        } else {
            // Backup existing file
            if fm.fileExists(atPath: path) {
                let backupPath = path + ".backup"
                try? fm.removeItem(atPath: backupPath)
                try? fm.copyItem(atPath: path, toPath: backupPath)
            }

            // Atomic write replaces the file, which would reset its permissions.
            // Keep them, so a plist locked to 600 (e.g. tokens in
            // EnvironmentVariables) doesn't become readable by other users.
            // New files start private (600).
            let oldPermissions = try? fm.attributesOfItem(atPath: path)[.posixPermissions]
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: oldPermissions ?? 0o600], ofItemAtPath: path)
        }
    }

    /// Write using AppleScript admin prompt for global domains.
    /// The plist bytes travel inside the script as base64, so there is no
    /// user-writable temp file another process could swap while the password
    /// prompt is open. The old file is backed up and the new one is staged in
    /// the root-owned target directory, then moved into place.
    private static func writeWithAdmin(data: Data, to path: String) throws {
        let target = shellQuoted(path)
        let staging = shellQuoted(path + ".ignition-tmp")
        let command = [
            "{ [ ! -e \(target) ] || /bin/cp -p \(target) \(shellQuoted(path + ".backup")); }",
            "printf %s \(data.base64EncodedString()) | /usr/bin/base64 -D > \(staging)",
            "/usr/sbin/chown root:wheel \(staging)",
            "/bin/chmod 644 \(staging)",
            "/bin/mv -f \(staging) \(target)",
        ].joined(separator: " && ")

        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        guard let appleScript = NSAppleScript(source: script) else {
            throw PlistWriteError(message: "Failed to create admin prompt.")
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Admin write failed"
            throw PlistWriteError(message: msg)
        }
    }

    /// Labels become filenames, so they must not contain "/" or start with ".".
    static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.hasPrefix(".") && !label.contains("/") && !label.contains("\0")
    }

    /// Create a new plist in ~/Library/LaunchAgents, named after its Label.
    static func create(_ dict: [String: Any]) throws {
        let label = dict["Label"] as? String ?? ""
        guard isSafeLabel(label) else {
            throw PlistWriteError(message: "Label '\(label)' can't be used as a file name. It must not contain '/' or start with '.'.")
        }
        let path = AgentDomain.userAgents.path + "/\(label).plist"
        let fm = FileManager.default

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        guard !fm.fileExists(atPath: path) else {
            throw PlistWriteError(message: "File already exists at \(path)")
        }

        try write(dict, to: path, requiresAdmin: false)
    }

    /// Single-quote a string for /bin/sh, so quotes or `$(...)` in a path stay literal.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wrap a string as an AppleScript string literal.
    static func appleScriptQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
