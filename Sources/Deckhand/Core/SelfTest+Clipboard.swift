import AppKit

extension SelfTest {
    /// Clipboard history and pasting. Owned by the clipboard workstream.
    static func clipboard(_ check: Check) {
        check(ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Passwords"),
              "copies from Apple Passwords count as passwords")
        check(ClipboardWatcher.isPassword(types: ["org.nspasteboard.ConcealedType"], sourceApp: nil),
              "concealed type counts as password")
        check(!ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.microsoft.edgemac"),
              "plain copy is not a password")

        check("Translate this sentence".looksLikeProse && "привет".looksLikeProse, "prose is prefilled")
        check(!"77.88.8.8".looksLikeProse && !"me@example.com".looksLikeProse && !"https://a.b/c".looksLikeProse,
              "addresses and links are not prefilled")
    }
}
