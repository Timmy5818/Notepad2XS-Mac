// 用 Apple CryptoKit 獨立驗證 Notepad2XS AES-GCM v1 密文（不使用專案的 GCM 程式碼）
import Foundation
import CryptoKit
import CommonCrypto

func pbkdf2(_ password: String, _ salt: Data, _ rounds: UInt32) -> SymmetricKey {
    var key = [UInt8](repeating: 0, count: 32)
    let pw = Array(password.utf8)
    _ = salt.withUnsafeBytes { s in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                             s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, 32)
    }
    return SymmetricKey(data: key)
}

func open(_ text: String, _ password: String) throws -> String {
    let marker = "nb2XSAeSGcMveR1"
    let wire = Data(base64Encoded: String(text.dropFirst(marker.count)))!
    let header = wire.prefix(16), salt = wire.subdata(in: 16..<32), nonce = wire.subdata(in: 32..<44)
    let body = wire.subdata(in: 44..<(wire.count - 16)), tag = wire.suffix(16)
    let rounds = header.subdata(in: header.startIndex + 10..<header.startIndex + 14).withUnsafeBytes { $0.load(as: UInt32.self) }
    let aad = Data(marker.utf8) + header + salt
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
    let plain = try AES.GCM.open(box, using: pbkdf2(password, salt, rounds), authenticating: aad)
    return String(decoding: plain, as: UTF8.self)
}

let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
var fails = 0
for (c, p, t, name) in [("cipher", "password", "plain", "多區塊 ASCII"), ("cipherUni", "passwordUni", "plainUni", "Unicode＋NUL")] {
    let ok = (try? open(j[c]!, j[p]!)) == j[t]!
    print(ok ? "✓" : "✗", "CryptoKit 獨立解密專案產生的 AES 密文（\(name)）")
    if !ok { fails += 1 }
}
exit(fails == 0 ? 0 : 1)
