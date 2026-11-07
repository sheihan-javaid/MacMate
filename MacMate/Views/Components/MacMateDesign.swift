//
//  MacMateDesign.swift
//  MacMate
//
//  Design system tokens, typography, surfaces, and reusable components
//  combining 70% Apple refinement, 20% Samsung One UI clarity, and
//  10% restrained futuristic luminous accents.
//

import SwiftUI
import AppKit

// MARK: - Color Tokens

public enum MMColor {
    // Semantic Surfaces
    public static var surfaceBase: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    public static var surfaceCard: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    public static var surfaceSecondary: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    // Futuristic Luminous Accents & Gradients
    public static let electricCyanStart = Color(red: 0.0, green: 0.824, blue: 1.0)     // #00D2FF
    public static let electricCyanEnd   = Color(red: 0.0, green: 0.478, blue: 1.0)     // #007AFF

    public static let luminousVioletStart = Color(red: 0.475, green: 0.157, blue: 0.792) // #7928CA
    public static let luminousVioletEnd   = Color(red: 0.722, green: 0.0, blue: 1.0)     // #B800FF

    public static var accentPrimaryGradient: LinearGradient {
        LinearGradient(
            colors: [electricCyanStart, electricCyanEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var accentSecondaryGradient: LinearGradient {
        LinearGradient(
            colors: [luminousVioletStart, luminousVioletEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var subtleCyanTint: Color {
        electricCyanStart.opacity(0.12)
    }

    // Status Colors
    public static let statusConnected = Color(red: 0.188, green: 0.820, blue: 0.345) // Vivid emerald #30D158
    public static let statusWarning   = Color(red: 1.0, green: 0.624, blue: 0.039)   // Amber #FF9F0A
    public static let statusError     = Color(red: 1.0, green: 0.271, blue: 0.227)   // Coral Red #FF453A
    public static let statusNeutral   = Color.secondary
}

// MARK: - Typography Hierarchy

public enum MMFont {
    public static let hero = Font.system(size: 26, weight: .bold, design: .rounded)
    public static let sectionHeader = Font.system(size: 18, weight: .semibold, design: .rounded)
    public static let cardTitle = Font.system(size: 14, weight: .semibold, design: .rounded)
    public static let cardSubtitle = Font.system(size: 12, weight: .regular)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 11, weight: .medium)
    public static let telemetry = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let telemetrySmall = Font.system(size: 10, weight: .medium, design: .monospaced)
}

// MARK: - Appearance Management

public enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum MMAppearanceManager {
    public static let key = "macmate_appearance_preference"

    public static func currentScheme(from rawValue: String) -> ColorScheme? {
        AppAppearance(rawValue: rawValue)?.colorScheme
    }
}

// MARK: - Glass Surface & Cards

public struct MMCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 16
    var isInteractive: Bool = false
    var showsGlow: Bool = false
    var glowColor: Color = MMColor.electricCyanStart
    @ViewBuilder var content: Content

    public init(
        radius: CGFloat = 16,
        isInteractive: Bool = false,
        showsGlow: Bool = false,
        glowColor: Color = MMColor.electricCyanStart,
        @ViewBuilder content: () -> Content
    ) {
        self.radius = radius
        self.isInteractive = isInteractive
        self.showsGlow = showsGlow
        self.glowColor = glowColor
        self.content = content()
    }

    public var body: some View {
        content
            .background {
                cardBackground
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        showsGlow ? glowColor.opacity(0.35) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: showsGlow ? glowColor.opacity(0.12) : Color.black.opacity(0.04),
                radius: showsGlow ? 12 : 6,
                x: 0,
                y: showsGlow ? 3 : 2
            )
    }

    @ViewBuilder
    private var cardBackground: some View {
        if reduceTransparency {
            MMColor.surfaceCard
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}

// MARK: - Status Pill

public struct MMStatusPill: View {
    let title: String
    let systemImage: String
    var statusColor: Color = MMColor.statusConnected
    var showPulse: Bool = false

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        systemImage: String,
        statusColor: Color = MMColor.statusConnected,
        showPulse: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.statusColor = statusColor
        self.showPulse = showPulse
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showPulse && !reduceMotion {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .scaleEffect(isPulsing ? 1.6 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.6)
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)

            Text(title)
                .font(MMFont.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule()
                .strokeBorder(statusColor.opacity(0.25), lineWidth: 0.8)
        }
        .onAppear {
            if showPulse && !reduceMotion {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
        }
    }
}

// MARK: - Icon Tile

public struct MMIconTile: View {
    let systemImage: String
    var size: CGFloat = 40
    var iconSize: CGFloat = 18
    var gradient: LinearGradient = MMColor.accentPrimaryGradient

    public init(
        systemImage: String,
        size: CGFloat = 40,
        iconSize: CGFloat = 18,
        gradient: LinearGradient = MMColor.accentPrimaryGradient
    ) {
        self.systemImage = systemImage
        self.size = size
        self.iconSize = iconSize
        self.gradient = gradient
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Device Telemetry Chip

public struct MMDeviceTelemetryChip: View {
    let deviceName: String
    let isConnected: Bool
    let batteryPercent: Int?
    let isCharging: Bool
    let linkType: String?

    public init(
        deviceName: String,
        isConnected: Bool,
        batteryPercent: Int?,
        isCharging: Bool = false,
        linkType: String? = nil
    ) {
        self.deviceName = deviceName
        self.isConnected = isConnected
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.linkType = linkType
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? MMColor.statusConnected : MMColor.statusNeutral)
                .frame(width: 7, height: 7)

            Text(deviceName)
                .font(MMFont.bodyMedium)
                .lineLimit(1)

            if isConnected, let battery = batteryPercent {
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol(for: battery, charging: isCharging))
                        .foregroundStyle(battery <= 15 && !isCharging ? MMColor.statusError : .secondary)
                    Text("\(battery)%")
                        .font(MMFont.telemetrySmall)
                }
                .foregroundStyle(.secondary)
            }

            if let link = linkType, !link.isEmpty {
                Text(link)
                    .font(MMFont.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func batterySymbol(for percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Section Availability & Gate

public enum SectionAvailabilityState: Equatable {
    case ready
    case noDevice
    case storageNotMounted(canMount: Bool)
    case toolMissing(tool: String, instruction: String)
    case phoneActionNeeded(message: String)
    case macPermissionDenied(message: String)
}

public struct MMSectionGate<Content: View>: View {
    let state: SectionAvailabilityState
    let sectionTitle: String
    let systemImage: String
    var onPrimaryAction: (() -> Void)? = nil
    var primaryActionTitle: String? = nil
    @ViewBuilder var content: Content

    public init(
        state: SectionAvailabilityState,
        sectionTitle: String,
        systemImage: String,
        primaryActionTitle: String? = nil,
        onPrimaryAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.sectionTitle = sectionTitle
        self.systemImage = systemImage
        self.primaryActionTitle = primaryActionTitle
        self.onPrimaryAction = onPrimaryAction
        self.content = content()
    }

    public var body: some View {
        switch state {
        case .ready:
            content
        case .noDevice:
            unavailableView(
                title: "No Device Connected",
                subtitle: "Connect or select an Android device to access \(sectionTitle).",
                icon: "iphone.slash",
                actionTitle: nil,
                action: nil
            )
        case .storageNotMounted:
            unavailableView(
                title: "Phone Storage Not Mounted",
                subtitle: "Mount your phone storage via SFTP or ADB to browse \(sectionTitle.lowercased()) directly on your Mac.",
                icon: "internaldrive",
                actionTitle: primaryActionTitle ?? "Mount Storage",
                action: onPrimaryAction
            )
        case .toolMissing(let tool, let instruction):
            unavailableView(
                title: "\(tool) Not Found",
                subtitle: instruction,
                icon: "wrench.and.screwdriver",
                actionTitle: primaryActionTitle,
                action: onPrimaryAction
            )
        case .phoneActionNeeded(let message):
            unavailableView(
                title: "Action Needed on Android",
                subtitle: message,
                icon: "hand.tap",
                actionTitle: primaryActionTitle,
                action: onPrimaryAction
            )
        case .macPermissionDenied(let message):
            unavailableView(
                title: "Permission Required",
                subtitle: message,
                icon: "lock.shield",
                actionTitle: primaryActionTitle ?? "Open System Settings",
                action: onPrimaryAction
            )
        }
    }

    private func unavailableView(
        title: String,
        subtitle: String,
        icon: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(MMColor.subtleCyanTint)
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(MMColor.electricCyanEnd)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(MMFont.sectionHeader)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(MMFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(MMFont.bodyMedium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(MMColor.electricCyanEnd)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Copy Code Button

/// Copies a verification code and provides transient feedback.
public struct CopyCodeButton: View {
    let code: String
    @State private var copied = false

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        Button {
            NotificationPlugin.copyToPasteboard(code)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : "Copy Code \(code)")
                .font(MMFont.telemetry)
        }
        .accessibilityLabel(copied ? "Copied" : "Copy code \(code.map(String.init).joined(separator: " "))")
    }
}
