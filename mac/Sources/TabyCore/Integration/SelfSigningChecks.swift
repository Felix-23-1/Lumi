// Prüfungen der Selbst-Signatur: Entscheidung „schon signiert?“ aus einer
// codesign-Ausgabe, Zertifikat-SHA-1 aus find-identity und die argv-Listen
// (keine Shell, kein Passwort auf der Argumentliste, keine Vorfreigabe, kein --deep).
import Foundation

enum SelfSigningChecks {
  static let signedOutput = """
    Executable=/Applications/Lumi.app/Contents/MacOS/Taby
    Identifier=de.felix.taby
    Authority=Taby Local Signing
    Authority=Taby Local Signing
    TeamIdentifier=not set
    """
  static let adhocOutput = """
    Executable=/Applications/Lumi.app/Contents/MacOS/Taby
    Identifier=de.felix.taby
    Signature=adhoc
    TeamIdentifier=not set
    """
  static let hash = "3F2A9C1D7B8E4F5061A2B3C4D5E6F708192A3B4C"
  static let findOutput = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Taby Local Signing 2"
      2) \(hash) "Taby Local Signing"
         2 valid identities found
    """

  static var cases: [CheckCase] {
    [
      CheckCase("Selbst-Signatur: erkennt Lumi, das schon mit „Taby Local Signing“ signiert ist") {
        try expect(SelfSigning.isSigned(codesignOutput: signedOutput), "signiert erkannt")
        try expect(!SelfSigning.isSigned(codesignOutput: adhocOutput), "ad hoc ist nicht signiert")
        try expect(!SelfSigning.isSigned(codesignOutput: ""), "leere Ausgabe")
        try expect(!SelfSigning.isSigned(codesignOutput: "Authority=Taby Local Signing 2"), "fremder Name")
      },
      CheckCase("Selbst-Signatur: SHA-1 nur bei exaktem Namen") {
        try expectEqual(SelfSigning.identityHash(findIdentityOutput: findOutput), hash)
        try expectEqual(SelfSigning.identityHash(findIdentityOutput: "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Taby Local Signing 2\""), nil)
        try expectEqual(SelfSigning.identityHash(findIdentityOutput: ""), nil)
      },
      CheckCase("Selbst-Signatur: Entscheidung – schon signiert, sonst signieren, sonst Grund") {
        let app = "/Applications/Lumi.app"
        try expectEqual(SelfSigning.plan(appPath: app, codesignOutput: signedOutput, certificateFound: false),
                        .alreadySigned)
        try expectEqual(SelfSigning.plan(appPath: app, codesignOutput: adhocOutput, certificateFound: false),
                        .sign(needsCertificate: true))
        try expectEqual(SelfSigning.plan(appPath: app, codesignOutput: adhocOutput, certificateFound: true),
                        .sign(needsCertificate: false))
        try expectEqual(SelfSigning.plan(appPath: "/Users/x/Downloads/Lumi.app", codesignOutput: adhocOutput,
                                         certificateFound: true), .notInApplications)
        try expectEqual(SelfSigning.plan(appPath: "/Applications/Lumi", codesignOutput: "", certificateFound: true),
                        .notInApplications)
      },
      CheckCase("Selbst-Signatur: argv-Listen – keine Vorfreigabe, nicht exportierbar, kein --deep") {
        let kc = "/Users/x/Library/Keychains/login.keychain-db"
        try expectEqual(SelfSigning.codesignInfoArgv(app: "/Applications/Lumi.app"),
                        ["-dv", "--verbose=2", "/Applications/Lumi.app"])
        try expectEqual(SelfSigning.findIdentityArgv(keychain: kc), ["find-identity", "-p", "codesigning", kc])
        try expectEqual(SelfSigning.signArgv(target: "/Applications/Lumi.app", keychain: kc, identityHash: hash),
                        ["--force", "--sign", hash, "--keychain", kc, "--timestamp=none", "/Applications/Lumi.app"])
        try expect(!SelfSigning.signArgv(target: "/x/taby-mcp", keychain: kc, identityHash: hash).contains("--deep"),
                   "kein --deep")
        let p12 = SelfSigning.pkcs12Argv(key: "k", cert: "c", p12: "p")
        try expectEqual(p12.last, "pass:", "leeres Passwort")
        try expect(!p12.contains { $0.hasPrefix("pass:") && $0 != "pass:" }, "kein Klartext-Passwort in argv")
        try expectEqual(SelfSigning.importArgv(p12: "p", keychain: kc),
                        ["import", "p", "-k", kc, "-P", "", "-x"])
        try expect(!SelfSigning.importArgv(p12: "p", keychain: kc).contains("-T"), "keine Vorfreigabe für codesign")
        try expectEqual(SelfSigning.verifyArgv(app: "/A.app"), ["--verify", "/A.app"])
        try expectEqual(SelfSigning.quarantineArgv(app: "/A.app"), ["-dr", "com.apple.quarantine", "/A.app"])
        try expect(SelfSigning.certificateConfig().contains("CN = Taby Local Signing"), "Zertifikatsname")
        try expect(SelfSigning.certificateConfig().contains("extendedKeyUsage = critical,codeSigning"), "Code-Signierung")
      },
      CheckCase("Selbst-Signatur: Werkzeug-Zeitlimit 120 s mit Hinweis auf den Schlüsselbund-Dialog") {
        try expectEqual(SelfSigning.toolTimeout, 120)
        try expect(SelfSigning.dialogHint.contains("Dialog von macOS"), "Hinweistext")
      },
    ]
  }
}
