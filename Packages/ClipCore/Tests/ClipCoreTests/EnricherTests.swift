import Foundation
import Synchronization
import Testing

@testable import ClipCore

// Proves the Enricher saves what the decoder returns, asks it once per item however many cards
// ask at the same time, and never reads the bytes of a text. The decoder is a closure here (the
// real one needs AppKit); it counts its calls and returns a fixed preview. The link tests cover
// the one thing in Yank that goes on the network: the fetch is fake (see FakeLinkFetcher), so
// they run offline and count exactly which addresses were asked for: none while link previews
// are off, none ever for a local address, and one for a public link, whose title and icon then
// land on the item.
struct EnricherTests {
    let folder = TemporaryFolder()

    @Test func savesThePreviewAndDecodesEachItemOnce() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let calls = Mutex(0)
        let enricher = Enricher(store: store) { item, data in
            calls.withLock { $0 += 1 }
            // Hold on, so the second caller arrives while the first is still decoding.
            try? await Task.sleep(for: .milliseconds(50))
            return CardPreview(
                thumbnail: CardThumbnail(clipboardItemId: item.id, png: data[0].data, width: 1, height: 1),
                detail: "decoded")
        }
        let item = try await store.save(
            CapturedCopy(data: [.png([4, 2])], sourceApp: nil, copiedAt: .now))
        async let first = enricher.enrich(item)
        async let second = enricher.enrich(item)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(calls.withLock { $0 } == 1)
        #expect(try await store.thumbnail(for: item.id)?.png == Data([4, 2]))
        #expect(try await store.items(limit: 1).first?.cardDetail == "decoded")
        // Done: the next ask decodes again (a thumbnail lost to a corrupt row, say).
        try await enricher.enrich(item)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func textsAndLinksAreNotDecoded() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let enricher = Enricher(store: store) { _, _ in
            Issue.record("a text must not be decoded")
            return nil
        }
        let item = try await store.save(
            CapturedCopy(data: [.text("plain")], sourceApp: nil, copiedAt: .now))
        #expect(try await enricher.enrich(item) == nil)
    }

    // The words an image recognizer returns land on the item and in the search index; an
    // item with no words, or no image, is left alone.
    @Test func wordsReadFromAnImageAreSearchable() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let enricher = Enricher(
            store: store, makePreview: { _, _ in nil },
            recognizeText: { data in data[0].data == Data([4, 2]) ? "Quarterly revenue" : nil })
        let picture = try await store.save(
            CapturedCopy(data: [.png([4, 2])], sourceApp: nil, copiedAt: .now))
        let blank = try await store.save(CapturedCopy(data: [.png([0])], sourceApp: nil, copiedAt: .now))
        try await enricher.recognizeText(in: picture)
        try await enricher.recognizeText(in: blank)
        let found = try await store.search("revenue", limit: 10)
        #expect(found?.map(\.id) == [picture.id])
        #expect(found?.first?.imageText == "Quarterly revenue")
    }

    // Copying the same picture again moves the item up; its thumbnail and its words are still
    // right, so the capture path must not decode or read it a second time.
    @Test func aRepeatCopyIsNotDecodedOrReadAgain() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let decodes = Mutex(0)
        let reads = Mutex(0)
        let enricher = Enricher(
            store: store,
            makePreview: { item, data in
                decodes.withLock { $0 += 1 }
                return CardPreview(
                    thumbnail: CardThumbnail(clipboardItemId: item.id, png: data[0].data, width: 1, height: 1)
                )
            },
            recognizeText: { _ in
                reads.withLock { $0 += 1 }
                return "words"
            })
        let copy = CapturedCopy(data: [.png([4, 2])], sourceApp: nil, copiedAt: .now)
        await enricher.enrichInBackground(try await store.save(copy)).value
        await enricher.enrichInBackground(try await store.save(copy)).value
        #expect(decodes.withLock { $0 } == 1)
        #expect(reads.withLock { $0 } == 1)
    }

    func linkCopy(_ address: String) -> CapturedCopy {
        CapturedCopy(
            data: [.text(address), .url(address)],
            sourceApp: SourceApp(bundleId: "com.apple.Safari", name: "Safari"), copiedAt: .now)
    }

    /// An Enricher with the fake web, thumbnails switched off, and the given setting.
    @MainActor func enricher(_ store: Store, web: FakeLinkFetcher, previews: Bool = true) -> Enricher {
        Enricher(
            store: store, makePreview: { _, _ in nil }, linkFetcher: web, linkPreviewsEnabled: { previews })
    }

    @MainActor @Test func aPublicLinkIsFetchedOnceAndGetsItsTitleAndIcon() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let web = FakeLinkFetcher()
        let item = try await store.save(linkCopy("https://example.com/page"))
        let preview = try await enricher(store, web: web).enrich(item)
        #expect(web.fetched == [URL(string: "https://example.com/page")!])
        #expect(preview?.linkPageTitle == "Example Domain")
        // The title is on the item, in the search index, and the icon is the card's thumbnail.
        let found = try await store.search("Example Domain", limit: 10)
        #expect(found?.map(\.id) == [item.id])
        #expect(found?.first?.linkPageTitle == "Example Domain")
        #expect(try await store.thumbnail(for: item.id)?.width == 32)
    }

    // Opening a page can use up a one-time link, so copying the same link again must not open
    // it a second time once its title is saved.
    @MainActor @Test func aRepeatCopyOfAFetchedLinkIsNotFetchedAgain() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let web = FakeLinkFetcher()
        let enricher = enricher(store, web: web)
        _ = try await enricher.enrich(try await store.save(linkCopy("https://example.com/once")))
        _ = try await enricher.enrich(try await store.save(linkCopy("https://example.com/once")))
        #expect(web.fetched.count == 1)
    }

    @MainActor @Test func nothingIsFetchedWhileLinkPreviewsAreOff() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let web = FakeLinkFetcher()
        let item = try await store.save(linkCopy("https://example.com/"))
        let preview = try await enricher(store, web: web, previews: false).enrich(item)
        #expect(web.fetched.isEmpty)
        #expect(preview == nil)
    }

    // A link to a router, a development server or a Bonjour name is never fetched, with
    // previews on, however it was copied (URL type or plain text alone).
    @MainActor
    @Test(arguments: [
        "http://192.168.1.1/admin", "http://localhost:3000/", "http://[::1]/", "http://nas.local/",
    ])
    func aLocalAddressIsNeverFetched(address: String) async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let web = FakeLinkFetcher()
        let typed = try await store.save(linkCopy(address))
        let plain = try await store.save(
            CapturedCopy(data: [.text(address + "?plain")], sourceApp: nil, copiedAt: .now))
        #expect(plain.kind == .link)
        let enricher = enricher(store, web: web)
        _ = try await enricher.enrich(typed)
        _ = try await enricher.enrich(plain)
        #expect(web.fetched.isEmpty)
    }
}
