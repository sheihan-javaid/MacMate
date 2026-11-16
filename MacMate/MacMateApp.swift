//
//  MacMateApp.swift
//  MacMate
//

import SwiftUI

@main
struct MacMateApp: App {
    @State private var appModel: MacMateAppModel

    init() {
        // Deterministic first-launch state: default settings and our own folders.
        FreshInstall.prepare()

        #if DEBUG
        // `-MacMateDemoData` fills the UI with sample devices for screenshots and
        // design work, without touching the network.
        // `-MacMateDemoRinging` also shows the Ring panel, without sound.
        // `-MacMateDemoCall` also shows the incoming-call card.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-MacMateDemoData") {
            _appModel = State(initialValue: .mock())
            PhoneFilesController.shared.showDemoDrive(for: "mock_phone")
            if args.contains("-MacMateDemoRinging") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MacRinger.shared.showDemoPanel(deviceName: "Pixel 9 Pro")
                }
            }
            if args.contains("-MacMateDemoCall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    CallCard.shared.showDemo()
                }
            }
            return
        }
        #endif

        _appModel = State(initialValue: .shared)

        // Unit tests run inside a copy of the app. Starting the services there
        // would connect to the phone next to the real MacMate and unmount its
        // phone drive as a "leftover".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Eagerly initialize identity on main thread
        _ = DeviceIdentity.shared
        // Start background discovery and network services
        MacMateService.shared.start()
        // Receive what's shared from the Share menu
        ShareInbox.shared.start()
        // Look for a newer release once a day
        UpdateController.shared.start()
        // Serve the phone's storage to Finder
        PhoneFilesController.shared.start()
    }

    /// Demo data opens the main window at `-MacMateDemoSection <section>`
    /// (overview when not given).
    private static var demoSection: DeviceSection? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-MacMateDemoData") else { return nil }
        return UserDefaults.standard.string(forKey: "MacMateDemoSection")
            .flatMap(DeviceSection.init) ?? .overview
        #else
        return nil
        #endif
    }

    var body: some Scene {
        MenuBarExtra("MacMate", image: appModel.statusMenuBarImageName) {
            MenuBarView(appModel: appModel)
                .macmateMotionPreference()
        }
        .menuBarExtraStyle(.window)

        Window("MacMate", id: "main") {
            MainWindowView(appModel: appModel, initialSection: Self.demoSection ?? .overview)
                .macmateMotionPreference()
        }
        .defaultSize(width: 1040, height: 700)
        .defaultLaunchBehavior(Self.demoSection == nil ? .automatic : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            MacMateCommands(appModel: appModel)
        }

        Settings {
            SettingsView(viewModel: .shared)
                .macmateMotionPreference()
        }
    }
}
