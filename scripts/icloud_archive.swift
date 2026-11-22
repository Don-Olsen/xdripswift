// Local maintenance helper; never included in the iOS/watchOS app.
// Uses public Foundation iCloud APIs. Eviction removes only the local download.
import Foundation
import Darwin

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
func errorInfo(_ error: Error) -> [String: Any] {
    let e = error as NSError
    return ["domain": e.domain, "code": e.code]
}
func status(_ url: URL) throws -> [String: Any] {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemDownloadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey]
    let v = try url.resourceValues(forKeys: keys)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    let dataless = (info.st_flags & 0x40000000) != 0
    var result: [String: Any] = [
        "isUbiquitous": v.isUbiquitousItem == true,
        "isUploaded": v.ubiquitousItemIsUploaded == true,
        "isUploading": v.ubiquitousItemIsUploading == true,
        "isDownloading": v.ubiquitousItemIsDownloading == true,
        "downloaded": v.ubiquitousItemDownloadingStatus == .current && !dataless,
        "dataless": dataless,
        "allocatedBytes": Int64(info.st_blocks) * 512,
        "downloadStatus": v.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown",
        "hasConflicts": v.ubiquitousItemHasUnresolvedConflicts == true]
    if let e = v.ubiquitousItemUploadingError ?? v.ubiquitousItemDownloadingError {
        result["error"] = errorInfo(e)
    }
    return result
}
let args = CommandLine.arguments
if args.count != 3 || !["status", "evict", "download"].contains(args[1]) {
    emit(["error": ["domain": "xDripArchiveUsage", "code": 1]])
    exit(2)
}
let url = URL(fileURLWithPath: args[2]).standardizedFileURL
let cloud = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/xDrip-arkiv").standardizedFileURL
// Never evict unrelated user files or project source.
if !url.path.hasPrefix(cloud.path + "/") ||
    cloud.resolvingSymlinksInPath().path != cloud.path ||
    url.resolvingSymlinksInPath().path != url.path {
    emit(["error": ["domain": "xDripArchivePath", "code": 1]])
    exit(2)
}
do {
    switch args[1] {
    case "evict":
        let s = try status(url)
        guard s["isUbiquitous"] as? Bool == true,
              s["isUploaded"] as? Bool == true,
              s["isUploading"] as? Bool == false,
              s["hasConflicts"] as? Bool == false,
              s["error"] == nil else {
            emit(["error": ["domain": "xDripArchiveNotUploaded", "code": 1]])
            exit(3)
        }
        try FileManager.default.evictUbiquitousItem(at: url)
    case "download":
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    default: break
    }
    emit(try status(url))
} catch {
    emit(["error": errorInfo(error)])
    exit(1)
}
