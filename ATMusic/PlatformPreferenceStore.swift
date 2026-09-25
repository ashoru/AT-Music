import SwiftUI
import Combine
import UIKit

/// 用户选择需要显示的平台。只控制入口可见性，不删除平台能力。
final class PlatformPreferenceStore: ObservableObject {
    static let shared = PlatformPreferenceStore()

    private static let key = "atmusic.enabledPlatforms.v1"
    private static let orderKey = "atmusic.platformOrder.v1"

    @Published private(set) var selectedRaw: Set<String>
    @Published var orderedRaw: [String]

    /// 仅隐藏页面顶部的平台切换控件，不影响平台启用状态或后台加载能力。
    static let hidePickerKey = "atmusic.hidePlatformPicker"

    var changes: AnyPublisher<Set<String>, Never> { $selectedRaw.eraseToAnyPublisher() }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        if saved.isEmpty {
            selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        } else {
            selectedRaw = Set(saved.map(Self.migrateRawValue))
        }
        orderedRaw = UserDefaults.standard.stringArray(forKey: Self.orderKey)?
            .map(Self.migrateRawValue) ?? []
        normalize()
        normalizeOrder()
    }

    var enabledSearchProviders: [SearchProvider] {
        let list = orderedSearchProviders.filter { selectedRaw.contains($0.rawValue) }
        return list.isEmpty ? [.netease] : list
    }

    var enabledLibraryProviders: [LibraryProvider] {
        enabledSearchProviders.compactMap { provider in
            LibraryProvider(rawValue: provider.rawValue)
        }
    }

    var summaryText: String {
        enabledSearchProviders.map(\.rawValue).joined(separator: " / ")
    }

    func isEnabled(_ provider: SearchProvider) -> Bool {
        selectedRaw.contains(provider.rawValue)
    }

    func isEnabled(_ provider: LibraryProvider) -> Bool {
        isEnabled(provider.searchProvider)
    }

    func set(_ provider: SearchProvider, enabled: Bool) {
        if enabled {
            selectedRaw.insert(provider.rawValue)
        } else if selectedRaw.count > 1 {
            selectedRaw.remove(provider.rawValue)
        }
        normalize()
        save()
    }

    func ensureVisible(_ provider: SearchProvider) -> SearchProvider {
        isEnabled(provider) ? provider : enabledSearchProviders.first ?? .netease
    }

    func ensureVisible(_ provider: LibraryProvider) -> LibraryProvider {
        isEnabled(provider) ? provider : enabledLibraryProviders.first ?? .netease
    }

    func resetToDefault() {
        selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        resetOrder()
        save()
    }

    func resetOrder() {
        orderedRaw = SearchProvider.allCases.map(\.rawValue)
        saveOrder()
        objectWillChange.send()
    }

    var orderedSearchProviders: [SearchProvider] {
        orderedRaw.compactMap(SearchProvider.init(rawValue:))
    }

    func moveProviders(from offsets: IndexSet, to destination: Int) {
        orderedRaw.move(fromOffsets: offsets, toOffset: destination)
        normalizeOrder()
        saveOrder()
        objectWillChange.send()
    }

    private func normalize() {
        let allowed = Set(SearchProvider.allCases.map(\.rawValue))
        selectedRaw = selectedRaw.intersection(allowed)
        if selectedRaw.isEmpty {
            selectedRaw = [SearchProvider.netease.rawValue]
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(selectedRaw), forKey: Self.key)
    }

    private func normalizeOrder() {
        let defaults = SearchProvider.allCases.map(\.rawValue)
        var result = orderedRaw.filter { defaults.contains($0) }
        for raw in defaults where !result.contains(raw) {
            result.append(raw)
        }
        orderedRaw = result
    }

    private func saveOrder() {
        UserDefaults.standard.set(orderedRaw, forKey: Self.orderKey)
    }

    private static func migrateRawValue(_ raw: String) -> String {
        raw == "网易云" ? SearchProvider.netease.rawValue : raw
    }
}

extension LibraryProvider {
    var searchProvider: SearchProvider {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        }
    }
}

extension SearchProvider {
    var songSource: SongSource {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        }
    }
}

extension SongSource {
    var searchProvider: SearchProvider? {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .local: return nil
        }
    }
}

struct PlatformPreferencePicker: View {
    @ObservedObject private var store = PlatformPreferenceStore.shared

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.orderedSearchProviders) { provider in
                Button {
                    ATMusicHaptics.select()
                    store.set(provider, enabled: !store.isEnabled(provider))
                } label: {
                    HStack(spacing: 12) {
                        if let imageName = provider.brandImageName {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: provider.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(provider.rawValue))
                                .font(ATMusicFont.appFont(14, .semibold))
                                .foregroundStyle(Color.atmusicLabel)
                                Text(LocalizedStringKey(store.isEnabled(provider) ? "已显示" : "已隐藏"))
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        Spacer()
                        Image(systemName: store.isEnabled(provider) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .atmusicSelectionForeground(selected: store.isEnabled(provider), accent: .atmusicAmber)
                    }
                    .padding(12)
                    .background {
                        ATMusicSelectableSurface(
                            selected: store.isEnabled(provider),
                            shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
