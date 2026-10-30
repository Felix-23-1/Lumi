// Sicherheitsregeln der Profi-Netzwerkwerkzeuge (Scan, Paket-Mitschnitt). Reine
// Prüfungen ohne Systemaufrufe: Ziele nur im eigenen Netz oder ausdrücklich
// eingetragene eigene Server; Mitschnitt-Filter nur aus einer harmlosen Teilmenge
// der tcpdump-Syntax, weil er als Argument an einen Administrator-Prozess geht.
import Foundation

public enum ScanTargets {
  public static let refusal = "Scannen nur im eigenen Netz oder gegen deine eingetragenen Server."
  public static let maxFilterLength = 200

  /// Wörter, die in einem Mitschnitt-Filter vorkommen dürfen.
  static let filterKeywords: Set<String> = [
    "host", "net", "port", "portrange", "src", "dst", "and", "or", "not", "tcp", "udp", "icmp", "arp",
    "ip", "ip6", "proto",
  ]
  /// Schlüsselwörter, nach denen ein Name/eine Adresse folgen darf.
  static let addressKeywords: Set<String> = ["host", "net", "port", "portrange", "src", "dst", "proto"]
  /// Operatoren, die als eigene Token stehen dürfen.
  static let filterOperators: Set<String> = ["&&", "||", "==", "(", ")"]
  /// Zeichen, die in einem Filter vorkommen dürfen (Leerraum wird separat geprüft).
  static let filterChars: Set<Character> =
    Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-/_()=&|")

  /// Erlaubt, wenn der Name (oder alle aufgelösten Adressen) privat sind, oder der Name einem
  /// vom Nutzer bestätigten eigenen Server entspricht. Mit mehreren aufgelösten Adressen müssen
  /// alle privat sein, sonst könnte ein öffentlicher Name über eine private Adresse durchrutschen.
  public static func isAllowed(host: String, ownServers: [OwnServer], resolvedIPs: [String]) -> Bool {
    let target = normalizedHost(host)
    guard !target.isEmpty else { return false }
    if ownServers.contains(where: { $0.authorized && normalizedHost($0.host) == target }) { return true }
    if NetworkAddress.isPrivate(target) { return true }
    let ips = resolvedIPs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return !ips.isEmpty && ips.allSatisfy { NetworkAddress.isPrivate($0) }
  }

  static func normalizedHost(_ host: String) -> String {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if h.hasSuffix(".") { h.removeLast() }
    return h
  }

  /// Leerer Filter (= alle Pakete) oder nur erlaubte Wörter, Adressen, Namen, Zahlen und Klammern.
  /// Verboten sind Shell-, Anführungs- und Umleitungszeichen sowie einzelnes `&`, `|` und `=`.
  public static func isValidTcpdumpFilter(_ filter: String) -> Bool {
    let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard f.count <= maxFilterLength else { return false }
    if f.isEmpty { return true }
    guard f.allSatisfy({ filterChars.contains($0) || $0.isWhitespace }) else { return false }

    var spaced = f
    for op in ["&&", "||", "==", "(", ")"] {
      spaced = spaced.replacingOccurrences(of: op, with: " \(op) ")
    }
    // Ein Name/eine IP ist nur erlaubt, wenn davor ein Adress-Schlüsselwort stand
    // (host, port, src …). So kommt „exec whoami“ nicht als zwei „Hostnamen“ durch.
    var expectArg = false
    for token in spaced.split(whereSeparator: \.isWhitespace).map(String.init) {
      let low = token.lowercased()
      if filterKeywords.contains(low) || filterOperators.contains(token) {
        expectArg = addressKeywords.contains(low)
        continue
      }
      guard isValueToken(token), expectArg else { return false }
      expectArg = false
    }
    return true
  }

  /// Port/Portbereich, IP (optional mit Präfix) oder Hostname – als Argument eines Schlüsselworts.
  static func isValueToken(_ token: String) -> Bool {
    let ranges = token.split(separator: "-", omittingEmptySubsequences: false)
    if (1...2).contains(ranges.count),
       ranges.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.allSatisfy(\.isNumber) }) {
      return true
    }
    let slash = token.split(separator: "/", omittingEmptySubsequences: false)
    if slash.count <= 2 {
      let address = String(slash[0])
      let prefixOK = slash.count == 1
        || (!slash[1].isEmpty && slash[1].count <= 3 && slash[1].allSatisfy(\.isNumber))
      if prefixOK && (NetworkAddress.isIPv4(address) || NetworkAddress.isIPv6(address)) { return true }
    }
    return NetworkAddress.isValidDNSName(token)
  }
}
