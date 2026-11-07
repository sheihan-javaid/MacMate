//
//  MacMateSection.swift
//  MacMate
//
//  10-section navigation enum mapping directly to real engine capabilities.
//

import SwiftUI

public enum MacMateSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case messages
    case notifications
    case photos
    case files
    case screenMirroring
    case calls
    case clipboard
    case device
    case settings
    case commands // Legacy compatibility alias, folded into device

    public var id: Self { self }

    public static var primarySections: [MacMateSection] {
        [
            .overview,
            .messages,
            .notifications,
            .photos,
            .files,
            .screenMirroring,
            .calls,
            .clipboard,
            .device,
            .settings
        ]
    }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .messages: return "Messages"
        case .notifications: return "Notifications"
        case .photos: return "Photos"
        case .files: return "Files"
        case .screenMirroring: return "Screen Mirroring"
        case .calls: return "Calls"
        case .clipboard: return "Clipboard"
        case .device, .commands: return "Device"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: return "macbook.and.iphone"
        case .messages: return "message.fill"
        case .notifications: return "bell.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .files: return "folder.fill"
        case .screenMirroring: return "display"
        case .calls: return "phone.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .device, .commands: return "cpu"
        case .settings: return "gearshape.fill"
        }
    }
}

public typealias DeviceSection = MacMateSection

