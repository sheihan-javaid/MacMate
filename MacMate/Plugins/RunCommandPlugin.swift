//
//  RunCommandPlugin.swift
//  MacMate
//
//  Plugin allowing remote execution of predefined shell commands on macOS.
//

import Foundation
import Combine

public final class RunCommandPlugin: ObservableObject, MacMatePlugin, @unchecked Sendable {
    public static let requestType = "kdeconnect.runcommand.request"
    public static let runCommandType = "kdeconnect.runcommand"
    public static let outputType = "kdeconnect.runcommand.output"

    public var supportedPacketTypes: [String] {
        [Self.requestType]
    }

    @Published public private(set) var commands: [RemoteCommand] = []
    @Published public private(set) var commandLogs: [String: [String]] = [:]

    private let lock = NSLock()
    private var activeProcesses: [UInt32: Process] = [:]
    private var executionCounter: UInt32 = 0
    private let userDefaultsKey = "macmate_remote_commands"
    private let legacyUserDefaultsKey = "tether_remote_commands"

    /// Commands › "Show my Shortcuts on the phone". Off by default: a shortcut
    /// can do anything, so exposing them is the user's choice.
    static let shortcutsKey = "macmate_share_shortcuts"
    static let legacyShortcutsKey = "tether_share_shortcuts"
    static let shortcutPrefix = "shortcut:"
    /// The user's Shortcuts, as commands, when sharing them is on.
    private var shortcutCommands: [RemoteCommand] = []
    private var connections: [String: DeviceConnection] = [:]
    private let defaults: UserDefaults

    /// Tests pass their own `defaults` so they never touch the saved commands.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadCommands()
    }

    public func onConnected(connection: DeviceConnection) {
        if let id = connection.peerDeviceInfo?.deviceId {
            lock.withLock { connections[id] = connection }
        }
        sendConfig(to: connection)
        refreshShortcuts()
    }

    public func onDisconnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        lock.withLock { if connections[id] === connection { connections[id] = nil } }
    }

    // MARK: - Shortcuts

    /// Reads the user's Shortcuts and sends the updated list to every
    /// connected phone. Also called when the setting changes.
    public func refreshShortcuts() {
        let enabled = defaults.object(forKey: Self.shortcutsKey) as? Bool ?? defaults.bool(forKey: Self.legacyShortcutsKey)
        DispatchQueue.global(qos: .utility).async {
            let names = enabled ? Self.shortcutNames() : []
            let commands = names.map {
                RemoteCommand(id: Self.shortcutPrefix + $0, name: $0, command: "Shortcut: \($0)")
            }
            let (changed, targets) = self.lock.withLock {
                let changed = commands != self.shortcutCommands
                self.shortcutCommands = commands
                return (changed, Array(self.connections.values))
            }
            guard changed else { return }
            MacMateLog("[RunCommandPlugin] Sharing \(commands.count) Shortcut(s)")
            for connection in targets { self.sendConfig(to: connection) }
        }
    }

    private static func shortcutNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        if packet.bool(for: "requestCommandList") {
            sendConfig(to: connection)
            return
        }

        if let key = packet.string(for: "key") {
            startCommand(key: key, connection: connection)
        } else if packet.bool(for: "stop") {
            stopAllProcesses()
        }
    }

    // MARK: - Command Management

    public func addCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
        lock.withLock {
            self.commands.append(command)
            self.saveCommands()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    public func removeCommand(id: String, connection: DeviceConnection? = nil) {
        lock.withLock {
            self.commands.removeAll(where: { $0.id == id })
            self.saveCommands()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    public func updateCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
        lock.withLock {
            if let index = self.commands.firstIndex(where: { $0.id == command.id }) {
                self.commands[index] = command
                self.saveCommands()
            }
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    private func loadCommands() {
        if let data = defaults.data(forKey: userDefaultsKey) ?? defaults.data(forKey: legacyUserDefaultsKey),
           let loaded = try? JSONDecoder().decode([RemoteCommand].self, from: data) {
            self.commands = loaded
        } else {
            self.commands = RemoteCommand.defaultCommands
            saveCommands()
        }
    }

    private func saveCommands() {
        if let data = try? JSONEncoder().encode(commands) {
            defaults.set(data, forKey: userDefaultsKey)
            defaults.set(data, forKey: legacyUserDefaultsKey)
        }
    }

    public func sendConfig(to connection: DeviceConnection) {
        var commandMap: [String: [String: String]] = [:]
        let shortcuts = lock.withLock { shortcutCommands }
        for cmd in commands + shortcuts {
            commandMap[cmd.id] = [
                "name": cmd.name,
                "command": cmd.command
            ]
        }

        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: commandMap, options: []),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "{}"
        }

        let packet = NetworkPacket(
            type: Self.runCommandType,
            body: [
                "commandList": AnyCodable(jsonString),
                "canAddCommand": AnyCodable(true)
            ]
        )
        connection.send(packet: packet)
        MacMateLog("[RunCommandPlugin] Sent commandList (\(commandMap.count) commands) to \(connection.peerDeviceInfo?.deviceName ?? "device")")
    }

    // MARK: - Process Execution

    public func startCommand(key: String, connection: DeviceConnection?) {
        let shortcuts = lock.withLock { shortcutCommands }
        guard let command = (commands + shortcuts).first(where: { $0.id == key }) else {
            MacMateLog("[RunCommandPlugin] Unknown command key: \(key)")
            return
        }

        let currentId: UInt32 = lock.withLock {
            self.executionCounter += 1
            return self.executionCounter
        }

        MacMateLog("[RunCommandPlugin] Starting command [\(currentId)]: \(command.name) ('\(command.command)')")

        if let conn = connection {
            let startPacket = NetworkPacket(
                type: Self.outputType,
                body: [
                    "commandStarted": AnyCodable(true),
                    "command": AnyCodable(command.command),
                    "id": AnyCodable(Int(currentId))
                ]
            )
            conn.send(packet: startPacket)
        }

        DispatchQueue.main.async {
            self.appendLog(commandId: command.id, line: "▶ Running: \(command.command)")
        }

        let process = Process()
        if command.id.hasPrefix(Self.shortcutPrefix) {
            // Run by name, never through the shell: a shortcut's name is text.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", String(command.id.dropFirst(Self.shortcutPrefix.count))]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command.command]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.withLock {
            self.activeProcesses[currentId] = process
        }

        // Pipe reads arrive in arbitrary chunks, so a line (or a multi-byte
        // character) can be split across two of them. Buffer until a newline.
        let stdoutLines = LineBuffer()
        let stderrLines = LineBuffer()

        func emit(_ lines: [String], isStderr: Bool, connection: DeviceConnection?) {
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                for line in lines {
                    self?.appendLog(commandId: command.id, line: isStderr ? "stderr: \(line)" : line)
                }
            }
            connection?.send(packet: NetworkPacket(
                type: Self.outputType,
                body: [
                    "commandOutput": AnyCodable(true),
                    "stdout": AnyCodable(isStderr ? [] as [String] : lines),
                    "stderr": AnyCodable(isStderr ? lines : [] as [String]),
                    "id": AnyCodable(Int(currentId))
                ]
            ))
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            emit(stdoutLines.append(data), isStderr: false, connection: connection)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            emit(stderrLines.append(data), isStderr: true, connection: connection)
        }

        process.terminationHandler = { [weak self, weak connection] proc in
            let exitCode = proc.terminationStatus
            let success = (exitCode == 0)

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // A last line with no trailing newline. The pipes are not drained:
            // a background child can hold them open and block this forever.
            emit(stdoutLines.flush(), isStderr: false, connection: connection)
            emit(stderrLines.flush(), isStderr: true, connection: connection)

            self?.lock.withLock {
                _ = self?.activeProcesses.removeValue(forKey: currentId)
            }

            DispatchQueue.main.async {
                self?.appendLog(commandId: command.id, line: "■ Finished with exit code \(exitCode)")
            }

            if let conn = connection {
                let finishPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandFinished": AnyCodable(true),
                        "success": AnyCodable(success),
                        "exitCode": AnyCodable(Int(exitCode)),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: finishPacket)
            }
            MacMateLog("[RunCommandPlugin] Command [\(currentId)] finished with exit code \(exitCode)")
        }

        do {
            try process.run()
        } catch {
            MacMateLog("[RunCommandPlugin] Failed to run process: \(error)")
            lock.withLock {
                _ = self.activeProcesses.removeValue(forKey: currentId)
            }
            if let conn = connection {
                let finishPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandFinished": AnyCodable(true),
                        "success": AnyCodable(false),
                        "exitCode": AnyCodable(-1),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: finishPacket)
            }
        }
    }

    public func stopAllProcesses() {
        lock.withLock {
            for (_, proc) in self.activeProcesses {
                proc.terminate()
            }
            self.activeProcesses.removeAll()
        }
    }

    private func appendLog(commandId: String, line: String) {
        var existing = commandLogs[commandId] ?? []
        existing.append(line)
        if existing.count > 100 {
            existing.removeFirst(existing.count - 100)
        }
        commandLogs[commandId] = existing
    }
}

/// Turns arbitrary chunks of process output into complete lines.
/// Used from one pipe's readability handler at a time.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    /// Adds `data` and returns every line it completed.
    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let text = String(decoding: line, as: UTF8.self)
                if !text.isEmpty { lines.append(text) }
            }
            return lines
        }
    }

    /// The last line, if the output didn't end with a newline.
    func flush() -> [String] {
        lock.withLock {
            defer { pending.removeAll() }
            let text = String(decoding: pending, as: UTF8.self)
            return text.isEmpty ? [] : [text]
        }
    }
}
