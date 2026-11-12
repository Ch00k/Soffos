import Foundation
import Testing
@testable import SpotifyKit

@Suite struct TokenStorageTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("soffos-tokens-\(UUID().uuidString).json")

    /// Writes data to file storage, reads it back, checks only the user can read the file, then deletes it.
    @Test func fileStorageRoundTripsWithOwnerOnlyPermissions() throws {
        let storage = TokenStorage.file(url)
        defer { try? FileManager.default.removeItem(at: url) }

        storage.write(Data("first".utf8))
        storage.write(Data("second".utf8))

        #expect(storage.read() == Data("second".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        storage.delete()

        #expect(storage.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A token store backed by a file starts signed in when the file holds tokens, and signing out removes the file.
    @Test func tokenStoreLoadsFromFileAndSignOutRemovesIt() async throws {
        let tokens = SpotifyTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        try JSONEncoder().encode(tokens).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SpotifyTokenStore(storage: .file(url))

        #expect(await store.isSignedIn)
        #expect(try await store.accessToken(clientID: "client") == "access")

        await store.signOut()

        #expect(await !store.isSignedIn)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
