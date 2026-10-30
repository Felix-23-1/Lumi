// Netz-Stand für die Oberfläche: WLAN-Daten, lokale IP, Teilnetz, Router, DNS
// und Online-Zustand. Die Auswertung der Befehlsausgaben liegt in
// NetworkParsers; hier wird nur zusammengesetzt.
import Foundation

public final class WifiInfoProvider: Sendable {
  public static let ssidHint = "WLAN-Name nur mit Ortungsdiensten sichtbar"

  let system: NetworkSystem

  public init(system: NetworkSystem = SystemNetwork()) {
    self.system = system
  }

  /// Momentaufnahme. Blockiert nie länger als wenige Sekunden (Befehle haben eigene Zeitlimits).
  public func current() async -> NetworkInfo {
    async let routeOut = system.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
    async let dnsOut = system.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
    async let online = system.onlineOnce(timeout: 1)

    let route = NetworkParsers.defaultRoute(await routeOut.stdout)
    let dns = NetworkParsers.dnsServers(await dnsOut.stdout)
    let isOnline = await online

    let wifi = system.wifi()
    let addresses = system.localAddresses().filter { $0.ip != "127.0.0.1" }
    let primary = route.flatMap { r in addresses.first { $0.interface == r.interface } }
      ?? addresses.first { NetworkAddress.isPrivate($0.ip) }

    var subnet: String?
    if let p = primary, let mask = p.netmask {
      subnet = NetworkAddress.cidr(ip: p.ip, mask: mask)
    }

    let label: String
    if let w = wifi, route == nil || w.interfaceName == route?.interface {
      label = "WLAN"
    } else if route != nil {
      label = "Ethernet"
    } else {
      label = ""
    }

    let ssid = wifi?.ssid
    return NetworkInfo(
      ssid: ssid,
      ssidHint: (wifi != nil && ssid == nil) ? Self.ssidHint : nil,
      rssi: wifi?.rssi,
      noise: wifi?.noise,
      channel: wifi?.channel,
      band: wifi?.band,
      txRate: wifi?.txRate,
      interfaceName: label,
      localIP: primary?.ip,
      subnet: subnet,
      router: route?.gateway,
      dns: dns,
      online: isOnline)
  }
}
