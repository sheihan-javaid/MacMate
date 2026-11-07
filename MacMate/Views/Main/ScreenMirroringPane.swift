//
//  ScreenMirroringPane.swift
//  MacMate
//
//  Screen mirroring workspace and launcher with diagnostics for adb and scrcpy.
//  No mock simulation: checks real system tools, discovers adb devices,
//  and launches native high-framerate scrcpy screen mirroring.
//

import SwiftUI
import AppKit

public struct ScreenMirroringPane: View {
    let device: DeviceViewModel

    @State private var adbPath: String?
    @State private var scrcpyPath: String?
    @State private var adbDevicesOutput: String = ""
    @State private var isChecking = false
    @State private var isRunningScrcpy = false
    @State private var forwardAudio = true
    @State private var stayAwake = true
    @State private var turnScreenOff = false
    @State private var maxBitrate = 12
    @State private var statusMessage: String?
    @State private var copiedInstallCmd = false

    public init(device: DeviceViewModel) {
        self.device = device
    }

    private var allToolsAvailable: Bool {
        adbPath != nil && scrcpyPath != nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Mirroring")
                            .font(MMFont.hero)
                        Text("Low-latency Android display mirroring and remote control.")
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: { Task { await runDiagnostics() } }) {
                        Label("Check Status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !allToolsAvailable {
                    missingToolsCard
                } else {
                    toolsReadyWorkspace
                }

                guideCard
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .task {
            await runDiagnostics()
        }
    }

    // MARK: - Missing Tools Card

    private var missingToolsCard: some View {
        MMCard(radius: 16, showsGlow: true, glowColor: MMColor.statusWarning) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(MMColor.statusWarning.opacity(0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 20))
                            .foregroundStyle(MMColor.statusWarning)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Mirroring Engine Setup")
                            .font(MMFont.cardTitle)
                        Text("MacMate uses industry-standard, high-performance scrcpy for zero-latency screen mirroring.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Diagnostics checklist
                VStack(spacing: 8) {
                    diagnosticRow(
                        title: "Android Debug Bridge (adb)",
                        path: adbPath,
                        isFound: adbPath != nil
                    )
                    diagnosticRow(
                        title: "scrcpy Display Engine",
                        path: scrcpyPath,
                        isFound: scrcpyPath != nil
                    )
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Install via Homebrew:")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("brew install scrcpy android-platform-tools")
                            .font(MMFont.telemetry)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                            .foregroundStyle(.white)

                        Button(action: copyInstallCommand) {
                            Label(copiedInstallCmd ? "Copied!" : "Copy", systemImage: copiedInstallCmd ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MMColor.electricCyanEnd)
                    }
                }

                HStack {
                    Button("Re-check System") {
                        Task { await runDiagnostics() }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Link("scrcpy Documentation", destination: URL(string: "https://github.com/Genymobile/scrcpy")!)
                        .font(MMFont.caption)
                }
            }
            .padding(20)
        }
    }

    private func diagnosticRow(title: String, path: String?, isFound: Bool) -> some View {
        HStack {
            Image(systemName: isFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isFound ? MMColor.statusConnected : MMColor.statusError)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MMFont.bodyMedium)
                if let path {
                    Text(path)
                        .font(MMFont.telemetrySmall)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not installed or not in PATH")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Ready Workspace

    private var toolsReadyWorkspace: some View {
        VStack(spacing: 16) {
            MMCard(radius: 16, showsGlow: true, glowColor: MMColor.statusConnected) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        MMStatusPill(
                            title: "Engine Ready",
                            systemImage: "bolt.fill",
                            statusColor: MMColor.statusConnected,
                            showPulse: true
                        )

                        Spacer()

                        if isRunningScrcpy {
                            MMStatusPill(
                                title: "Mirroring Active",
                                systemImage: "display",
                                statusColor: MMColor.electricCyanStart,
                                showPulse: true
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mirror \(device.name)")
                            .font(MMFont.sectionHeader)
                        Text("Stream screen with keyboard, mouse, and clipboard passthrough.")
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }

                    // Toggles & Options
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Forward Audio to Mac", isOn: $forwardAudio)
                        Toggle("Keep Phone Awake while Mirroring", isOn: $stayAwake)
                        Toggle("Turn Phone Screen Off during Mirroring", isOn: $turnScreenOff)
                    }
                    .toggleStyle(.switch)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))

                    if let status = statusMessage {
                        Text(status)
                            .font(MMFont.caption)
                            .foregroundStyle(MMColor.statusWarning)
                    }

                    HStack(spacing: 12) {
                        Button(action: launchScreenMirroring) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Launch Screen Mirroring")
                                    .font(MMFont.bodyMedium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MMColor.electricCyanEnd)

                        if !adbDevicesOutput.isEmpty {
                            Button("Check ADB Devices") {
                                Task { await checkAdbDevices() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Guide Card

    private var guideCard: some View {
        MMCard(radius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Connecting via USB or Wi-Fi", systemImage: "info.circle")
                    .font(MMFont.cardTitle)

                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Enable **Developer Options** on your Android device (tap Build Number 7 times in Settings › About Phone).")
                    Text("2. Turn on **USB Debugging** (and optionally **Wireless Debugging**).")
                    Text("3. Connect your phone via USB cable and tap **Allow USB Debugging** on the phone prompt.")
                    Text("4. Once authorized, click **Launch Screen Mirroring** above.")
                }
                .font(MMFont.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    // MARK: - Diagnostics & Launch

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install scrcpy android-platform-tools", forType: .string)
        copiedInstallCmd = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedInstallCmd = false
        }
    }

    private func runDiagnostics() async {
        isChecking = true
        defer { isChecking = false }

        let adb = findTool(["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"], toolName: "adb")
        let scrcpy = findTool(["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy", "/usr/bin/scrcpy"], toolName: "scrcpy")

        self.adbPath = adb
        self.scrcpyPath = scrcpy

        if adb != nil {
            await checkAdbDevices()
        }
    }

    private func findTool(_ candidates: [String], toolName: String) -> String? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Check PATH
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [toolName]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty && fm.isExecutableFile(atPath: out) {
                return out
            }
        }
        return nil
    }

    private func checkAdbDevices() async {
        guard let adb = adbPath else { return }
        let output = await Task.detached(priority: .utility) { () -> String in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = ["devices", "-l"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value

        self.adbDevicesOutput = output
        if output.contains("unauthorized") {
            self.statusMessage = "Device detected but unauthorized. Check phone screen to allow USB debugging."
        } else if output.contains("device") {
            self.statusMessage = nil
        } else {
            self.statusMessage = "No ADB devices detected. Plug in USB or enable wireless debugging."
        }
    }

    private func launchScreenMirroring() {
        guard let scrcpy = scrcpyPath else { return }

        var args: [String] = [
            "--video-bit-rate", "\(maxBitrate)M"
        ]
        if stayAwake { args.append("--stay-awake") }
        if turnScreenOff { args.append("--turn-screen-off") }
        if !forwardAudio { args.append("--no-audio") }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scrcpy)
        proc.arguments = args

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                DispatchQueue.main.async { self.isRunningScrcpy = true }
                proc.waitUntilExit()
                DispatchQueue.main.async { self.isRunningScrcpy = false }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to launch scrcpy: \(error.localizedDescription)"
                    self.isRunningScrcpy = false
                }
            }
        }
    }
}

