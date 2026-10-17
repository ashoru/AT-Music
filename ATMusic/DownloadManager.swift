import Foundation
import Combine
import UIKit

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

// MARK: - 任务状态模型

enum TransferDownloadStatus: Equatable {
    case waiting
    case resolving
    case downloading
    case finishing
    case completed
    case paused
    case failed(String)
}

enum TransferUploadStatus: Equatable {
    case waiting
    case uploadingAudio
    case uploadingSupportFiles
    case syncingTags
    case completed
    case paused
    case failed(String)
}

final class DownloadTaskItem: Identifiable, ObservableObject {
    let id: UUID
    let song: Song
    let requestedQuality: DownloadQuality
    @Published var actualQuality: DownloadQuality?
    @Published var status: TransferDownloadStatus = .waiting
    @Published var progress: Double = 0.0
    @Published var speedBytesPerSecond: Double = 0.0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var errorMessage: String?
    @Published var localRelativePath: String?
    let createdAt: Date

    var lastBytesWritten: Int64 = 0
    var lastSpeedUpdate: Date = Date()
    var sessionTask: URLSessionDownloadTask?
    var resumeData: Data?

    init(id: UUID = UUID(), song: Song, requestedQuality: DownloadQuality) {
        self.id = id
        self.song = song
        self.requestedQuality = requestedQuality
        self.createdAt = Date()
    }

    var formattedSpeed: String {
        if speedBytesPerSecond > 1024 * 1024 {
            return String(format: "%.1f MB/s", speedBytesPerSecond / (1024 * 1024))
        } else if speedBytesPerSecond > 0 {
            return String(format: "%.0f KB/s", speedBytesPerSecond / 1024)
        }
        return "-- KB/s"
    }

    var formattedProgress: String {
        let downloadedStr = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(downloadedStr) / \(totalStr)"
        }
        return downloadedStr
    }

    var statusDescription: String {
        switch status {
        case .waiting: return "排队等待中"
        case .resolving: return "正在解析音质直链..."
        case .downloading: return "正在下载 \(Int(progress * 100))%"
        case .finishing: return "正在写入本地曲库..."
        case .completed: return "已离线完成"
        case .paused: return "已暂停"
        case .failed(let err): return "下载失败: \(err)"
        }
    }
}

final class UploadTaskItem: Identifiable, ObservableObject {
    let id: UUID
    let song: Song
    let destinationFolder: String
    @Published var status: TransferUploadStatus = .waiting
    @Published var progress: Double = 0.0
    @Published var speedBytesPerSecond: Double = 0.0
    @Published var uploadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var errorMessage: String?
    let createdAt: Date
    var isCancelled: Bool = false

    init(id: UUID = UUID(), song: Song, destinationFolder: String) {
        self.id = id
        self.song = song
        self.destinationFolder = destinationFolder
        self.createdAt = Date()
    }

    var formattedSpeed: String {
        if speedBytesPerSecond > 1024 * 1024 {
            return String(format: "%.1f MB/s", speedBytesPerSecond / (1024 * 1024))
        } else if speedBytesPerSecond > 0 {
            return String(format: "%.0f KB/s", speedBytesPerSecond / 1024)
        }
        return "-- KB/s"
    }

    var formattedProgress: String {
        let uploadedStr = ByteCountFormatter.string(fromByteCount: uploadedBytes, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(uploadedStr) / \(totalStr)"
        }
        return uploadedStr
    }

    var statusDescription: String {
        switch status {
        case .waiting: return "等待上传至 NAS..."
        case .uploadingAudio: return "正在上传音频 \(Int(progress * 100))%"
        case .uploadingSupportFiles: return "正在同步歌词与封面..."
        case .syncingTags: return "正在写入 NAS 媒体标签..."
        case .completed: return "已成功归档到群晖 NAS"
        case .paused: return "已暂停"
        case .failed(let err): return "上传失败: \(err)"
        }
    }
}

// MARK: - 会话代理协调器

final class DownloadSessionCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let taskID = downloadTask.taskDescription, let uuid = UUID(uuidString: taskID) else { return }
        Task { @MainActor [weak self] in
            self?.manager?.handleDownloadProgress(id: uuid, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskID = downloadTask.taskDescription, let uuid = UUID(uuidString: taskID) else { return }
        let ext = AudioFormatDetector.detectExtension(fileURL: location, fallback: "mp3")
        let tempStaging = FileManager.default.temporaryDirectory.appendingPathComponent("stage_\(UUID().uuidString).\(ext)")
        try? FileManager.default.copyItem(at: location, to: tempStaging)
        let response = downloadTask.response
        Task { @MainActor [weak self] in
            self?.manager?.handleDownloadFinished(id: uuid, stagingURL: tempStaging, response: response, detectedExtension: ext)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskID = task.taskDescription, let uuid = UUID(uuidString: taskID) else { return }
        Task { @MainActor [weak self] in
            self?.manager?.handleDownloadError(id: uuid, error: error)
        }
    }
}

// MARK: - 传输与下载管理器核心

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadTaskItem] = []
    @Published var activeUploads: [UploadTaskItem] = []
    @Published var isPaused: Bool = false

    private let maxConcurrentDownloads = 3
    private let maxConcurrentUploads = 1
    private let sessionDelegate = DownloadSessionCoordinator()
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: OperationQueue.main)
    }()

    private init() {
        sessionDelegate.manager = self
    }

    // MARK: - 计算属性与看板数据

    var downloadedSongs: [Song] {
        LocalLibraryStore.shared.importedSongs
    }

    var formattedDownloadedSize: String {
        let docs = ManagedAudioPath.documents.appendingPathComponent("ATMusicAudio", isDirectory: true)
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: docs.path) else { return "0 MB" }
        var total: Int64 = 0
        for file in files {
            let fullPath = docs.appendingPathComponent(file).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var totalDownloadSpeed: Double {
        activeDownloads
            .filter { $0.status == .downloading }
            .reduce(0.0) { $0 + $1.speedBytesPerSecond }
    }

    var formattedDownloadSpeed: String {
        let speed = totalDownloadSpeed
        if speed > 1024 * 1024 {
            return String(format: "%.1f MB/s", speed / (1024 * 1024))
        } else if speed > 0 {
            return String(format: "%.0f KB/s", speed / 1024)
        }
        return "0 KB/s"
    }

    var transferCardSubtitle: String {
        let pendingDownloads = activeDownloads.filter { $0.status != .completed }
        let pendingUploads = activeUploads.filter { $0.status != .completed }
        if !pendingDownloads.isEmpty || !pendingUploads.isEmpty {
            var parts: [String] = []
            if !pendingDownloads.isEmpty {
                parts.append("↓ \(pendingDownloads.count) 首")
            }
            if !pendingUploads.isEmpty {
                parts.append("↑ \(pendingUploads.count) 首")
            }
            return parts.joined(separator: " · ")
        }
        return "已离线 \(downloadedSongs.count) 首"
    }

    // MARK: - 状态感知查询

    nonisolated func isDownloaded(song: Song) -> Bool {
        localAudioURL(for: song) != nil
    }

    func isDownloading(song: Song) -> Bool {
        activeDownloads.contains {
            $0.song.identityKey == song.identityKey &&
            ($0.status == .waiting || $0.status == .resolving || $0.status == .downloading || $0.status == .finishing)
        }
    }

    nonisolated func localAudioURL(for song: Song) -> URL? {
        if song.source == .local, let relativePath = song.localRelativePath {
            if let url = try? ManagedAudioPath.resolve(relativePath), FileManager.default.fileExists(atPath: url.path) {
                if relativePath.hasSuffix(".tmp") {
                    let base = (relativePath as NSString).deletingPathExtension
                    for candidateExt in ["flac", "mp3", "m4a", "wav", "ogg"] {
                        let candidateRel = base + "." + candidateExt
                        if let candURL = try? ManagedAudioPath.resolve(candidateRel), FileManager.default.fileExists(atPath: candURL.path) {
                            return candURL
                        }
                    }
                }
                return url
            }
            if relativePath.hasSuffix(".tmp") {
                let base = (relativePath as NSString).deletingPathExtension
                for candidateExt in ["flac", "mp3", "m4a", "wav", "ogg"] {
                    let candidateRel = base + "." + candidateExt
                    if let candURL = try? ManagedAudioPath.resolve(candidateRel), FileManager.default.fileExists(atPath: candURL.path) {
                        return candURL
                    }
                }
            }
        }
        if let file = LocalAudioFileManager.shared.file(forSongId: song.identityKey),
           let url = try? LocalAudioFileManager.shared.url(for: file),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let localSong = LocalLibraryStore.shared.importedSongs.first(where: {
            $0.name.lowercased() == song.name.lowercased() &&
            $0.artists.lowercased() == song.artists.lowercased() &&
            $0.localRelativePath != nil
        }), let path = localSong.localRelativePath {
            if let url = try? ManagedAudioPath.resolve(path), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            if path.hasSuffix(".tmp") {
                let base = (path as NSString).deletingPathExtension
                for candidateExt in ["flac", "mp3", "m4a", "wav", "ogg"] {
                    let candidateRel = base + "." + candidateExt
                    if let candURL = try? ManagedAudioPath.resolve(candidateRel), FileManager.default.fileExists(atPath: candURL.path) {
                        return candURL
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 一键离线下载调度

    func startDownload(song: Song, quality: DownloadQuality? = nil) {
        if isDownloaded(song: song) {
            ToastCenter.shared.show("《\(song.name)》已在本地离线库中")
            return
        }
        if isDownloading(song: song) {
            ToastCenter.shared.show("《\(song.name)》已在下载队列中")
            return
        }

        let targetQuality: DownloadQuality
        if let quality {
            targetQuality = quality
        } else {
            let saved = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey)
            targetQuality = saved.flatMap { DownloadQuality(sourceValue: $0) } ?? ThirdPartyAudioQuality.current
        }

        let item = DownloadTaskItem(song: song, requestedQuality: targetQuality)
        activeDownloads.insert(item, at: 0)
        ATMusicHaptics.medium()
        ToastCenter.shared.show("已加入下载队列：\(song.name)")
        scheduleDownloadQueue()
    }

    func startBatchDownload(songs: [Song], quality: DownloadQuality? = nil) {
        let missing = songs.filter { !isDownloaded(song: $0) && !isDownloading(song: $0) }
        guard !missing.isEmpty else {
            ToastCenter.shared.show("选中的歌曲均已在本地离线库中")
            return
        }

        let targetQuality: DownloadQuality
        if let quality {
            targetQuality = quality
        } else {
            let saved = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey)
            targetQuality = saved.flatMap { DownloadQuality(sourceValue: $0) } ?? ThirdPartyAudioQuality.current
        }

        for song in missing {
            let item = DownloadTaskItem(song: song, requestedQuality: targetQuality)
            activeDownloads.append(item)
        }
        ATMusicHaptics.medium()
        ToastCenter.shared.show("已将 \(missing.count) 首歌曲加入离线下载队列")
        scheduleDownloadQueue()
    }

    private func scheduleDownloadQueue() {
        guard !isPaused else { return }
        let runningCount = activeDownloads.filter { $0.status == .downloading || $0.status == .resolving || $0.status == .finishing }.count
        guard runningCount < maxConcurrentDownloads else { return }

        let availableSlots = maxConcurrentDownloads - runningCount
        let waitingTasks = activeDownloads.filter { $0.status == .waiting }.prefix(availableSlots)

        for task in waitingTasks {
            executeDownloadTask(task)
        }
    }

    private func executeDownloadTask(_ task: DownloadTaskItem) {
        task.status = .resolving
        Task {
            guard let resolved = await resolveURL(song: task.song, quality: task.requestedQuality) else {
                task.status = .failed("无法解析音频地址（VIP限制或音源无版权）")
                scheduleDownloadQueue()
                return
            }

            task.actualQuality = resolved.actualQuality
            task.status = .downloading
            task.lastSpeedUpdate = Date()
            task.lastBytesWritten = 0

            let req = downloadRequest(for: resolved.url, song: task.song)
            let sessionTask: URLSessionDownloadTask
            if let resumeData = task.resumeData {
                sessionTask = downloadSession.downloadTask(withResumeData: resumeData)
                task.resumeData = nil
            } else {
                sessionTask = downloadSession.downloadTask(with: req)
            }
            sessionTask.taskDescription = task.id.uuidString
            task.sessionTask = sessionTask
            sessionTask.resume()
        }
    }

    // MARK: - 会话代理回调响应

    func handleDownloadProgress(id: UUID, written: Int64, total: Int64) {
        guard let task = activeDownloads.first(where: { $0.id == id }) else { return }
        task.downloadedBytes = written
        task.totalBytes = total
        if total > 0 {
            task.progress = min(1.0, max(0.0, Double(written) / Double(total)))
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(task.lastSpeedUpdate)
        if elapsed >= 0.5 {
            let delta = written - task.lastBytesWritten
            if delta >= 0 {
                let instantSpeed = Double(delta) / elapsed
                // EMA 平滑滤波
                task.speedBytesPerSecond = task.speedBytesPerSecond == 0 ? instantSpeed : (task.speedBytesPerSecond * 0.7 + instantSpeed * 0.3)
            }
            task.lastBytesWritten = written
            task.lastSpeedUpdate = now
        }
    }

    func handleDownloadFinished(id: UUID, stagingURL: URL, response: URLResponse?, detectedExtension: String? = nil) {
        guard let task = activeDownloads.first(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }

        task.status = .finishing
        let song = task.song

        Task {
            defer { try? FileManager.default.removeItem(at: stagingURL) }

            guard let response = response, isUsableAudioFile(at: stagingURL, response: response, song: song) else {
                task.status = .failed("返回内容不是有效音频（可能触发防盗链）")
                scheduleDownloadQueue()
                return
            }

            let safeName = "\(song.name) - \(song.artists)"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")

            do {
                let record = try LocalAudioFileManager.shared.registerFile(
                    sourceTempURL: stagingURL,
                    songId: song.identityKey,
                    originalFilename: safeName,
                    kind: .userDownloaded,
                    explicitExtension: detectedExtension
                )
                task.localRelativePath = record.relativePath

                // 并行异步保存歌词文件
                if let rawLyrics = await SongLyricsLoader.rawLyricString(for: song),
                   let lrcData = rawLyrics.data(using: .utf8), !lrcData.isEmpty {
                    let localLRCPath = (record.relativePath as NSString).deletingPathExtension + ".lrc"
                    _ = try? LocalAudioFileManager.shared.writeSupportData(lrcData, relativePath: localLRCPath)
                }

                // 并行异步持久化封面
                var localCoverURL: URL? = nil
                if let coverURL = song.coverURL,
                   let (coverData, _) = try? await URLSession.shared.data(from: coverURL), !coverData.isEmpty {
                    let localCoverPath = "ATMusicAudio/Artwork/\(record.id).jpg"
                    localCoverURL = try? LocalAudioFileManager.shared.writeSupportData(coverData, relativePath: localCoverPath)
                }

                let localSong = Song(
                    id: song.id,
                    name: song.name,
                    artists: song.artists,
                    album: song.album,
                    coverURL: localCoverURL ?? song.coverURL,
                    duration: song.duration,
                    source: .local,
                    localRelativePath: record.relativePath,
                    albumArtist: song.albumArtist,
                    genre: song.genre,
                    year: song.year,
                    comment: song.comment,
                    discNumber: song.discNumber,
                    trackNumber: song.trackNumber
                )

                LocalLibraryStore.shared.addImportedSongs([localSong])
                _ = LocalLibraryStore.shared.addSongToNamedPlaylist(localSong, name: "已下载歌曲")

                task.progress = 1.0
                task.status = .completed
                ATMusicHaptics.success()
                ToastCenter.shared.show("《\(song.name)》已离线入库")
                ATMusicLogger.shared.log("✅ 离线下载成功：\(song.name) -> \(record.relativePath)", level: .info)
            } catch {
                task.status = .failed("本地入库失败：\(error.localizedDescription)")
            }

            scheduleDownloadQueue()
        }
    }

    func handleDownloadError(id: UUID, error: Error?) {
        guard let task = activeDownloads.first(where: { $0.id == id }) else { return }
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                // 用户主动暂停或取消，状态已在暂停方法设置
                return
            }
            task.status = .failed(error.localizedDescription)
            scheduleDownloadQueue()
        }
    }

    // MARK: - 下载任务控管

    func pauseDownload(id: UUID) {
        guard let task = activeDownloads.first(where: { $0.id == id }) else { return }
        task.sessionTask?.cancel(byProducingResumeData: { data in
            task.resumeData = data
        })
        task.status = .paused
        task.speedBytesPerSecond = 0
        scheduleDownloadQueue()
    }

    func resumeDownload(id: UUID) {
        guard let task = activeDownloads.first(where: { $0.id == id }) else { return }
        task.status = .waiting
        scheduleDownloadQueue()
    }

    func cancelDownload(id: UUID) {
        if let task = activeDownloads.first(where: { $0.id == id }) {
            task.sessionTask?.cancel()
        }
        activeDownloads.removeAll { $0.id == id }
        scheduleDownloadQueue()
    }

    func pauseAllDownloads() {
        isPaused = true
        for task in activeDownloads where task.status == .downloading || task.status == .resolving {
            task.sessionTask?.cancel(byProducingResumeData: { data in
                task.resumeData = data
            })
            task.status = .paused
            task.speedBytesPerSecond = 0
        }
    }

    func resumeAllDownloads() {
        isPaused = false
        for task in activeDownloads where task.status == .paused {
            task.status = .waiting
        }
        scheduleDownloadQueue()
    }

    func clearFinishedDownloads() {
        activeDownloads.removeAll { $0.status == .completed || $0.status == .failed("") }
    }

    func removeDownloaded(song: Song) {
        if let localSong = LocalLibraryStore.shared.localSong(for: song.identityKey) {
            _ = LocalLibraryStore.shared.removeImportedSong(localSong)
        } else if let file = LocalAudioFileManager.shared.file(forSongId: song.identityKey) {
            try? LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: file.relativePath)
            LocalLibraryStore.shared.importedSongs.removeAll { $0.identityKey == song.identityKey }
        }
        ToastCenter.shared.show("已从本地移除：\(song.name)")
        ATMusicHaptics.medium()
    }

    // MARK: - 群晖 NAS 上传归档调度

    func startUploadToNAS(song: Song, customFolder: String? = nil) {
        guard SynologyAPI.shared.isLoggedIn else {
            ToastCenter.shared.show("请先在「我的」或设置中登录群晖 NAS 账号")
            return
        }

        let folder: String
        if let custom = customFolder, !custom.isEmpty {
            folder = custom
        } else {
            let root = UserDefaults.standard.string(forKey: "atmusic.nas.uploadRoot") ?? "/music/ATMusic"
            let cleanArtist = song.artists.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAlbum = song.album.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            folder = "\(root)/\(cleanArtist.isEmpty ? "未知歌手" : cleanArtist)/\(cleanAlbum.isEmpty ? "单曲" : cleanAlbum)"
        }

        let item = UploadTaskItem(song: song, destinationFolder: folder)
        activeUploads.insert(item, at: 0)
        ATMusicHaptics.medium()
        ToastCenter.shared.show("已加入群晖 NAS 上传队列：\(song.name)")
        scheduleUploadQueue()
    }

    func startBatchUploadToNAS(songs: [Song], customFolder: String? = nil) {
        guard SynologyAPI.shared.isLoggedIn else {
            ToastCenter.shared.show("请先在「我的」或设置中登录群晖 NAS 账号")
            return
        }

        let root = UserDefaults.standard.string(forKey: "atmusic.nas.uploadRoot") ?? "/music/ATMusic"
        for song in songs {
            let folder: String
            if let custom = customFolder, !custom.isEmpty {
                folder = custom
            } else {
                let cleanArtist = song.artists.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanAlbum = song.album.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                folder = "\(root)/\(cleanArtist.isEmpty ? "未知歌手" : cleanArtist)/\(cleanAlbum.isEmpty ? "单曲" : cleanAlbum)"
            }
            let item = UploadTaskItem(song: song, destinationFolder: folder)
            activeUploads.append(item)
        }
        ATMusicHaptics.medium()
        ToastCenter.shared.show("已将 \(songs.count) 首歌曲加入群晖 NAS 上传队列")
        scheduleUploadQueue()
    }

    private func scheduleUploadQueue() {
        let runningCount = activeUploads.filter {
            $0.status == .uploadingAudio || $0.status == .uploadingSupportFiles || $0.status == .syncingTags
        }.count
        guard runningCount < maxConcurrentUploads else { return }

        let availableSlots = maxConcurrentUploads - runningCount
        let waitingTasks = Array(activeUploads.filter { $0.status == .waiting }.prefix(availableSlots))

        for task in waitingTasks {
            task.status = .uploadingAudio
            executeUploadTask(task)
        }
    }

    private func executeUploadTask(_ task: UploadTaskItem) {
        Task {
            let song = task.song
            // 1. 获取本地文件
            var localURL = localAudioURL(for: song)
            if localURL == nil {
                // 如果尚未下载，先静默下载
                task.status = .waiting
                let result = await download(song: song, quality: .lossless)
                if case .success(let downloaded) = result {
                    localURL = downloaded.url
                }
            }

            guard let localAudioURL = localURL, FileManager.default.fileExists(atPath: localAudioURL.path) else {
                task.status = .failed("未找到可上传的本地音频文件")
                scheduleUploadQueue()
                return
            }

            // 2. 上传音频主体
            task.status = .uploadingAudio
            var lastUploaded: Int64 = 0
            var lastDate = Date()

            let trackPrefix = song.trackNumber > 0 ? String(format: "%02d - ", song.trackNumber) : ""
            let safeTitle = song.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            var ext = localAudioURL.pathExtension.lowercased()
            if ext.isEmpty || ext == "tmp" {
                ext = AudioFormatDetector.detectExtension(fileURL: localAudioURL, fallback: "flac")
            }
            let destFilename = "\(trackPrefix)\(safeTitle).\(ext)"
            let mimeType = AudioFormatDetector.mimeType(forExtension: ext)

            do {
                let nasPath = try await SynologyAPI.shared.uploadFileToNAS(
                    localFileURL: localAudioURL,
                    destinationFolder: task.destinationFolder,
                    filename: destFilename,
                    mimeType: mimeType,
                    onProgress: { progress, sent, total in
                        task.progress = progress
                        task.uploadedBytes = sent
                        task.totalBytes = total
                        let now = Date()
                        let elapsed = now.timeIntervalSince(lastDate)
                        if elapsed >= 0.5 {
                            let delta = sent - lastUploaded
                            if delta > 0 {
                                task.speedBytesPerSecond = Double(delta) / elapsed
                            }
                            lastUploaded = sent
                            lastDate = now
                        }
                    }
                )

                // 3. 上传伴生歌词
                task.status = .uploadingSupportFiles
                if let rawLyrics = await SongLyricsLoader.rawLyricString(for: song), !rawLyrics.isEmpty {
                    let tempLRC = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lrc")
                    try? rawLyrics.data(using: .utf8)?.write(to: tempLRC)
                    let lrcFilename = (destFilename as NSString).deletingPathExtension + ".lrc"
                    _ = try? await SynologyAPI.shared.uploadFileToNAS(
                        localFileURL: tempLRC,
                        destinationFolder: task.destinationFolder,
                        filename: lrcFilename,
                        mimeType: "text/plain"
                    )
                    try? FileManager.default.removeItem(at: tempLRC)
                }

                // 4. 写入 NAS Audio Station 媒体标签
                task.status = .syncingTags
                let patch = SynologyTagPatch(
                    title: song.name,
                    artist: song.artists,
                    album: song.album,
                    albumArtist: (song.albumArtist?.isEmpty == false ? song.albumArtist! : song.artists),
                    genre: song.genre,
                    year: song.year,
                    comment: "AT Music 归档"
                )
                let remoteSong = Song(
                    id: song.id,
                    name: song.name,
                    artists: song.artists,
                    album: song.album,
                    coverURL: song.coverURL,
                    duration: song.duration,
                    source: .synology,
                    synologyPath: nasPath
                )
                try? await SynologyAPI.shared.applyMetadata(song: remoteSong, patch: patch)

                task.status = .completed
                task.progress = 1.0
                ATMusicHaptics.success()
                ToastCenter.shared.show("已成功归档到群晖 NAS：\(song.name)")
                ATMusicLogger.shared.log("✅ 成功归档到 NAS：\(song.name) -> \(nasPath)", level: .info)
                SynologyAPI.shared.invalidateFolderCache()
            } catch {
                task.status = .failed(error.localizedDescription)
                ATMusicLogger.shared.log("❌ 上传到 NAS 失败：\(song.name) - \(error.localizedDescription)", level: .error)
            }

            scheduleUploadQueue()
        }
    }

    func retryUpload(id: UUID) {
        guard let task = activeUploads.first(where: { $0.id == id }) else { return }
        task.status = .waiting
        task.progress = 0
        task.uploadedBytes = 0
        task.speedBytesPerSecond = 0
        scheduleUploadQueue()
    }

    func cancelUpload(id: UUID) {
        if let task = activeUploads.first(where: { $0.id == id }) {
            task.isCancelled = true
        }
        activeUploads.removeAll { $0.id == id }
        scheduleUploadQueue()
    }

    func clearFinishedUploads() {
        activeUploads.removeAll { $0.status == .completed || $0.status == .failed("") }
    }

    // MARK: - 基础底层下载与老接口兼容

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
                guard isUsableAudioFile(at: downloaded, response: response, song: song) else {
                    lastError = NetEaseError.unknown("返回内容不是有效音频")
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
        return .failure(lastError)
    }

    func resolveURL(song: Song, quality: DownloadQuality) async -> ResolvedDownloadURL? {
        // 1. NAS 必须只使用当前已验证作用域的 Audio Station 地址
        if song.source == .synology {
            guard let urlString = SynologyAPI.shared.songURL(song: song),
                  let url = URL(string: urlString),
                  !UnblockService.isCorruptOrAntiLeechURL(url) else { return nil }
            return ResolvedDownloadURL(url: url, actualQuality: .flac, sourceName: "群晖 NAS")
        }

        // 2. 核心原则：官方原生绝对第一优先级！带 VIP 鉴权Cookie，确保满血音质与正版音轨，绝不盲目跳第三方
        if song.source == .qq, let mid = song.qqMid {
            if let result = try? await QQMusicAPI.shared.songURLResult(
                songmid: mid,
                mediaMid: song.qqMediaMid,
                quality: quality.atmusicQuality
            ),
            let url = URL(string: result.url),
            !UnblockService.isCorruptOrAntiLeechURL(url) {
                return ResolvedDownloadURL(
                    url: url,
                    actualQuality: Self.downloadQuality(forQQBR: result.br),
                    sourceName: nil
                )
            }
        } else if song.source == .kugou {
            if let urlString = try? await KugouMusicAPI.shared.songURL(song: song, quality: quality.atmusicQuality),
               let url = URL(string: urlString),
               !UnblockService.isCorruptOrAntiLeechURL(url) {
                return ResolvedDownloadURL(url: url, actualQuality: quality, sourceName: nil)
            }
        } else if song.source == .netease {
            if let infos = try? await NetEaseAPI.shared.songURLInfo(ids: [song.id], level: quality.neteaseLevel),
               let info = infos[song.id],
               info.freeTrial != true,
               let urlString = info.url,
               let url = URL(string: urlString),
               !UnblockService.isCorruptOrAntiLeechURL(url) {
                return ResolvedDownloadURL(url: url, actualQuality: quality, sourceName: nil)
            }
        }

        // 3. 官方全档位无版权/非VIP无完整音轨时，仅在启用自定义音源时进行第三方兜底
        if UnblockSourceStore.shared.isEffectivelyEnabled {
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
            ), !UnblockService.isCorruptOrAntiLeechURL(resolved.url) {
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
        }

        return nil
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

    private func isUsableAudioFile(at url: URL, response: URLResponse, song: Song? = nil) -> Bool {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("text/") || mimeType.contains("json") || mimeType.contains("html") {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 1024 else {
            return false
        }

        if let song = song, song.duration >= 45, fileSize.int64Value < 250_000 {
            ATMusicLogger.shared.log("🚫 下载音频过小可能为防盗链或损坏音频：\(song.name) 大小=\(fileSize.int64Value) 歌曲时长=\(song.duration)s", level: .warn)
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
}
