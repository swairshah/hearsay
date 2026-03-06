import Foundation
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "update")

/// Checks GitHub Releases for newer versions of the app.
final class UpdateChecker {
    
    /// GitHub API endpoint for the latest release
    private static let releasesURL = URL(string: "https://api.github.com/repos/swairshah/hearsay/releases/latest")!
    
    struct ReleaseInfo {
        let version: String      // e.g. "1.0.13"
        let tagName: String      // e.g. "v1.0.13"
        let htmlURL: URL         // Link to the release page
        let releaseNotes: String // Body/description
    }
    
    enum UpdateResult {
        case updateAvailable(ReleaseInfo)
        case upToDate(currentVersion: String)
        case error(String)
    }
    
    /// Check for updates against the GitHub latest release.
    static func check() async -> UpdateResult {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        logger.info("Checking for updates. Current version: \(currentVersion)")
        
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Hearsay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 404 means no releases yet
                if httpResponse.statusCode == 404 {
                    return .upToDate(currentVersion: currentVersion)
                }
                return .error("GitHub API returned status \(httpResponse.statusCode)")
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURLString = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString) else {
                return .error("Failed to parse release info")
            }
            
            let releaseNotes = json["body"] as? String ?? ""
            
            // Strip "v" prefix from tag to get version
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            
            logger.info("Latest release: \(remoteVersion) (current: \(currentVersion))")
            
            if isVersion(remoteVersion, newerThan: currentVersion) {
                let info = ReleaseInfo(
                    version: remoteVersion,
                    tagName: tagName,
                    htmlURL: htmlURL,
                    releaseNotes: releaseNotes
                )
                return .updateAvailable(info)
            } else {
                return .upToDate(currentVersion: currentVersion)
            }
            
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }
    
    /// Semantic version comparison. Returns true if `a` is newer than `b`.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false // equal
    }
}
