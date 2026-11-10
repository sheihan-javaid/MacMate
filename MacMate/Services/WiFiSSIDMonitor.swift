//
//  WiFiSSIDMonitor.swift
//  MacMate
//

import CoreWLAN
import Foundation

/// Delegate for Wi-Fi SSID change events.
public protocol WiFiSSIDMonitorDelegate: AnyObject {
    func ssidDidChange()
}

/// Monitors CoreWLAN SSID change events and notifies a delegate.
///
/// Must be created and used on the main thread, as CoreWLAN requires it.
public final class WiFiSSIDMonitor: NSObject, CWEventDelegate {

    public weak var delegate: WiFiSSIDMonitorDelegate?
    private let wifiClient = CWWiFiClient.shared()

    public override init() {
        super.init()
        wifiClient.delegate = self
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
    }

    public func ssidDidChangeForWiFiInterfaceWithName(interfaceName: String!) {
        delegate?.ssidDidChange()
    }
}
