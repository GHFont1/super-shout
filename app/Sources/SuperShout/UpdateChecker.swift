import AppKit

/// Lightweight self-updater: compares the running version against
/// version.json on the website and offers the download when newer.
/// Checked on launch, daily, and via the menu.
enum UpdateChecker {
    private static let feedURL = URL(string: "https://ghfont1.github.io/super-shout/version.json")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `verbose` also reports "you're up to date" (menu-triggered checks).
    static func check(verbose: Bool = false) {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = json["version"] as? String,
                  let urlString = json["url"] as? String,
                  let downloadURL = URL(string: urlString)
            else {
                if verbose { DispatchQueue.main.async { alertNoUpdateInfo() } }
                return
            }
            let notes = json["notes"] as? String ?? ""
            DispatchQueue.main.async {
                if isNewer(latest, than: currentVersion) {
                    offerUpdate(latest: latest, notes: notes, url: downloadURL)
                } else if verbose {
                    alertUpToDate()
                }
            }
        }.resume()
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offerUpdate(latest: String, notes: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Super Shout \(latest) is available"
        alert.informativeText = (notes.isEmpty ? "" : notes + "\n\n")
            + "You're on \(currentVersion). Download the update, then replace the app in Applications."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private static func alertUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Super Shout \(currentVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func alertNoUpdateInfo() {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "The update feed wasn't reachable. Try again later."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
