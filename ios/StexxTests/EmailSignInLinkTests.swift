import Foundation
import Testing
@testable import Stexx

struct EmailSignInLinkTests {
    @Test func readsTheTokenFromAUniversalLink() throws {
        let url = try #require(URL(string: "https://stexx.gay/auth/email?token=abc_DEF-123"))
        #expect(EmailSignInLink.token(from: url) == "abc_DEF-123")
    }

    @Test func acceptsATrailingSlashAndOtherQueryItems() throws {
        let url = try #require(URL(string: "https://stexx.gay/auth/email/?utm=x&token=t0k3n"))
        #expect(EmailSignInLink.token(from: url) == "t0k3n")
    }

    @Test(arguments: [
        "https://stexx.gay/auth/email",
        "https://stexx.gay/auth/email?token=",
        "https://stexx.gay/auth/emails?token=abc",
        "https://stexx.gay/auth/email/extra?token=abc",
        "https://stexx.gay/?token=abc",
    ])
    func ignoresAnythingElse(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(EmailSignInLink.token(from: url) == nil)
    }
}
