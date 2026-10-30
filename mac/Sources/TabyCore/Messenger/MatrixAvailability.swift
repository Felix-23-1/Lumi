// Ob die Matrix Rust SDK (Element-X-Schicht) in dieses Build gelinkt ist.
// TABY_MATRIX kommt nur aus Package.swift, wenn scripts/build-matrix-sdk.sh
// Vendor/MatrixSDK gebaut hat.
#if TABY_MATRIX
import MatrixSDK
#endif

public enum MatrixAvailability {
  public static var isAvailable: Bool {
    #if TABY_MATRIX
    // Trivialer FFI-Aufruf: beweist Linken und Laufzeit-Anbindung.
    return !sdkGitSha().isEmpty
    #else
    return false
    #endif
  }
}
