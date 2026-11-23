import Foundation
import GRDB
import Synchronization
import Testing

@testable import ClipCore

struct CleanTextTests {
    @Test func stripsColourCodesAndPrompts() {
        let copied =
            "$ git status\n\u{1B}[32mOn branch main\u{1B}[0m\nuser@mac:~/Dev$ ls -la\n% make\n❯ swift test"
        #expect(CleanText.clean(copied) == "git status\nOn branch main\nls -la\nmake\nswift test")
    }

    // A dollar inside a line is not a prompt, and a line without one is left as it was.
    @Test func leavesOtherTextAlone() {
        #expect(CleanText.clean("costs $ 5\n  indented") == "costs $ 5\n  indented")
        #expect(CleanText.clean("{not json") == "{not json")
    }

    // Keys stay in their order and numbers as written, which JSONSerialization would not keep.
    @Test func prettyPrintsJSON() {
        #expect(
            CleanText.clean(#"  {"b":1.50,"a":[1, {"s":"x, {y}: \"z\""}],"e":{}}"#) == """
                {
                  "b": 1.50,
                  "a": [
                    1,
                    {
                      "s": "x, {y}: \\"z\\""
                    }
                  ],
                  "e": {}
                }
                """)
    }

    // A prompt in front of JSON is stripped first, so the JSON is then found.
    @Test func cleansAPromptBeforeJSON() {
        #expect(CleanText.clean("$ [1,2]") == "[\n  1,\n  2\n]")
    }
}

struct CredentialsTests {
    @Test(arguments: [
        "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx",
        "token ghp_" + String(repeating: "a", count: 36),
        "github_pat_11ABCDEFG0123456789abcdef_more",
        "aws_access_key_id = AKIAIOSFODNN7EXAMPLE",
        "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----",
    ])
    func findsSecrets(text: String) {
        #expect(Credentials.detect(text))
    }

    // Look-alikes: too short, inside a word, or a public key.
    @Test(arguments: [
        "sk-short", "task-list-for-the-week-and-more-words", "ghp_tooShort", "AKIA1234", "eyJ.notajwt",
        "-----BEGIN PUBLIC KEY-----", "risk-free returns",
    ])
    func ignoresLookAlikes(text: String) {
        #expect(!Credentials.detect(text))
    }
}

struct CategoryTests {
    let folder = TemporaryFolder()

    func copy(_ text: String) -> CapturedCopy {
        CapturedCopy(data: [.text(text)], sourceApp: nil, copiedAt: .now)
    }

    @Test func startsWithTheBuiltInList() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let categories = try await store.categories()
        #expect(
            categories.map(\.name) == [
                "Code", "Command", "Error or log", "Credential", "Address or contact", "Prose", "Data",
                "Other",
            ])
        #expect(categories.first { $0.id == ItemCategory.otherId }?.name == "Other")
        #expect(categories.first { $0.id == ItemCategory.credentialId }?.name == "Credential")
    }

    // Items point at the category by id, so a rename keeps them; a taken or blank name is refused.
    @Test func renamingKeepsItsItems() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let item = try await store.save(copy("print(1)"))
        try await store.setCategory(1, for: item.id)
        try await store.updateCategory(id: 1, name: "Snippets", about: "Bits of code")
        try await store.updateCategory(id: 2, name: "snippets", about: "Taken name")
        try await store.updateCategory(id: 3, name: "  ", about: "Blank name")
        let categories = try await store.categories()
        #expect(categories.map(\.name).prefix(3) == ["Snippets", "Command", "Error or log"])
        #expect(categories[1].about == "Taken name")
        let filtered = try await store.search("print", matching: ItemFilter(categoryId: 1), limit: 10)
        #expect(filtered?.map(\.id) == [item.id])
    }

    @Test func removingMovesItsItemsToOther() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let item = try await store.save(copy("hello there"))
        try await store.setCategory(6, for: item.id)
        try await store.deleteCategory(id: 6)
        try await store.deleteCategory(id: ItemCategory.otherId)
        try await store.deleteCategory(id: ItemCategory.credentialId)
        let names = try await store.categories().map(\.name)
        #expect(!names.contains("Prose") && names.contains("Other") && names.contains("Credential"))
        #expect(try await store.items(limit: 1).first?.categoryId == ItemCategory.otherId)
    }

    // A changed list queues again everything not set by hand, and never a credential.
    @Test func aListChangeQueuesItemsNotSetByHand() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let byHand = try await store.save(copy("set by hand"))
        try await store.setCategory(6, for: byHand.id)
        let byModel = try await store.save(copy("labelled by the model"))
        let key = try await store.save(copy("sk-ant-abcdefghijklmnopqrstuvwxyz"))
        while let (item, _) = try await store.nextToLabel() {
            try await store.setLabels(categoryId: 7, language: "none", title: nil, for: item.id)
        }
        try await store.reorderCategories(ids: [2, 1, 3, 4, 5, 6, 7, 8])
        var queued: [Int64] = []
        while let (item, _) = try await store.nextToLabel() {
            queued.append(item.id)
            try await store.dropFromLabelQueue(itemId: item.id)
        }
        #expect(queued == [byModel.id])
        let items = try await store.items(limit: 10)
        #expect(items.first { $0.id == key.id }?.categoryId == ItemCategory.credentialId)
        #expect(items.first { $0.id == byHand.id }?.categoryId == 6)
    }

    // The model must never read a key: a queued text edited into one leaves the queue. An image
    // joins it once its words are read, unless the words are a key too.
    @Test func editsAndImageWordsKeepTheQueueRight() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let note = try await store.save(copy("draft note"))
        _ = try await store.replaceData(for: note.id, with: [.text("key AKIAIOSFODNN7EXAMPLE")])
        #expect(try await store.nextToLabel() == nil)
        #expect(try await store.items(limit: 1).first?.categoryId == ItemCategory.credentialId)
        let picture = try await store.save(CapturedCopy(data: [.png([1])], sourceApp: nil, copiedAt: .now))
        let secret = try await store.save(CapturedCopy(data: [.png([2])], sourceApp: nil, copiedAt: .now))
        #expect(try await store.nextToLabel() == nil)
        try await store.setPreview(CardPreview(imageText: "Quarterly revenue"), for: picture.id)
        try await store.setPreview(
            CardPreview(imageText: "ghp_" + String(repeating: "c", count: 36)), for: secret.id)
        let next = try await store.nextToLabel()
        #expect(next?.item.id == picture.id && next?.text == "Quarterly revenue")
        try await store.dropFromLabelQueue(itemId: picture.id)
        #expect(try await store.nextToLabel() == nil)
    }

    // A database from before labels: its texts are queued, pinned first, and its keys are
    // marked Credential without ever being queued.
    @Test func migrationSixQueuesTheHistory() async throws {
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.url.appending(path: "yank.sqlite").path)
        try Migrations.migrator.migrate(queue, upTo: "v5")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO pinboard (name, position) VALUES ('Keep', 0)")
            for (text, kind, pinned, imageText) in [
                ("old note", "text", false, nil), ("pinned note", "text", true, nil),
                ("AKIAIOSFODNN7EXAMPLE", "text", false, nil), ("", "image", false, "Quarterly revenue"),
                ("", "image", false, ""), ("https://a.example", "link", false, nil),
            ] as [(String, String, Bool, String?)] {
                try db.execute(
                    sql: """
                        INSERT INTO clipboardItem (kind, cardText, searchText, createdAt, copiedAt,
                            contentFingerprint, pinboardId, imageText)
                        VALUES (?, ?, ?, '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', ?, ?, ?)
                        """, arguments: [kind, text, text, UUID().uuidString, pinned ? 1 : nil, imageText])
            }
        }
        try queue.close()
        let store = try Store(folder: folder.url)
        var queued: [String] = []
        while let (_, text) = try await store.nextToLabel() {
            queued.append(text)
            let next = try #require(try await store.nextToLabel())
            try await store.dropFromLabelQueue(itemId: next.item.id)
        }
        #expect(queued.first == "pinned note")
        #expect(Set(queued) == ["pinned note", "old note", "Quarterly revenue"])
        let key = try await store.items(limit: 10).first { $0.cardText == "AKIAIOSFODNN7EXAMPLE" }
        #expect(key?.categoryId == ItemCategory.credentialId)
    }
}

struct LabellingTests {
    let folder = TemporaryFolder()

    @Test func labelsQueuedItemsButKeepsHandSetValues() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let seen = Mutex<[String]>([])
        let enricher = Enricher(
            store: store, makePreview: { _, _ in nil },
            askModel: { text, categories in
                seen.withLock { $0.append(text) }
                #expect(!categories.contains { $0.id == ItemCategory.credentialId })
                return Labels(
                    category: "Code", language: "Swift", title: "a function that adds two whole numbers")
            })
        let code = try await store.save(
            CapturedCopy(data: [.text("func add() {}")], sourceApp: nil, copiedAt: .now))
        let mine = try await store.save(
            CapturedCopy(data: [.text("let x = 1")], sourceApp: nil, copiedAt: .now))
        try await store.setLanguage("Python", for: mine.id)
        try await store.save(
            CapturedCopy(
                data: [.text("ghp_" + String(repeating: "b", count: 36))], sourceApp: nil, copiedAt: .now))
        await enricher.labelInBackground()?.value
        #expect(Set(seen.withLock { $0 }) == ["func add() {}", "let x = 1"])
        let items = try await store.items(limit: 10)
        let labelled = try #require(items.first { $0.id == code.id })
        #expect(labelled.categoryId == 1 && labelled.language == "Swift")
        // Six words at most, and only for code or long text.
        #expect(labelled.labelTitle == "a function that adds two whole")
        #expect(items.first { $0.id == mine.id }?.language == "Python")
    }

    // Off means no model call at all; the queue waits for the switch to come back on.
    @Test func switchedOffNeverCallsTheModel() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let on = Mutex(false)
        let calls = Mutex(0)
        let enricher = Enricher(
            store: store, makePreview: { _, _ in nil },
            askModel: { _, _ in
                calls.withLock { $0 += 1 }
                return Labels(category: "Prose", language: "none", title: "")
            }, labelsEnabled: { on.withLock { $0 } })
        try await store.save(CapturedCopy(data: [.text("hello")], sourceApp: nil, copiedAt: .now))
        await enricher.labelInBackground()?.value
        #expect(calls.withLock { $0 } == 0)
        on.withLock { $0 = true }
        await enricher.labelInBackground()?.value
        #expect(calls.withLock { $0 } == 1)
        #expect(try await store.items(limit: 1).first?.labelTitle == nil)
    }
}
