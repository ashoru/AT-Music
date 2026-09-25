import Foundation

// MARK: - 下载音质

/// 下载复用第三方音源音质枚举，但与播放音质使用不同的 UserDefaults key。
typealias DownloadQuality = ThirdPartyAudioQuality

extension ThirdPartyAudioQuality {
    static var low: Self { .kb128 }
    static var high: Self { .kb320 }
    static var lossless: Self { .flac }

    var label: String { displayName }

    var defaultFileExtension: String {
        switch self {
        case .kb128, .kb320: return "mp3"
        case .flac, .flac24bit, .hires, .atmos, .atmosPlus, .master: return "flac"
        }
    }
}

/// 下载结果（downgraded 表示目标音质不可用，已自动降级）
struct DownloadResult {
    let url: URL
    let requestedQuality: DownloadQuality
    let actualQuality: DownloadQuality
    let downgraded: Bool
    let sourceName: String?
}

struct ResolvedDownloadURL {
    let url: URL
    let actualQuality: DownloadQuality
    let sourceName: String?
}

// MARK: - 歌曲下载

/// 下载歌曲到临时目录（不自动保存到本地）：下载完成后交给播放页弹原生分享，由用户自行选择保存或转发
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private init() {}

    @discardableResult
    func download(song: Song, quality: DownloadQuality) async -> Result<DownloadResult, Error> {
        await downloadAudio(
            song: song,
            quality: quality,
            destinationDirectoryName: "ATMusicShare",
            uniqueFilename: false,
            logContext: "下载"
        )
    }

    /// 播放器的“下一首预缓存”使用同一套地址解析、请求头与音质降级逻辑，
    /// 但写入独立临时目录，随后由 MusicCacheManager 原子移入 Caches。
    func downloadForPlaybackCache(song: Song, quality: DownloadQuality) async -> Result<DownloadResult, Error> {
        await downloadAudio(
            song: song,
            quality: quality,
            destinationDirectoryName: "ATMusicPlaybackPrefetch",
            uniqueFilename: true,
            logContext: "预缓存"
        )
    }

    private func downloadAudio(
        song: Song,
        quality: DownloadQuality,
        destinationDirectoryName: String,
        uniqueFilename: Bool,
        logContext: String
    ) async -> Result<DownloadResult, Error> {
        let chain = quality.fallbackChain
        var lastError: Error = NetEaseError.unknown("\(logContext)失败")
        ATMusicLogger.shared.log(
            "\(logContext)开始：\(song.name) 平台=\(song.source.rawValue) 请求音质=\(quality.rawValue)",
            level: logContext == "预缓存" ? .debug : .info
        )

        for (index, current) in chain.enumerated() {
            if Task.isCancelled { return .failure(CancellationError()) }
            guard let resolved = await resolveURL(song: song, quality: current) else {
                lastError = NetEaseError.unknown("无法解析播放地址（可能为 VIP 歌曲或音源不可用）")
                continue
            }

            let tempURL: URL
            let response: URLResponse
            do {
                let request = downloadRequest(for: resolved.url, song: song)
                let (downloaded, downloadResponse) = try await URLSession.shared.download(for: request)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: downloaded)
                    return .failure(CancellationError())
                }
                response = downloadResponse
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = NetEaseError.unknown("\(logContext)失败（HTTP \(http.statusCode)）")
                    try? FileManager.default.removeItem(at: downloaded)
                    continue
                }
                guard isUsableAudioFile(at: downloaded, response: response) else {
                    lastError = NetEaseError.unknown("返回内容不是有效音频")
                    ATMusicLogger.shared.log(
                        "\(logContext)音频校验失败，继续尝试降级：\(song.name) 平台=\(song.source.rawValue) 音质=\(current.rawValue) MIME=\(response.mimeType ?? "未知")",
                        level: .debug
                    )
                    try? FileManager.default.removeItem(at: downloaded)
                    continue
                }
                tempURL = downloaded
            } catch is CancellationError {
                return .failure(CancellationError())
            } catch {
                lastError = NetEaseError.unknown("\(logContext)失败：\(error.localizedDescription)")
                continue
            }

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(destinationDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = "\(song.name) - \(song.artists)"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let actualQuality = resolved.actualQuality
            let ext = fileExtension(for: resolved.url, response: response, quality: actualQuality)
            let baseName = uniqueFilename ? "\(UUID().uuidString)-\(safeName)" : safeName
            let dest = dir.appendingPathComponent("\(baseName).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
            } catch {
                lastError = NetEaseError.unknown("保存失败：\(error.localizedDescription)")
                continue
            }

            let downgraded = index > 0 || actualQuality != quality
            ATMusicLogger.shared.log(
                "\(logContext)成功：\(song.name) 平台=\(song.source.rawValue) 请求音质=\(quality.rawValue) 实际音质=\(actualQuality.rawValue) 降级=\(downgraded ? "是" : "否") 地址=\(safeURLSummary(resolved.url))",
                level: logContext == "预缓存" ? .debug : .info
            )
            return .success(
                DownloadResult(
                    url: dest,
                    requestedQuality: quality,
                    actualQuality: actualQuality,
                    downgraded: downgraded,
                    sourceName: resolved.sourceName
                )
            )
        }
        ATMusicLogger.shared.log(
            "\(logContext)失败：\(song.name) 平台=\(song.source.rawValue) 请求音质=\(quality.rawValue) 所有候选质量均失败",
            level: logContext == "预缓存" ? .debug : .error
        )
        return .failure(lastError)
    }

    private func resolveURL(song: Song, quality: DownloadQuality) async -> ResolvedDownloadURL? {
        // NAS 必须只使用当前已验证作用域的 Audio Station 地址，不能走第三方同名歌曲兜底。
        if song.source == .synology {
            guard let urlString = SynologyAPI.shared.songURL(song: song),
                  let url = URL(string: urlString) else { return nil }
            return ResolvedDownloadURL(url: url, actualQuality: .flac, sourceName: "群晖 NAS")
        }
        // 下载优先复用已配置的第三方音源，避免播放能用第三方而下载仍走官方地址。
        let thirdPartyID = song.source == .netease ? song.id : 0
        let thirdPartyKugouID = song.kugouHash ?? song.kugouAlbumAudioId
        if let resolved = await UnblockService.resolve(
            name: song.name,
            artists: song.artists,
            neteaseID: thirdPartyID,
            songSource: song.source,
            qqMid: song.qqMid,
            qqMediaMid: song.qqMediaMid,
            kugouID: thirdPartyKugouID,
            quality: quality
        ) {
            ATMusicLogger.shared.log(
                "下载使用第三方音源：\(song.name) 来源=\(resolved.source) 请求音质=\(quality.rawValue) 实际音质=\(resolved.quality.rawValue)",
                level: .info
            )
            return ResolvedDownloadURL(
                url: resolved.url,
                actualQuality: resolved.quality,
                sourceName: resolved.source
            )
        }

        if song.source == .qq, let mid = song.qqMid {
            guard let result = try? await QQMusicAPI.shared.songURLResult(
                songmid: mid,
                mediaMid: song.qqMediaMid,
                quality: quality.atmusicQuality
            ),
            let url = URL(string: result.url) else { return nil }
            return ResolvedDownloadURL(
                url: url,
                actualQuality: Self.downloadQuality(forQQBR: result.br),
                sourceName: nil
            )
        } else if song.source == .kugou {
            guard let urlString = try? await KugouMusicAPI.shared.songURL(song: song, quality: quality.atmusicQuality),
                  let url = URL(string: urlString) else { return nil }
            return ResolvedDownloadURL(url: url, actualQuality: quality, sourceName: nil)
        } else {
            let urls = try? await NetEaseAPI.shared.songURLs(ids: [song.id], level: quality.neteaseLevel)
            guard let urlString = urls?[song.id], let url = URL(string: urlString) else { return nil }
            return ResolvedDownloadURL(url: url, actualQuality: quality, sourceName: nil)
        }
    }

    private func downloadRequest(for url: URL, song: Song) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0", forHTTPHeaderField: "User-Agent")

        if isQQHost(url.host) {
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            let cookie = QQMusicAuth.shared.cookieHeader
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        } else if url.host?.lowercased().contains("kugou") == true
                    || url.host?.lowercased().contains("kgimg.com") == true {
            request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
            let cookie = KugouMusicAuth.shared.cookieHeader
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        return request
    }

    private func isQQHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host.contains("qq.com")
            || host.contains("qqmusic")
            || host.contains("ptqqmusic")
            || host.contains("gitv.tv")
    }

    private static func downloadQuality(forQQBR br: String) -> DownloadQuality {
        switch br.uppercased() {
        case "M500": return .kb128
        case "M800": return .kb320
        case "C400": return .kb320
        case "F000": return .flac
        default: return .kb128
        }
    }

    private func fileExtension(for url: URL, response: URLResponse, quality: DownloadQuality) -> String {
        if let mimeType = response.mimeType?.lowercased() {
            if mimeType.contains("flac") { return "flac" }
            if mimeType.contains("mpeg") || mimeType.contains("mp3") { return "mp3" }
            if mimeType.contains("mp4") || mimeType.contains("m4a") { return "m4a" }
            if mimeType.contains("aac") { return "aac" }
            if mimeType.contains("ogg") { return "ogg" }
            if mimeType.contains("wav") { return "wav" }
        }

        let knownExtensions = Set(["mp3", "m4a", "flac", "aac", "ogg", "wav"])
        let urlExtension = url.pathExtension.lowercased()
        if knownExtensions.contains(urlExtension) {
            return urlExtension
        }
        if let suggestedFilename = response.suggestedFilename,
           let responseExtension = suggestedFilename.split(separator: ".").last.map({ String($0).lowercased() }),
           knownExtensions.contains(responseExtension) {
            return responseExtension
        }
        return quality.defaultFileExtension
    }

    /// 防止接口返回 HTTP 200 的 JSON/HTML 错误页被保存为歌曲，并阻断音质降级。
    private func isUsableAudioFile(at url: URL, response: URLResponse) -> Bool {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("text/") || mimeType.contains("json") || mimeType.contains("html") {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 1024 else {
            return false
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 64)) ?? Data()
        guard !prefix.isEmpty else { return false }
        let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return !text.hasPrefix("{")
            && !text.hasPrefix("[")
            && !text.hasPrefix("<html")
            && !text.hasPrefix("<!doctype")
    }

    private func safeURLSummary(_ url: URL) -> String {
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path
        let shortPath = path.count > 64 ? String(path.prefix(64)) + "..." : path
        return "\(host)\(shortPath)"
    }
}
