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

    func testTheWeatherComesWithItsHoursDaysAndSun() throws {
        let data = Data("""
        {"boards":{},"weather":{"place":"Saint-Constant","temp":8,"feels":5,"wind":14,"summary":"Couvert","symbol":"cloud.fill",
          "hours":[{"at":"2026-10-29T10:00:00-04:00","temp":8,"symbol":"cloud.fill","rain":10},{"temp":9}],
          "days":[{"date":"2026-10-29","summary":"Pluie","symbol":"cloud.rain.fill","high":10,"low":3,"rain":40,"sunrise":"2026-10-29T07:17","sunset":"2026-10-29T17:48"},{"date":"2026-10-30","high":7}],
          "expires_at":"2026-10-29T11:50:00-04:00"}}
        """.utf8)
        let weather = try XCTUnwrap(AgentBoards.decode(data).weather)
        XCTAssertEqual(weather.temp, 8); XCTAssertEqual(weather.feels, 5); XCTAssertEqual(weather.place, "Saint-Constant")
        XCTAssertEqual(weather.hours.count, 1, "an hour with no moment is left out")
        XCTAssertEqual(weather.days.count, 1, "a day with no low is left out")
        let day = try XCTUnwrap(weather.days.first)
        XCTAssertEqual(day.high, 10); XCTAssertEqual(day.rain, 40)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: try XCTUnwrap(day.sunset))
        XCTAssertEqual(parts.hour, 17); XCTAssertEqual(parts.minute, 48)
        XCTAssertFalse(weather.isExpired(at: ISO8601DateFormatter().date(from: "2026-10-29T11:00:00-04:00")!))
        XCTAssertTrue(weather.isExpired(at: ISO8601DateFormatter().date(from: "2026-10-29T12:00:00-04:00")!))
        XCTAssertNil(try AgentBoards.decode(Data("{\"boards\":{},\"weather\":{\"place\":\"x\"}}".utf8)).weather, "no temperature, nothing to draw")
        XCTAssertNil(try AgentBoards.decode(Data("{\"boards\":{}}".utf8)).weather)
    }

    func testASeenBoardStaysClearedUntilTheAgentWritesAnotherOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(AgentBoards.decode(Data(#"{"boards":{"p":{"title":"T","items":[{"text":"Colis"}],"updated_at":"2026-10-29T10:00:00-04:00"}}}"#.utf8)).boards["p"])
        let same = try XCTUnwrap(AgentBoards.decode(Data(#"{"boards":{"p":{"title":"T","items":[{"text":"Colis"}],"updated_at":"2026-10-29T10:00:00-04:00"}}}"#.utf8)).boards["p"])
        let later = try XCTUnwrap(AgentBoards.decode(Data(#"{"boards":{"p":{"title":"T","items":[{"text":"Colis"}],"updated_at":"2026-10-29T11:00:00-04:00"}}}"#.utf8)).boards["p"])
        XCTAssertTrue(BoardDismissals.read(from: directory).isEmpty)
        BoardDismissals.dismiss(profile: "p", signature: first.signature, to: directory)
        XCTAssertEqual(BoardDismissals.read(from: directory)["p"], same.signature, "downloaded again, it is the same board")
        XCTAssertNotEqual(BoardDismissals.read(from: directory)["p"], later.signature, "a new write shows again")
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

    func testAShareIsRemovedByIdAndALateOneSurvives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ShareInbox.add(SharedItem(id: "a", profile: "p", text: "un"), to: directory)
        let seen = ShareInbox.read(from: directory)
        ShareInbox.add(SharedItem(id: "b", profile: "p", text: "deux"), to: directory)      // the share sheet adds while the app works
        ShareInbox.remove(ids: Set(seen.map(\.id)), from: directory)
        XCTAssertEqual(ShareInbox.read(from: directory).map(\.id), ["b"])
    }

    func testAnOldBoardWithNoExpiryGoesStaleAndTwinsGetDistinctIds() throws {
        let now = Date()
        XCTAssertTrue(AgentBoard(title: "x", items: [.init(text: "a")], updatedAt: now.addingTimeInterval(-25 * 3600)).isExpired(at: now))
        XCTAssertFalse(AgentBoard(title: "x", items: [.init(text: "a")], updatedAt: now.addingTimeInterval(-3600)).isExpired(at: now))
        let data = Data("""
        {"boards":{"p":{"items":[{"text":"Standup","time":"09:00","at":"2026-10-29T09:00:00-04:00","until":"2026-10-29T09:30:00-04:00"},
                                 {"text":"Standup","time":"09:00","at":"2026-10-30T09:00:00-04:00"}]}}}
        """.utf8)
        let items = try XCTUnwrap(AgentBoards.decode(data).boards["p"]).items
        XCTAssertNotEqual(items[0].id, items[1].id, "the same title at the same time on two days")
        XCTAssertNotNil(items[0].until); XCTAssertNil(items[1].until)
        XCTAssertNoThrow(try AgentBoards.decode(Data("{\"agendas\":{\"p\":{\"items\":[]}}}".utf8)), "agendas alone are fine")
        XCTAssertThrowsError(try AgentBoards.decode(Data("{\"version\":1}".utf8)))
    }

    func testTheProfileListRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        SharedProfiles.write([SharedProfile(name: "personnel", title: "Jarvis"), SharedProfile(name: "noriven", title: "Hermès")], to: directory)
        XCTAssertEqual(SharedProfiles.read(from: directory).map(\.title), ["Jarvis", "Hermès"])
    }
}
