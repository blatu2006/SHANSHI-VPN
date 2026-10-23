import CryptoKit
import Darwin
import Foundation

struct LocalCredentials: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

enum LocalCredentialError: Error, LocalizedError {
    case invalidKey
    case invalidEncryptedValue

    var errorDescription: String? {
        switch self {
        case .invalidKey: "本地凭据密钥格式无效"
        case .invalidEncryptedValue: "本地加密凭据格式无效"
        }
    }
}

/// Stores credentials in an encrypted file inside the app's sandbox so saving
/// or loading a VPN profile never invokes system credential-storage APIs.
/// The random AES key and encrypted records are separate files protected by
/// the app sandbox and owner-only filesystem permissions.
enum LocalCredentialStore {
    private static let keyFileName = "credentials.key"

    static func load(profileID: UUID) throws -> LocalCredentials? {
        let recordURL = try directoryURL(create: false)?.appendingPathComponent(recordName(profileID))
        guard let recordURL, FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let key = try loadKey(create: false)
        let encrypted = try Data(contentsOf: recordURL)
        return try decrypt(encrypted, using: key)
    }

    static func save(_ credentials: LocalCredentials, profileID: UUID) throws {
        let directory = try directoryURL(create: true)!
        let key = try loadKey(create: true)
        let combined = try encrypt(credentials, using: key)
        let recordURL = directory.appendingPathComponent(recordName(profileID))
        try combined.write(to: recordURL, options: .atomic)
        applyOwnerOnlyPermissions(to: recordURL, directory: false)
    }

    static func delete(profileID: UUID) throws {
        guard let directory = try directoryURL(create: false) else { return }
        let recordURL = directory.appendingPathComponent(recordName(profileID))
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        try FileManager.default.removeItem(at: recordURL)
    }

    private static func loadKey(create: Bool) throws -> SymmetricKey {
        guard let directory = try directoryURL(create: create) else {
            throw LocalCredentialError.invalidKey
        }
        let keyURL = directory.appendingPathComponent(keyFileName)
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw LocalCredentialError.invalidKey }
            return SymmetricKey(data: data)
        }
        guard create else { throw LocalCredentialError.invalidKey }
        return try createKey(at: keyURL)
    }

    static func createKey(at keyURL: URL) throws -> SymmetricKey {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        try data.write(to: keyURL, options: .atomic)
        applyOwnerOnlyPermissions(to: keyURL, directory: false)
        return SymmetricKey(data: data)
    }

    private static func directoryURL(create: Bool) throws -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("NLVC VPN/Credentials", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard create else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            applyOwnerOnlyPermissions(to: directory, directory: true)
        }
        return directory
    }

    private static func recordName(_ profileID: UUID) -> String {
        "\(profileID.uuidString.lowercased()).credentials"
    }

    static func encrypt(_ credentials: LocalCredentials, using key: SymmetricKey) throws -> Data {
        let cleartext = try JSONEncoder().encode(credentials)
        let encrypted = try AES.GCM.seal(cleartext, using: key)
        guard let combined = encrypted.combined else {
            throw LocalCredentialError.invalidEncryptedValue
        }
        return combined
    }

    static func decrypt(_ encrypted: Data, using key: SymmetricKey) throws -> LocalCredentials {
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let cleartext = try? AES.GCM.open(box, using: key),
              let credentials = try? JSONDecoder().decode(LocalCredentials.self, from: cleartext) else {
            throw LocalCredentialError.invalidEncryptedValue
        }
        return credentials
    }

    private static func applyOwnerOnlyPermissions(to url: URL, directory: Bool) {
        let mode: mode_t = directory ? 0o700 : 0o600
        url.withUnsafeFileSystemRepresentation { path in
            if let path { _ = chmod(path, mode) }
        }
    }
}
