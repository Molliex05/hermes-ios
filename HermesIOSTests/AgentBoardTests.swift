import XCTest
@testable import HermesIOSCore

final class AgentBoardTests: XCTestCase {
    private let json = """
    {"version":1,"boards":{
      "personnel":{"title":"Aujourd'hui","focus":"Quart de jour jusqu'à 15 h","ask":"Qu'est-ce qui m'attend demain ?",
        "updated_at":"2026-10-29T10:00:00+00:00","expires_at":"2026-10-29T14:00:00Z",
        "items":[{"text":"Barbier","time":"13:45","detail":"Don Barbero","icon":"scissors","tone":"Positive"},
                 {"text":""},{"text":"Souper chez Julie","time":"18:30"}]},
      "noriven":{"title":"Serveur","items":"pas une liste"},
      "":{"title":"sans profil"}}}
    """

    func testABoardKeepsWhatItShowsAndDropsWhatItCannot() throws {
        let boards = try AgentBoards.decode(Data(json.utf8))
        XCTAssertEqual(Set(boards.boards.keys), ["personnel", "noriven"], "a board with no profile is left out")
        let board = try XCTUnwrap(boards.boards["personnel"])
        XCTAssertEqual(board.title, "Aujourd'hui"); XCTAssertEqual(board.focus, "Quart de jour jusqu'à 15 h")
        XCTAssertEqual(board.items.map(\.text), ["Barbier", "Souper chez Julie"], "an empty line is dropped")
        XCTAssertEqual(board.items[0].tone, "positive", "lower case"); XCTAssertEqual(board.items[0].icon, "scissors")
        XCTAssertNotNil(board.updatedAt); XCTAssertNotNil(board.expiresAt)
        XCTAssertTrue(boards.boards["noriven"]?.isEmpty ?? false, "a malformed list is an empty board, not an error")
    }

    func testABoardGoesStaleAtItsExpiry() throws {
        let board = try XCTUnwrap(AgentBoards.decode(Data(json.utf8)).boards["personnel"])
        let expiry = try XCTUnwrap(board.expiresAt)
        XCTAssertFalse(board.isExpired(at: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(board.isExpired(at: expiry))
        XCTAssertFalse(AgentBoard(title: "x").isExpired(), "no expiry: it stays")
    }

    func testTheBoardIsBoundedAndNotAnObjectIsRefused() throws {
        let many = (1...9).map { "{\"text\":\"ligne \($0)\"}" }.joined(separator: ",")
        let board = try XCTUnwrap(AgentBoards.decode(Data("{\"boards\":{\"p\":{\"items\":[\(many)],\"title\":\"\(String(repeating: "T", count: 90))\"}}}".utf8)).boards["p"])
        XCTAssertEqual(board.items.count, AgentBoard.maxItems); XCTAssertEqual(board.title.count, 40)
        XCTAssertThrowsError(try AgentBoards.decode(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try AgentBoards.decode(Data("{\"boards\":[]}".utf8)))
    }

    func testTheCalendarAgendaComesWithItsExactMoments() throws {
        let data = Data("""
        {"boards":{},"agendas":{"personnel":{"title":"Aujourd’hui","expires_at":"2026-10-29T12:00:00-04:00",
          "items":[{"text":"Demain matin","time":"09:00","at":"2026-10-30T09:00:00-04:00","detail":"Demain · Personnel"},{"text":"Sans moment","time":"10:00"}]},
          "libre":{"title":"Aujourd’hui","items":[]}}}
        """.utf8)
        let boards = try AgentBoards.decode(data)
        XCTAssertEqual(Set(boards.agendas.keys), ["personnel", "libre"])
        XCTAssertEqual(boards.agendas["personnel"]?.items.first?.at, ISO8601DateFormatter().date(from: "2026-10-30T09:00:00-04:00"))
        XCTAssertNil(boards.agendas["personnel"]?.items.last?.at)
        XCTAssertTrue(boards.agendas["libre"]?.items.isEmpty ?? false, "a free day is present and empty")
        XCTAssertTrue(try AgentBoards.decode(Data("{\"boards\":{}}".utf8)).agendas.isEmpty, "a server without agendas is fine")
    }

    func testTheStoreKeepsAGoodBoardWhenTheNextOneIsBroken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNotNil(AgentBoardStore.write(Data(json.utf8), to: directory))
        XCTAssertNil(AgentBoardStore.write(Data("nope".utf8), to: directory))
        XCTAssertEqual(AgentBoardStore.read(from: directory)?.boards["personnel"]?.title, "Aujourd'hui")
        AgentBoardStore.clear(from: directory)
        XCTAssertNil(AgentBoardStore.read(from: directory))
    }

    func testSharedItemsWaitForTheAppAndAreTakenOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        XCTAssertTrue(ShareInbox.add(SharedItem(profile: "personnel", text: "https://www.centris.ca/fr/x", note: "Ajoute à la veille", createdAt: now), to: directory))
        XCTAssertTrue(ShareInbox.add(SharedItem(profile: "noriven", text: "Une note", createdAt: now.addingTimeInterval(-3 * 86_400)), to: directory))
        let taken = ShareInbox.take(from: directory, now: now)
        XCTAssertEqual(taken.map(\.profile), ["personnel"], "a share two days old is forgotten")
        XCTAssertEqual(taken[0].message, "Ajoute à la veille\n\nhttps://www.centris.ca/fr/x")
        XCTAssertTrue(ShareInbox.take(from: directory, now: now).isEmpty, "taken once")
        for index in 0..<14 { ShareInbox.add(SharedItem(id: "\(index)", profile: "p", text: "t"), to: directory) }
        XCTAssertEqual(ShareInbox.read(from: directory).count, ShareInbox.capacity)
        XCTAssertEqual(ShareInbox.read(from: directory).last?.id, "13", "the newest are kept")
    }

    func testTheProfileListRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        SharedProfiles.write([SharedProfile(name: "personnel", title: "Jarvis"), SharedProfile(name: "noriven", title: "Hermès")], to: directory)
        XCTAssertEqual(SharedProfiles.read(from: directory).map(\.title), ["Jarvis", "Hermès"])
    }
}
