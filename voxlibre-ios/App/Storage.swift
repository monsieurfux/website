import Foundation
import Security

/// Non-secret settings (selected ring, SN/FWID, recordings index) in UserDefaults.
final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults
    private let prefix: String

    init(defaults: UserDefaults = .standard, prefix: String = "voxlibre.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    func get(_ key: String) -> String {
        return defaults.string(forKey: prefix + key) ?? ""
    }

    func set(_ key: String, _ value: String) {
        defaults.set(value, forKey: prefix + key)
    }
}

/// BIND KEY / USER ID live in the Keychain, not in UserDefaults (the Android original used
/// plain SharedPreferences). `AfterFirstUnlock` keeps them readable while the phone is locked,
/// which background Bluetooth needs; `ThisDeviceOnly` keeps them out of backups/migrations.
final class KeychainStore: KeyValueStore {
    private let service: String

    init(service: String = "app.voxlibre.ios") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func get(_ key: String) -> String {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func set(_ key: String, _ value: String) {
        let base = baseQuery(key)
        if value.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Recordings live in the app's Documents folder (visible in the Files app, since the app
/// enables file sharing); the decoded-WAV cache lives in Caches and may be purged by iOS.
final class LocalFileStore: FileStore {
    private let fm = FileManager.default
    let documents: URL
    let caches: URL

    init() {
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    func url(for name: String) -> URL {
        return documents.appendingPathComponent(name)
    }

    func cacheURL(for name: String) -> URL {
        return caches.appendingPathComponent(name)
    }

    func list(suffix: String) -> [(name: String, size: Int64)] {
        guard let items = try? fm.contentsOfDirectory(atPath: documents.path) else { return [] }
        return items.filter { $0.hasSuffix(suffix) }.compactMap { name -> (name: String, size: Int64)? in
            let attrs = try? fm.attributesOfItem(atPath: url(for: name).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return (name: name, size: size)
        }
    }

    func read(name: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return [UInt8](data)
    }

    func write(name: String, data: [UInt8]) throws {
        try Data(data).write(to: url(for: name), options: .atomic)
    }

    func remove(name: String) {
        try? fm.removeItem(at: url(for: name))
        try? fm.removeItem(at: cacheURL(for: name))
    }
}
