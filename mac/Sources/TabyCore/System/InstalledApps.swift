// Liste der installierten Apps (für die Auswahl „Diese Apps ausblenden“).
// Liest nur die Info.plist der .app-Pakete; startet nichts.
import Foundation

public enum InstalledApps {
  private static let ownBundleId = "de.felix.taby"

  /// Apps aus /Applications, /System/Applications und ~/Applications (eine Ebene tief in Unterordnern),
  /// je Bundle-ID nur einmal, nach Name sortiert. Lumi selbst fehlt.
  public static func list() -> [AppInfo] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
    ]
    var seen = Set<String>()
    var result: [AppInfo] = []
    for root in roots {
      for url in appBundles(in: root) {
        // Symlinks auflösen: z. B. /Applications/Safari.app zeigt auf das Systemvolume.
        guard let bundle = Bundle(url: url.resolvingSymlinksInPath()), let id = bundle.bundleIdentifier, !id.isEmpty,
              id != ownBundleId, !seen.contains(id) else { continue }
        seen.insert(id)
        let name = displayName(of: bundle, fallback: url.deletingPathExtension().lastPathComponent)
        result.append(AppInfo(id: id, name: name))
      }
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func displayName(of bundle: Bundle, fallback: String) -> String {
    for key in ["CFBundleDisplayName", "CFBundleName"] {
      if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
        return value
      }
    }
    return fallback
  }

  /// .app-Pakete direkt in `root` und in dessen Unterordnern (eine Ebene).
  private static func appBundles(in root: URL) -> [URL] {
    var found: [URL] = []
    for entry in children(of: root) {
      if entry.pathExtension == "app" {
        found.append(entry)
      } else if isDirectory(entry) {
        found += children(of: entry).filter { $0.pathExtension == "app" }
      }
    }
    return found
  }

  private static func children(of dir: URL) -> [URL] {
    // Ohne .skipsHiddenFiles: Apps wie Safari.app tragen das macOS-Flag „hidden“ und fehlen sonst.
    let items = (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
    return items.sorted { $0.path < $1.path }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
  }
}
