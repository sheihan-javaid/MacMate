//
//  SettingsViewModel.swift
//  MacMate
//
//  Native macOS SwiftUI @Observable view model for app settings and preferences.
//

import SwiftUI
import Combine
import Observation
import ServiceManagement
import UserNotifications
import ApplicationServices
import CoreLocation

@Observable
@MainActor
public final class SettingsViewModel {
    public static let shared = SettingsViewModel()

    public var deviceName: String = DeviceIdentity.shared.deviceName
    public var deviceId: String = DeviceIdentity.shared.deviceId
    public var certificateFingerprint: String = DeviceIdentity.shared.certificateFingerprint
    public var pairedDevices: [PairedDevice] = []
    public var launchAtLogin: Bool = false
    public var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    public var isAccessibilityTrusted: Bool = false
    public var tailscaleStatus: TailscaleStatus = .notInstalled
    public var isTailscaleDiscoveryEnabled: Bool = TailscaleDiscovery.isEnabled {
        didSet {
            guard !isMockMode, oldValue != isTailscaleDiscoveryEnabled else { return }
            UserDefaults.standard.set(isTailscaleDiscoveryEnabled, forKey: TailscaleDiscovery.enabledKey)
            MacMateService.shared.refreshTailscale()
        }
    }
    /// Whether this Mac shares its Wi-Fi network name with paired devices.
    public var shareWiFiSSID: Bool {
        get { UserDefaults.standard.bool(forKey: "macmate_share_wifi_ssid") }
        set {
            UserDefaults.standard.set(newValue, forKey: "macmate_share_wifi_ssid")
            MacMateService.shared.updateSSIDSharing(enabled: newValue)
        }
    }
    /// Whether this Mac pushes its desktop wallpaper to paired PocketLink devices.
    /// Opt-in and off by default; nothing is sent unless this is on.
    public var shareWallpaper: Bool {
        get { UserDefaults.standard.bool(forKey: "macmate_share_wallpaper") }
        set {
            UserDefaults.standard.set(newValue, forKey: "macmate_share_wallpaper")
            // MacMateService.shared.wallpaperSync.isEnabled reads this same key.
        }
    }
    /// Current Core Location authorization status.
    public var locationAuthStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var locationDelegate = LocationPermissionDelegate()
    @ObservationIgnored private var _locationManager: CLLocationManager?
    private var isMockMode: Bool = false

    private var locationManager: CLLocationManager {
        if _locationManager == nil {
            let mgr = CLLocationManager()
            mgr.delegate = locationDelegate
            locationDelegate.settingsViewModel = self
            _locationManager = mgr
        }
        return _locationManager!
    }

    public init(isMock: Bool = false) {
        self.isMockMode = isMock
        if !isMock {
            refresh()
            MacMateService.shared.$tailscaleStatus
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.tailscaleStatus = $0 }
                .store(in: &cancellables)
        }
    }

    public func refresh() {
        guard !isMockMode else { return }
        self.deviceName = DeviceIdentity.shared.deviceName
        self.deviceId = DeviceIdentity.shared.deviceId
        self.certificateFingerprint = DeviceIdentity.shared.certificateFingerprint
        reloadPairedDevices()
        self.isAccessibilityTrusted = AXIsProcessTrusted()
        self.checkLaunchAtLoginStatus()
        self.refreshNotificationStatus()
        _ = self.locationManager // ensure initialized with delegate
        if locationManager.authorizationStatus == .authorized {
            self.locationManager.startUpdatingLocation()
        }
    }

    public func saveDeviceName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.deviceName = trimmed
        DeviceIdentity.shared.deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "macmate_device_name")
        UserDefaults.standard.set(trimmed, forKey: "tether_device_name")
        MacMateService.shared.refreshAdvertisement()
    }

    public func unpair(deviceId: String) {
        MacMateService.shared.unpair(deviceId: deviceId)
        reloadPairedDevices()
    }

    public func setSync(deviceId: String, clipboard: Bool, notifications: Bool) {
        guard !isMockMode else { return }
        TrustStore.shared.updateSettings(deviceId: deviceId, clipboard: clipboard, notifications: notifications)
        reloadPairedDevices()
    }

    /// Port the TCP listener actually bound, which peers dial back on.
    public var listeningPort: Int { DeviceIdentity.shared.advertisedTCPPort }

    private func reloadPairedDevices() {
        self.pairedDevices = TrustStore.shared.pairedDevices.values
            .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    private func checkLaunchAtLoginStatus() {
        let service = SMAppService.mainApp
        self.launchAtLogin = (service.status == .enabled)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            self.launchAtLogin = (service.status == .enabled)
        } catch {
            MacMateLog("[SettingsViewModel] Failed to toggle launch at login: \(error)")
            self.launchAtLogin = (service.status == .enabled)
        }
    }

    public func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthStatus = settings.authorizationStatus
            }
        }
    }

    public func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshNotificationStatus()
            }
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    public func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Mocks for Previews

    #if DEBUG
    public static func mock() -> SettingsViewModel {
        let vm = SettingsViewModel(isMock: true)
        vm.deviceName = "MacBook Air"
        vm.deviceId = "b0ffaae46842413d997e1da63fcd6f93"
        vm.certificateFingerprint = "7F:1E:AA:32:89:01:BC:DE:45:67:89:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:01:23:45:67:89:AB:CD:EF"
        vm.pairedDevices = [
            PairedDevice(
                deviceId: "mock_phone",
                deviceName: "Pixel 9 Pro",
                deviceType: .phone,
                certificateFingerprint: "94:0A:06:43:72:98:77:70:3B:FC:E5:EC:B4:27:96:C9:F7:C3:6B:1C:50:E5:22:AB:88:00:B3:28:81:F6:D8:76",
                pairedDate: Date().addingTimeInterval(-86400 * 5)
            )
        ]
        vm.launchAtLogin = true
        vm.tailscaleStatus = .running(selfIP: "100.101.42.7", phones: [
            TailscalePeer(name: "Pixel 9 Pro", ip: "100.88.17.53", os: "android")
        ])
        vm.notificationAuthStatus = .authorized
        vm.isAccessibilityTrusted = true
        return vm
    }

    public static func mockDenied() -> SettingsViewModel {
        let vm = SettingsViewModel.mock()
        vm.notificationAuthStatus = .denied
        vm.isAccessibilityTrusted = false
        return vm
    }
    #endif
}

// MARK: - Location permission helper

/// Handles CLLocationManager delegate callbacks and reports authorization status
/// to the settings view model on the main actor.
@MainActor
public final class LocationPermissionDelegate: NSObject, CLLocationManagerDelegate {
    public weak var settingsViewModel: SettingsViewModel?

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorized {
            manager.startUpdatingLocation()
        }
        Task { @MainActor in
            guard let vm = settingsViewModel else { return }
            if status == .authorized {
                if !vm.shareWiFiSSID {
                    vm.shareWiFiSSID = true
                } else {
                    MacMateService.shared.updateSSIDSharing(enabled: true)
                }
            }
        }
    }
}
