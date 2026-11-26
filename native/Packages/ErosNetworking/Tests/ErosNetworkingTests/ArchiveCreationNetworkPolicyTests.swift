import Foundation
import Testing
import ErosCore
import ErosNetworking

struct ArchiveCreationNetworkPolicyTests {
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
    private let parsing = ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid")

    private func request(url: String = "https://ex.example.invalid/archiver.php?gid=42&token=synthetic",
                         body: String = "dltype=org&dlcheck=Download%20Original%20Archive") -> HTTPRequest {
        HTTPRequest(id: UUID(), scope: scope, url: URL(string: url)!, method: .post,
                    headers: ["Accept": "text/html", "Content-Type": "application/x-www-form-urlencoded"],
                    body: Data(body.utf8))
    }

    @Test func archiveWriteRequiresSeparateCapability() throws {
        let normal = NetworkPolicy(parsing: parsing)
        #expect(throws: AppError.accessDenied) { try normal.validate(request()) }
        let enabled = NetworkPolicy(parsing: parsing, allowArchiveWrite: true)
        try enabled.validate(request())
    }

    @Test func onlyExactOwnerBoundFormIsAllowed() throws {
        let enabled = NetworkPolicy(parsing: parsing, allowArchiveWrite: true)
        for candidate in [
            request(body: "dltype=org&dlcheck=Download%20Resample%20Archive"),
            request(body: "dltype=org&dlcheck=Download%20Original%20Archive&extra=1"),
            request(body: "dltype=org&dltype=res&dlcheck=Download%20Original%20Archive"),
            request(url: "https://ex.example.invalid/archiver.php?gid=42&gid=42&token=synthetic"),
            request(url: "https://evil.invalid/archiver.php?gid=42&token=synthetic")
        ] {
            #expect(throws: (any Error).self) { try enabled.validate(candidate) }
        }
        try enabled.validate(request(body: "dltype=res&dlcheck=Download%20Resample%20Archive"))
    }
}
