//  WiFiSSIDProvider.swift
//  MacMate
//
import CoreWLAN
import Foundation

/// Protocol for reading the Mac's current Wi-Fi network name (SSID).
/// Designed to be mocked in tests.
public protocol WiFiSSIDProvider: Sendable {
    func currentSSID() -> String?
}

/// Reads the SSID using CoreWLAN's CWWiFiClient.
public struct CoreWLANSSIDProvider: WiFiSSIDProvider {
    public init() {}
    public func currentSSID() -> String? {
        let client = CWWiFiClient.shared()
        if let ssid = client.interface()?.ssid(), !ssid.isEmpty {
            return ssid
        }
        if let interfaces = client.interfaces() {
            for iface in interfaces {
                if let ssid = iface.ssid(), !ssid.isEmpty {
                    return ssid
                }
            }
        }
        return nil
    }
}

/// Sanitises a raw SSID string. Returns nil for nil, empty, whitespace-only,
/// `"<unknown ssid>"`, `"0x"`, or a value that is only surrounding quotes.
public func sanitizeSsid(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count > 1 {
        s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if s.isEmpty || s.lowercased() == "<unknown ssid>" || s == "0x" {
        return nil
    }
    return s
}