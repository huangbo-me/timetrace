import CommonCrypto
import CryptoKit
import Foundation

enum BackupError: LocalizedError {
    case unsupportedVersion, invalidFile, wrongPassword, encryptionFailed, unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "备份版本暂不支持，请更新时光落点后重试。"
        case .invalidFile: "无法读取此备份，文件格式不正确或已损坏。"
        case .wrongPassword: "密码不正确，或备份文件已损坏。"
        case .encryptionFailed: "无法加密备份，请重试。"
        case .unavailable: "本地存储暂不可用，请重新打开应用后重试。"
        }
    }
}

/// Version 1 uses PBKDF2-HMAC-SHA256 (600,000 rounds), a fresh 16-byte salt,
/// and AES-256-GCM. Passwords and plaintext are never written to disk.
enum BackupArchive {
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let salt: Data
        let sealed: Data
    }

    static func encrypt(_ snapshot: BackupSnapshot, password: String) throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.encryptionFailed }
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(snapshot), using: key)
        guard let combined = sealed.combined else { throw BackupError.encryptionFailed }
        return try JSONEncoder().encode(Envelope(format: "TimeTraceBackup", version: 1, salt: salt, sealed: combined))
    }

    static func decrypt(_ data: Data, password: String) throws -> BackupSnapshot {
        guard data.count <= 100 * 1_024 * 1_024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == "TimeTraceBackup", envelope.salt.count == 16 else {
            throw BackupError.invalidFile
        }
        guard envelope.version == 1 else { throw BackupError.unsupportedVersion }
        let key = try deriveKey(password: password, salt: envelope.salt)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key)
        } catch { throw BackupError.wrongPassword }
        guard let snapshot = try? JSONDecoder().decode(BackupSnapshot.self, from: plaintext) else {
            throw BackupError.invalidFile
        }
        guard snapshot.version == 1 else { throw BackupError.unsupportedVersion }
        return snapshot
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                bytes.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, bytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard result == kCCSuccess else { throw BackupError.encryptionFailed }
        return SymmetricKey(data: key)
    }
}
