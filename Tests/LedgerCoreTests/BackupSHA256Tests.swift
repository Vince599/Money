import Foundation
import Testing
@testable import LedgerCore

@Suite("Backup SHA-256 standard vectors")
struct BackupSHA256Tests {
    // RFC 6234 section 8.5 supplies the abc, 56-byte and million-a vectors.
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    ])
    func standardVectors(_ input: String, _ digest: String) {
        #expect(BackupSHA256.hex(Data(input.utf8)) == digest)
    }

    @Test func millionA() {
        #expect(BackupSHA256.hex(Data(repeating: 97, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
