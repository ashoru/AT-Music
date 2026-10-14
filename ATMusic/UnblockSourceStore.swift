import Foundation

/// 第三方解锁源配置。
/// kind：音源类型标识，用于兼容不同导入格式。
/// template：请求 URL 模板，支持 {id}、{source}、{quality} 占位符。
/// headers：可选的请求头与内置元数据。
/// quality：默认音质选择。
/// script：LX / Baka 风格 JS 脚本内容。
struct ThirdPartySource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var quality: String = "320k"
    var script: String?
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, quality, script, enabled
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        quality: String = "320k",
        script: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? headers["quality"] ?? "320k"
        script = try container.decodeIfPresent(String.self, forKey: .script)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 第三方音源管理：只保存用户导入的音源配置。
final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()
    private static let removedBuiltInSourceIDs: Set<String> = [
        "atmusic.preset.shiqianjiang.lx.v7",
        "atmusic.preset.shiqianjiang.cr.v7",
        "atmusic.preset.shiqianjiang.qt.v7",
        "atmusic.preset.legacy.guoyue.qq.v1",
        "atmusic.preset.legacy.guoyue.netease.v1",
        "atmusic.preset.cerumusic.free.v1",
        "atmusic.preset.quandouyao.free.v1",
        "atmusic.special.cr.v1"
    ]
    private static let deadSourceNames: Set<String> = [
        "野草🌾",
        "野花🌷",
        "HYWmusic_beta_公益测试",
        "聚合API接口 (CF)",
        "K×H测试",
        "星海音乐源",
        "长青SVIP音源(二改修复版)",
        "杰翔聚合音源",
        "lx-玉宁熙-Pro",
        "屿溪-终章",
        "星澜聚合音源 (StellarWave)",
        "星澜聚合音源(别人优化版)"
    ]
    private static let masterEnabledKey = "atmusic.thirdPartySources.enabled"

    @Published var isThirdPartyEnabled: Bool {
        didSet {
            defaults.set(isThirdPartyEnabled, forKey: Self.masterEnabledKey)
            NotificationCenter.default.post(name: .atmusicThirdPartySourceSettingDidChange, object: nil)
        }
    }

    var isEffectivelyEnabled: Bool {
        isThirdPartyEnabled && sources.contains(where: \.enabled)
    }

    func setThirdPartyEnabled(_ enabled: Bool) {
        isThirdPartyEnabled = enabled
    }

    @Published var sources: [ThirdPartySource] {
        didSet { save() }
    }

    var managementVisibleSources: [ThirdPartySource] {
        sources
    }

    private let defaults = UserDefaults.standard
    private let presetsKey = "atmusic.unblock.presets"
    private let legacyCustomKey = "atmusic.unblock.custom"
    private let legacyLXKey = "atmusic.unblock.lxScripts"

    private init() {
        let initialEnabled = defaults.object(forKey: Self.masterEnabledKey) as? Bool ?? true
        self.isThirdPartyEnabled = initialEnabled
        let savedSources: [ThirdPartySource]
        if let data = defaults.data(forKey: presetsKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else if let data = defaults.data(forKey: legacyCustomKey),
                  let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else {
            savedSources = []
        }

        // 旧版本的内置预设与已知失效/死链音源全部清理，只保留有效的配置。
        var seen = Set<String>()
        sources = savedSources.compactMap { source in
            guard !Self.removedBuiltInSourceIDs.contains(source.id),
                  !Self.deadSourceNames.contains(source.name),
                  seen.insert(source.id).inserted else { return nil }
            return source
        }

        // 核心加固：确保最新的终极极速音源始终存在且优先置顶启用
        if let primaryBuiltIn = BuiltInLXSources.makeSources().first {
            if let existingIndex = sources.firstIndex(where: { $0.name == primaryBuiltIn.name || $0.id == primaryBuiltIn.id }) {
                sources.remove(at: existingIndex)
            }
            sources.insert(primaryBuiltIn, at: 0)
        }
        defaults.removeObject(forKey: legacyCustomKey)
        defaults.removeObject(forKey: legacyLXKey)
        defaults.removeObject(forKey: "atmusic.thirdPartyAPIKeys")
        defaults.removeObject(forKey: "atmusic.paidAudioSource.usageRecorded")
        defaults.removeObject(forKey: "atmusic.enableUnblock")
        defaults.removeObject(forKey: "atmusic.useFreeAudioSource")
        defaults.removeObject(forKey: "atmusic.showThirdPartyKeys")
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    func addSource(_ source: ThirdPartySource) {
        upsert(source)
    }

    func addSources(_ newSources: [ThirdPartySource]) {
        guard !newSources.isEmpty else { return }
        var merged = sources
        for source in newSources {
            if let index = merged.firstIndex(where: { $0.id == source.id }) {
                merged[index] = source
            } else {
                merged.append(source)
            }
        }
        sources = merged
        save()
    }

    func upsert(_ source: ThirdPartySource) {
        var merged = sources
        if let index = merged.firstIndex(where: { $0.id == source.id }) {
            merged[index] = source
        } else {
            merged.append(source)
        }
        sources = merged
        save()
    }

    func moveSource(id: String, by offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), max(0, sources.count - 1))
        guard target != index else { return }
        var reordered = sources
        let item = reordered.remove(at: index)
        reordered.insert(item, at: target)
        sources = reordered
        save()
    }

    func moveManagementSource(id: String, by offset: Int) {
        let visibleIDs = managementVisibleSources.map(\.id)
        guard let visibleIndex = visibleIDs.firstIndex(of: id) else { return }
        let targetVisibleIndex = visibleIndex + offset
        guard visibleIDs.indices.contains(targetVisibleIndex) else { return }
        let targetID = visibleIDs[targetVisibleIndex]
        guard let sourceIndex = sources.firstIndex(where: { $0.id == id }) else { return }

        var reordered = sources
        let item = reordered.remove(at: sourceIndex)
        guard let adjustedTargetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = targetVisibleIndex > visibleIndex
            ? adjustedTargetIndex + 1
            : adjustedTargetIndex
        reordered.insert(item, at: min(insertionIndex, reordered.count))
        sources = reordered
        save()
    }

    func updateEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var updated = sources
        updated[index].enabled = enabled
        sources = updated
        save()
    }

    @discardableResult
    func removeSource(id: String) -> Bool {
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        save()
        return sources.count != originalCount
    }

}

extension UnblockSourceStore {
    func availableThirdPartyQualities() -> [ThirdPartyAudioQuality] {
        let options = sources
            .filter(\.enabled)
            .flatMap { Self.supportedQualities(for: $0) }
            .uniquePreservingOrder()
        return options.isEmpty ? ThirdPartyAudioQuality.allCases : options
    }

    static func supportedQualities(
        for source: ThirdPartySource,
        providerCode: String? = nil
    ) -> [ThirdPartyAudioQuality] {
        let explicit = explicitQualities(
            from: source.headers["qualities"] ?? source.headers["qualityOptions"] ?? source.headers["qualitys"]
        )
        if !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let script = source.script,
           let explicit = scriptQualities(from: script),
           !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let providerCode {
            return ThirdPartyAudioQuality.supported(providerCode: providerCode)
        }

        if let sourceProvider = source.headers["source"] ?? source.headers["platform"] {
            return ThirdPartyAudioQuality.supported(providerCode: sourceProvider)
        }

        return ThirdPartyAudioQuality.allCases
    }

    private static func explicitQualities(from raw: String?) -> [ThirdPartyAudioQuality] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|/[]\"'"))
        return raw
            .components(separatedBy: separators)
            .compactMap { ThirdPartyAudioQuality(sourceValue: $0) }
            .uniquePreservingOrder()
    }

    private static func scriptQualities(from script: String) -> [ThirdPartyAudioQuality]? {
        let pattern = #"(?i)(?:qualitys?|qualityOptions)\s*[:=]\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: script,
                options: [],
                range: NSRange(script.startIndex..<script.endIndex, in: script)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return explicitQualities(from: String(script[range]))
    }
}

private extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
// MARK: - 内置洛雪音源（随 App 打包，开箱即用：无用户导入源时自动注入，恢复第三方 VIP 兜底）

enum BuiltInLXSources {
    static let bundled: [(name: String, base64: String)] = [
        ("AT-Music 终极极速音源", "LyohCiAqIEBuYW1lIEFULU11c2ljIOe7iOaegeaegemAn+iBmuWQiOmfs+a6kAogKiBAZGVzY3JpcHRpb24g5LiT5Li6IEFULU11c2ljIOaJk+mAoOeahOaegemAn+eos+WumumrmOWPr+eUqOmfs+a6kO+8muaVtOWQiOi9puacuuS4k+e6v+OAgei3qOa6kOWFqOabsuebtOi/nuOAgeWumOaWueebtOi/nuS4juWSquWSleS4k+e6v++8jOavq+enkue6p+WHuuWjsOS4juWkmue6p+W5s+a7keWuueeBvuOAggogKiBAdmVyc2lvbiA1LjIuMAogKiBAYXV0aG9yIEFULU11c2ljICYgR2VtaW5pCiAqLwoKY29uc3QgeyBFVkVOVF9OQU1FUywgcmVxdWVzdCwgb24sIHNlbmQsIHV0aWxzLCBlbnYsIHZlcnNpb24sIGN1cnJlbnRTY3JpcHRJbmZvIH0gPSBnbG9iYWxUaGlzLmx4OwoKY29uc3QgaHR0cEdldCA9ICh1cmwsIGhlYWRlcnMgPSB7fSwgdGltZW91dCA9IDMwMDApID0+IHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgcmVxdWVzdCh1cmwsIHsKICAgICAgbWV0aG9kOiAiR0VUIiwKICAgICAgaGVhZGVyczogT2JqZWN0LmFzc2lnbih7CiAgICAgICAgIlVzZXItQWdlbnQiOiAib2todHRwLzMuMTAuMCIsCiAgICAgICAgIkFjY2VwdCI6ICIqLyoiCiAgICAgIH0sIGhlYWRlcnMpLAogICAgICB0aW1lb3V0OiB0aW1lb3V0CiAgICB9LCAoZXJyLCByZXNwKSA9PiB7CiAgICAgIGlmIChlcnIpIHJldHVybiByZWplY3QoZXJyKTsKICAgICAgaWYgKCFyZXNwKSByZXR1cm4gcmVqZWN0KG5ldyBFcnJvcigi5peg5ZON5bqUIikpOwogICAgICBjb25zdCBib2R5ID0gcmVzcC5ib2R5OwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICJvYmplY3QiICYmIGJvZHkgIT09IG51bGwpIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICJzdHJpbmciKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKEpTT04ucGFyc2UoYm9keSkpOwogICAgICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICAgIH0KICAgICAgfQogICAgICByZXNvbHZlKGJvZHkpOwogICAgfSk7CiAgfSk7Cn07Cgpjb25zdCBodHRwUG9zdCA9ICh1cmwsIGRhdGEsIGhlYWRlcnMgPSB7fSwgdGltZW91dCA9IDMwMDApID0+IHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgY29uc3QgaXNKc29uID0gdHlwZW9mIGRhdGEgPT09ICJvYmplY3QiOwogICAgY29uc3QgcG9zdEhlYWRlcnMgPSBPYmplY3QuYXNzaWduKHsKICAgICAgIlVzZXItQWdlbnQiOiAiTW96aWxsYS81LjAgKGlQaG9uZTsgQ1BVIGlQaG9uZSBPUyAxN181IGxpa2UgTWFjIE9TIFgpIEFwcGxlV2ViS2l0LzYwNS4xLjE1IiwKICAgICAgIkNvbnRlbnQtVHlwZSI6IGlzSnNvbiA/ICJhcHBsaWNhdGlvbi9qc29uIiA6ICJhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQiCiAgICB9LCBoZWFkZXJzKTsKICAgIHJlcXVlc3QodXJsLCB7CiAgICAgIG1ldGhvZDogIlBPU1QiLAogICAgICBoZWFkZXJzOiBwb3N0SGVhZGVycywKICAgICAgYm9keTogaXNKc29uID8gSlNPTi5zdHJpbmdpZnkoZGF0YSkgOiBkYXRhLAogICAgICB0aW1lb3V0OiB0aW1lb3V0CiAgICB9LCAoZXJyLCByZXNwKSA9PiB7CiAgICAgIGlmIChlcnIpIHJldHVybiByZWplY3QoZXJyKTsKICAgICAgaWYgKCFyZXNwKSByZXR1cm4gcmVqZWN0KG5ldyBFcnJvcigi5peg5ZON5bqUIikpOwogICAgICBjb25zdCBib2R5ID0gcmVzcC5ib2R5OwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICJvYmplY3QiICYmIGJvZHkgIT09IG51bGwpIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICJzdHJpbmciKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKEpTT04ucGFyc2UoYm9keSkpOwogICAgICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICAgIH0KICAgICAgfQogICAgICByZXNvbHZlKGJvZHkpOwogICAgfSk7CiAgfSk7Cn07Cgpjb25zdCBpc1ZhbGlkQXVkaW9VcmwgPSAodXJsKSA9PiB7CiAgaWYgKCF1cmwgfHwgdHlwZW9mIHVybCAhPT0gInN0cmluZyIpIHJldHVybiBmYWxzZTsKICBjb25zdCB0cmltbWVkID0gdXJsLnRyaW0oKTsKICBpZiAoIXRyaW1tZWQuc3RhcnRzV2l0aCgiaHR0cDovLyIpICYmICF0cmltbWVkLnN0YXJ0c1dpdGgoImh0dHBzOi8vIikpIHJldHVybiBmYWxzZTsKICBpZiAodHJpbW1lZC5pbmNsdWRlcygiMjAyNi0wNi0xNy0xOTU3MjJfMTA0NTk1IikpIHJldHVybiBmYWxzZTsKICBpZiAodHJpbW1lZC5pbmNsdWRlcygibXVzaWMuMTYzLmNvbS80MDQiKSkgcmV0dXJuIGZhbHNlOwogIGlmICh0cmltbWVkLmluY2x1ZGVzKCJlcnJvci5waHAiKSB8fCB0cmltbWVkLmluY2x1ZGVzKCJlcnJvcl91cmwiKSkgcmV0dXJuIGZhbHNlOwogIHJldHVybiB0cnVlOwp9OwoKY29uc3QgZ2V0U29uZ0lkZW50aWZpZXIgPSAoc291cmNlLCBpbmZvKSA9PiB7CiAgY29uc3QgbXVzaWNJbmZvID0gaW5mby5tdXNpY0luZm8gfHwge307CiAgaWYgKHNvdXJjZSA9PT0gInR4IikgewogICAgcmV0dXJuIG11c2ljSW5mby5zb25nbWlkIHx8IG11c2ljSW5mby5taWQgfHwgbXVzaWNJbmZvLmlkIHx8ICIiOwogIH0KICBpZiAoc291cmNlID09PSAia2ciKSB7CiAgICByZXR1cm4gbXVzaWNJbmZvLmhhc2ggfHwgbXVzaWNJbmZvLmlkIHx8ICIiOwogIH0KICByZXR1cm4gbXVzaWNJbmZvLmlkIHx8IG11c2ljSW5mby5zb25nbWlkIHx8ICIiOwp9OwoKY29uc3QgZmV0Y2hLdXdvTW9iaUJ5UmlkID0gYXN5bmMgKHJpZCwgcXVhbGl0eSkgPT4gewogIGNvbnN0IGJyTWFwID0gewogICAgIjEyOGsiOiAiMTI4a21wMyIsCiAgICAiMTkyayI6ICIxOTJrb2dnIiwKICAgICIzMjBrIjogIjMyMGttcDMiLAogICAgImZsYWMiOiAiMjAwMGtmbGFjIiwKICAgICJmbGFjMjRiaXQiOiAiMjAwMGtmbGFjIgogIH07CiAgY29uc3QgYnIgPSBick1hcFtxdWFsaXR5XSB8fCAiMzIwa21wMyI7CgogIC8vIOa4oOmBkyAxOiDovabmnLrkuJPnur8gY29udmVydF91cmwyICjmnoHpgJ/lk43lupQgfjMwbXMpCiAgdHJ5IHsKICAgIGNvbnN0IHVybDEgPSAiaHR0cDovL2FueW1hdGNoLmt1d28uY24vbW9iaS5zP2Y9d2ViJnJpZD0iICsgZW5jb2RlVVJJQ29tcG9uZW50KHJpZCkgKyAiJmJyPSIgKyBiciArICImc291cmNlPWt3cGxheWVyY2FyX2FyXzYuMC4wLjlfQl9qaWFrb25nX3ZoLmFwayZ0eXBlPWNvbnZlcnRfdXJsMiI7CiAgICBjb25zdCByYXcgPSBhd2FpdCBodHRwR2V0KHVybDEsIHsgIlVzZXItQWdlbnQiOiAib2todHRwLzMuMTAuMCIgfSwgMjAwMCk7CiAgICBpZiAodHlwZW9mIHJhdyA9PT0gInN0cmluZyIgJiYgcmF3LmluY2x1ZGVzKCJ1cmw9IikpIHsKICAgICAgY29uc3QgbWF0Y2ggPSByYXcubWF0Y2goL3VybD0oW15cclxuXSspLyk7CiAgICAgIGlmIChtYXRjaCAmJiBtYXRjaFsxXSAmJiBpc1ZhbGlkQXVkaW9VcmwobWF0Y2hbMV0pKSB7CiAgICAgICAgcmV0dXJuIHsKICAgICAgICAgIHVybDogbWF0Y2hbMV0udHJpbSgpLAogICAgICAgICAgaGVhZGVyczogeyAiVXNlci1BZ2VudCI6ICJva2h0dHAvMy4xMC4wIiwgIlJlZmVyZXIiOiAiaHR0cDovL2t1d28uY24vIiB9CiAgICAgICAgfTsKICAgICAgfQogICAgfQogIH0gY2F0Y2ggKGUpIHt9CgogIC8vIOa4oOmBkyAyOiDovabmnLrnrb7lkI3pgJrpgZMgY29udmVydF91cmxfd2l0aF9zaWduCiAgY29uc3QgdXJsMiA9ICJodHRwczovL21vYmkua3V3by5jbi9tb2JpLnM/Zj13ZWImcmlkPSIgKyBlbmNvZGVVUklDb21wb25lbnQocmlkKSArICImYnI9IiArIGJyICsgIiZzb3VyY2U9amlha29uZyZ0eXBlPWNvbnZlcnRfdXJsX3dpdGhfc2lnbiZzdXJsPTEiOwogIGNvbnN0IHJlcyA9IGF3YWl0IGh0dHBHZXQodXJsMiwgeyAiVXNlci1BZ2VudCI6ICJva2h0dHAvMy4xMC4wIiB9LCAyMDAwKTsKICBpZiAocmVzICYmIHJlcy5jb2RlID09PSAyMDAgJiYgcmVzLmRhdGEpIHsKICAgIGNvbnN0IHBsYXlVcmwgPSByZXMuZGF0YS5zdXJsIHx8IHJlcy5kYXRhLnVybDsKICAgIGlmIChwbGF5VXJsICYmIGlzVmFsaWRBdWRpb1VybChwbGF5VXJsKSkgewogICAgICByZXR1cm4gewogICAgICAgIHVybDogcGxheVVybCwKICAgICAgICBoZWFkZXJzOiB7CiAgICAgICAgICAiVXNlci1BZ2VudCI6ICJva2h0dHAvMy4xMC4wIiwKICAgICAgICAgICJSZWZlcmVyIjogImh0dHA6Ly9rdXdvLmNuLyIKICAgICAgICB9CiAgICAgIH07CiAgICB9CiAgfQogIHRocm93IG5ldyBFcnJvcigi6YW35oiR6L2m5py65o6l5Y+j5pyq6L+U5Zue5pyJ5pWI6ZO+5o6lIik7Cn07Cgpjb25zdCBmZXRjaEt1d29Dcm9zc1NlYXJjaCA9IGFzeW5jIChuYW1lLCBhcnRpc3QsIHF1YWxpdHkpID0+IHsKICBpZiAoIW5hbWUpIHRocm93IG5ldyBFcnJvcigi57y65bCR5q2M5ZCNIik7CiAgY29uc3QgcXVlcnkgPSBlbmNvZGVVUklDb21wb25lbnQoKGFydGlzdCA/IGFydGlzdCArICIgIiA6ICIiKSArIG5hbWUpOwogIGNvbnN0IHNlYXJjaFVybCA9ICJodHRwOi8vc2VhcmNoLmt1d28uY24vci5zP2NsaWVudD1rdCZhbGw9IiArIHF1ZXJ5ICsgIiZwbj0wJnJuPTUmdmVyPWt3cGxheWVyX2FyXzkuMi4xJnZpcHZlcj0xJmZ0PW11c2ljJmNsdXN0ZXI9MCZzdHJhdGVneT0yMDEyJmVuY29kaW5nPXV0ZjgmcmZvcm1hdD1qc29uIjsKICBjb25zdCByYXcgPSBhd2FpdCBodHRwR2V0KHNlYXJjaFVybCwgeyAiVXNlci1BZ2VudCI6ICJva2h0dHAvMy4xMC4wIiB9LCAyNTAwKTsKICBsZXQgc2VhcmNoRGF0YSA9IHJhdzsKICBpZiAodHlwZW9mIHJhdyA9PT0gInN0cmluZyIpIHsKICAgIHRyeSB7CiAgICAgIHNlYXJjaERhdGEgPSBKU09OLnBhcnNlKHJhdy5yZXBsYWNlKC8nL2csICJcIiIpKTsKICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgdGhyb3cgbmV3IEVycm9yKCLphbfmiJHmkJzntKLnu5Pmnpzop6PmnpDlpLHotKUiKTsKICAgIH0KICB9CiAgaWYgKCFzZWFyY2hEYXRhIHx8ICFzZWFyY2hEYXRhLmFic2xpc3QgfHwgIXNlYXJjaERhdGEuYWJzbGlzdC5sZW5ndGgpIHsKICAgIHRocm93IG5ldyBFcnJvcigi6YW35oiR5pyq5pCc57Si5Yiw5a+55bqU5q2M5puyIik7CiAgfQogIGZvciAoY29uc3QgaXRlbSBvZiBzZWFyY2hEYXRhLmFic2xpc3QpIHsKICAgIGNvbnN0IHJpZCA9IGl0ZW0uRENfVEFSR0VUSUQgfHwgKGl0ZW0uTVVTSUNSSUQgPyBpdGVtLk1VU0lDUklELnJlcGxhY2UoIk1VU0lDXyIsICIiKSA6ICIiKTsKICAgIGlmICghcmlkKSBjb250aW51ZTsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHJlcyA9IGF3YWl0IGZldGNoS3V3b01vYmlCeVJpZChyaWQsIHF1YWxpdHkpOwogICAgICBpZiAocmVzICYmIHJlcy51cmwpIHJldHVybiByZXM7CiAgICB9IGNhdGNoIChlKSB7fQogIH0KICB0aHJvdyBuZXcgRXJyb3IoIuaXoOacieaViOmFt+aIkeaSreaUvumTvuaOpSIpOwp9OwoKY29uc3QgZmV0Y2hRUU9mZmljaWFsID0gYXN5bmMgKHNvbmdtaWQpID0+IHsKICBjb25zdCBmaWxlID0gIk01MDAiICsgc29uZ21pZCArICIubXAzIjsKICBjb25zdCBndWlkID0gIjEwMDAwMDAwMDAiOwogIGNvbnN0IHJlcURhdGEgPSB7CiAgICByZXFfMDogewogICAgICBtb2R1bGU6ICJ2a2V5LkdldFZrZXlTZXJ2ZXIiLAogICAgICBtZXRob2Q6ICJDZ2lHZXRWa2V5IiwKICAgICAgcGFyYW06IHsgZmlsZW5hbWU6IFtmaWxlXSwgZ3VpZDogZ3VpZCwgc29uZ21pZDogW3NvbmdtaWRdLCBzb25ndHlwZTogWzBdLCB1aW46ICIwIiwgbG9naW5mbGFnOiAwLCBwbGF0Zm9ybTogIjIwIiB9CiAgICB9LAogICAgbG9naW5VaW46ICIwIiwKICAgIGNvbW06IHsgdWluOiAiMCIsIGZvcm1hdDogImpzb24iLCBjdDogMjQsIGN2OiAwIH0KICB9OwogIGNvbnN0IHJlcyA9IGF3YWl0IGh0dHBQb3N0KCJodHRwczovL3UueS5xcS5jb20vY2dpLWJpbi9tdXNpY3UuZmNnIiwgcmVxRGF0YSwgewogICAgIlVzZXItQWdlbnQiOiAiTW96aWxsYS81LjAgKFdpbmRvd3MgTlQgMTAuMDsgV2luNjQ7IHg2NCkgQXBwbGVXZWJLaXQvNTM3LjM2IiwKICAgICJSZWZlcmVyIjogImh0dHBzOi8veS5xcS5jb20vIgogIH0sIDI1MDApOwogIGlmIChyZXMgJiYgcmVzLnJlcV8wICYmIHJlcy5yZXFfMC5kYXRhICYmIHJlcy5yZXFfMC5kYXRhLm1pZHVybGluZm8gJiYgcmVzLnJlcV8wLmRhdGEubWlkdXJsaW5mb1swXSkgewogICAgY29uc3QgaW5mbyA9IHJlcy5yZXFfMC5kYXRhLm1pZHVybGluZm9bMF07CiAgICBpZiAoaW5mby5wdXJsICYmIGlzVmFsaWRBdWRpb1VybChpbmZvLnB1cmwpKSB7CiAgICAgIGNvbnN0IHNpcCA9IChyZXMucmVxXzAuZGF0YS5zaXAgJiYgcmVzLnJlcV8wLmRhdGEuc2lwWzBdKSB8fCAiaHR0cHM6Ly9pc3VyZS5zdHJlYW0ucXFtdXNpYy5xcS5jb20vIjsKICAgICAgcmV0dXJuIHsKICAgICAgICB1cmw6IHNpcCArIGluZm8ucHVybCwKICAgICAgICBoZWFkZXJzOiB7CiAgICAgICAgICAiVXNlci1BZ2VudCI6ICJNb3ppbGxhLzUuMCAoV2luZG93cyBOVCAxMC4wOyBXaW42NDsgeDY0KSIsCiAgICAgICAgICAiUmVmZXJlciI6ICJodHRwczovL3kucXEuY29tLyIKICAgICAgICB9CiAgICAgIH07CiAgICB9CiAgfQogIHRocm93IG5ldyBFcnJvcigiUVEg5a6Y5pa55o6l5Y+j5pegIHB1cmwiKTsKfTsKCmNvbnN0IGZldGNoTWlndU1vYmkgPSBhc3luYyAoaWQpID0+IHsKICBjb25zdCB1cmwgPSAiaHR0cHM6Ly9hcHAuYy5uZi5taWd1LmNuL01JR1VNMi4wL3N0cmF0ZWd5L2xpc3Rlbi11cmwvdjIuMj9uZXRUeXBlPTAxJnJlc291cmNlVHlwZT0yJnNvbmdJZD0iICsgZW5jb2RlVVJJQ29tcG9uZW50KGlkKSArICImY29udGVudElkPSIgKyBlbmNvZGVVUklDb21wb25lbnQoaWQpOwogIGNvbnN0IHJlcyA9IGF3YWl0IGh0dHBHZXQodXJsLCB7ICJVc2VyLUFnZW50IjogIk1vemlsbGEvNS4wIiB9LCAyNTAwKTsKICBpZiAocmVzICYmIHJlcy5kYXRhICYmIHJlcy5kYXRhLnVybCAmJiBpc1ZhbGlkQXVkaW9VcmwocmVzLmRhdGEudXJsKSkgewogICAgcmV0dXJuIHsKICAgICAgdXJsOiByZXMuZGF0YS51cmwsCiAgICAgIGhlYWRlcnM6IHsKICAgICAgICAiVXNlci1BZ2VudCI6ICJNb3ppbGxhLzUuMCIsCiAgICAgICAgIlJlZmVyZXIiOiAiaHR0cHM6Ly9tdXNpYy5taWd1LmNuLyIKICAgICAgfQogICAgfTsKICB9CiAgdGhyb3cgbmV3IEVycm9yKCLlkqrlkpXmjqXlj6Pml6Dnm7Tpk74iKTsKfTsKCm9uKEVWRU5UX05BTUVTLnJlcXVlc3QsIGFzeW5jICh7IGFjdGlvbiwgc291cmNlLCBpbmZvIH0pID0+IHsKICBpZiAoYWN0aW9uICE9PSAibXVzaWNVcmwiKSB7CiAgICB0aHJvdyBuZXcgRXJyb3IoIuS4jeaUr+aMgeeahOaTjeS9nDogIiArIGFjdGlvbik7CiAgfQogIGNvbnN0IGlkID0gZ2V0U29uZ0lkZW50aWZpZXIoc291cmNlLCBpbmZvKTsKICBjb25zdCBxdWFsaXR5ID0gaW5mby50eXBlIHx8ICIzMjBrIjsKICBjb25zdCBtdXNpY0luZm8gPSBpbmZvLm11c2ljSW5mbyB8fCB7fTsKICBjb25zdCBzb25nTmFtZSA9IG11c2ljSW5mby5uYW1lIHx8IG11c2ljSW5mby5zb25nTmFtZSB8fCAiIjsKICBjb25zdCBzaW5nZXIgPSBtdXNpY0luZm8uc2luZ2VyIHx8IG11c2ljSW5mby5hcnRpc3QgfHwgIiI7CgogIGNvbnN0IHRhc2tzID0gW107CgogIGlmIChzb3VyY2UgPT09ICJrdyIpIHsKICAgIHRhc2tzLnB1c2goZmV0Y2hLdXdvTW9iaUJ5UmlkKGlkLCBxdWFsaXR5KSk7CiAgICBpZiAoc29uZ05hbWUpIHsKICAgICAgdGFza3MucHVzaChmZXRjaEt1d29Dcm9zc1NlYXJjaChzb25nTmFtZSwgc2luZ2VyLCBxdWFsaXR5KSk7CiAgICB9CiAgfSBlbHNlIGlmIChzb3VyY2UgPT09ICJ3eSIpIHsKICAgIGlmIChzb25nTmFtZSkgewogICAgICB0YXNrcy5wdXNoKGZldGNoS3V3b0Nyb3NzU2VhcmNoKHNvbmdOYW1lLCBzaW5nZXIsIHF1YWxpdHkpKTsKICAgIH0KICB9IGVsc2UgaWYgKHNvdXJjZSA9PT0gInR4IikgewogICAgdGFza3MucHVzaChmZXRjaFFRT2ZmaWNpYWwoaWQpKTsKICAgIGlmIChzb25nTmFtZSkgewogICAgICB0YXNrcy5wdXNoKGZldGNoS3V3b0Nyb3NzU2VhcmNoKHNvbmdOYW1lLCBzaW5nZXIsIHF1YWxpdHkpKTsKICAgIH0KICB9IGVsc2UgaWYgKHNvdXJjZSA9PT0gImtnIikgewogICAgaWYgKHNvbmdOYW1lKSB7CiAgICAgIHRhc2tzLnB1c2goZmV0Y2hLdXdvQ3Jvc3NTZWFyY2goc29uZ05hbWUsIHNpbmdlciwgcXVhbGl0eSkpOwogICAgfQogIH0gZWxzZSBpZiAoc291cmNlID09PSAibWciKSB7CiAgICB0YXNrcy5wdXNoKGZldGNoTWlndU1vYmkoaWQpKTsKICAgIGlmIChzb25nTmFtZSkgewogICAgICB0YXNrcy5wdXNoKGZldGNoS3V3b0Nyb3NzU2VhcmNoKHNvbmdOYW1lLCBzaW5nZXIsIHF1YWxpdHkpKTsKICAgIH0KICB9IGVsc2UgewogICAgaWYgKHNvbmdOYW1lKSB7CiAgICAgIHRhc2tzLnB1c2goZmV0Y2hLdXdvQ3Jvc3NTZWFyY2goc29uZ05hbWUsIHNpbmdlciwgcXVhbGl0eSkpOwogICAgfQogIH0KCiAgdHJ5IHsKICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IFByb21pc2UuYW55KHRhc2tzKTsKICAgIGlmIChyZXN1bHQgJiYgcmVzdWx0LnVybCAmJiBpc1ZhbGlkQXVkaW9VcmwocmVzdWx0LnVybCkpIHsKICAgICAgcmV0dXJuIHJlc3VsdDsKICAgIH0KICB9IGNhdGNoIChlcnIpIHsKICAgIGZvciAoY29uc3QgdCBvZiB0YXNrcykgewogICAgICB0cnkgewogICAgICAgIGNvbnN0IHJlcyA9IGF3YWl0IHQ7CiAgICAgICAgaWYgKHJlcyAmJiByZXMudXJsICYmIGlzVmFsaWRBdWRpb1VybChyZXMudXJsKSkgewogICAgICAgICAgcmV0dXJuIHJlczsKICAgICAgICB9CiAgICAgIH0gY2F0Y2ggKGUpIHt9CiAgICB9CiAgfQoKICB0aHJvdyBuZXcgRXJyb3IoIuaJgOaciemfs+a6kOmAmumBk+ino+aekOWksei0pTogIiArIHNvdXJjZSArICIgaWQ9IiArIGlkKTsKfSk7CgpzZW5kKEVWRU5UX05BTUVTLmluaXRlZCwgewogIG9wZW5EZXZUb29sczogZmFsc2UsCiAgc291cmNlczogewogICAgd3k6IHsKICAgICAgbmFtZTogIue9keaYk+S6kemfs+S5kCIsCiAgICAgIHR5cGU6ICJtdXNpYyIsCiAgICAgIGFjdGlvbnM6IFsibXVzaWNVcmwiXSwKICAgICAgcXVhbGl0eXM6IFsiMTI4ayIsICIzMjBrIiwgImZsYWMiLCAiZmxhYzI0Yml0Il0KICAgIH0sCiAgICB0eDogewogICAgICBuYW1lOiAiUVHpn7PkuZAiLAogICAgICB0eXBlOiAibXVzaWMiLAogICAgICBhY3Rpb25zOiBbIm11c2ljVXJsIl0sCiAgICAgIHF1YWxpdHlzOiBbIjEyOGsiLCAiMzIwayIsICJmbGFjIiwgImZsYWMyNGJpdCJdCiAgICB9LAogICAga2c6IHsKICAgICAgbmFtZTogIumFt+eLl+mfs+S5kCIsCiAgICAgIHR5cGU6ICJtdXNpYyIsCiAgICAgIGFjdGlvbnM6IFsibXVzaWNVcmwiXSwKICAgICAgcXVhbGl0eXM6IFsiMTI4ayIsICIzMjBrIiwgImZsYWMiLCAiZmxhYzI0Yml0Il0KICAgIH0sCiAgICBrdzogewogICAgICBuYW1lOiAi6YW35oiR6Z+z5LmQIiwKICAgICAgdHlwZTogIm11c2ljIiwKICAgICAgYWN0aW9uczogWyJtdXNpY1VybCJdLAogICAgICBxdWFsaXR5czogWyIxMjhrIiwgIjE5MmsiLCAiMzIwayIsICJmbGFjIiwgImZsYWMyNGJpdCJdCiAgICB9LAogICAgbWc6IHsKICAgICAgbmFtZTogIuWSquWSlemfs+S5kCIsCiAgICAgIHR5cGU6ICJtdXNpYyIsCiAgICAgIGFjdGlvbnM6IFsibXVzaWNVcmwiXSwKICAgICAgcXVhbGl0eXM6IFsiMTI4ayIsICIzMjBrIiwgImZsYWMiXQogICAgfQogIH0KfSk7Cg=="),
    ]

    static func makeSources() -> [ThirdPartySource] {
        bundled.compactMap { item in
            guard let data = Data(base64Encoded: item.base64),
                  let script = String(data: data, encoding: .utf8) else { return nil }
            return ThirdPartySource(
                name: item.name,
                kind: "script",
                template: "",
                headers: ["quality": "320k"],
                script: script,
                enabled: true
            )
        }
    }
}
