// Checks download/Taby.dmg against download/version.json (sha256 + Ed25519 signature).
// Run from the repo root: swift mac/scripts/verify-download.swift
import CryptoKit
import Foundation

let publicKey = "99Rh2ragLF1JyXK7pwWAywZ5tGKopMwn+7pMmX6xZP4="
let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "download/version.json"))) as! [String: Any]
var ok = true
for name in ["download/Taby.dmg", "download/Lumi.dmg"] {
  let dmg = try Data(contentsOf: URL(fileURLWithPath: name))
  let sha = SHA256.hash(data: dmg).map { String(format: "%02x", $0) }.joined()
  let match = sha == (info["sha256"] as! String).lowercased()
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey)!)
  let msg = Data("\(info["build"]!)\n\(info["commit"]!)\n\(sha)".utf8)
  let sig = key.isValidSignature(Data(base64Encoded: info["signature"] as! String)!, for: msg)
  print("\(name) sha match: \(match) sig ok: \(sig)")
  ok = ok && match && sig
}
exit(ok ? 0 : 1)
