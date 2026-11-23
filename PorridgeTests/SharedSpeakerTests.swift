import SwiftData
import XCTest
@testable import Porridge

/// Speakers of meetings in shared bowls: shared without links to people, linked on each device to its own people.
@MainActor
final class SharedSpeakerTests: XCTestCase {
    private func voice(_ hot: Int, size: Int = 8) -> [Float] {
        var v = [Float](repeating: 0.05, count: size)
        v[hot] = 1
        return VoiceMath.normalized(v)
    }

    private func speaker(_ id: String, _ name: String, voice: [Float]? = nil, profile: String? = nil) -> Speaker {
        Speaker(id: id, name: name, colorIndex: 0, voice: voice.map(VoiceMath.data(from:)), voiceSeconds: voice == nil ? nil : 30, profileID: profile)
    }

    func testSharedPayloadCarriesNoLinks() throws {
        let note = Note()
        note.speakers = [speaker("1", "Anna", voice: voice(0), profile: UUID().uuidString)]
        let payload = SharedNotePayload(note)
        let shared = try JSONDecoder().decode([Speaker].self, from: XCTUnwrap(payload.speakersData))
        XCTAssertNil(shared[0].profileID)
        XCTAssertEqual(shared[0].name, "Anna")
        XCTAssertNotNil(shared[0].voice)
    }

    func testSameMeetingSameFingerprintWhateverTheLinks() {
        let a = Note(), b = Note()
        b.id = a.id
        b.createdAt = a.createdAt
        b.updatedAt = a.updatedAt
        a.speakers = [speaker("1", "Anna", voice: voice(0), profile: UUID().uuidString)]
        b.speakers = [speaker("1", "Anna", voice: voice(0), profile: UUID().uuidString)]
        XCTAssertEqual(SharedNotePayload(a).fingerprint, SharedNotePayload(b).fingerprint)
    }

    func testOldPayloadWithLinksIsReadWithout() throws {
        let note = Note()
        note.speakers = [speaker("1", "Anna", profile: UUID().uuidString)]
        var payload = SharedNotePayload(note)
        payload.speakersData = note.speakersData
        let decoded = try XCTUnwrap(SharedNotePayload.decode(payload.encoded()))
        XCTAssertEqual(decoded.fingerprint, SharedNotePayload(note).fingerprint)
    }

    func testLinksByNameVoiceAndKeepsEarlierLink() throws {
        let context = try TestStore.context()
        let anna = VoiceProfile(name: "Anna", voice: voice(0), seconds: 60)
        let ben = VoiceProfile(name: "Ben Berger", voice: voice(1), seconds: 60)
        let cara = VoiceProfile(name: "Cara", voice: voice(2), seconds: 60)
        [anna, ben, cara].forEach(context.insert)
        let profiles = [anna, ben, cara]

        let incoming = [
            speaker("1", "anna", voice: voice(5)),          // known name (any case), other voice
            speaker("2", "Speaker 2", voice: voice(1)),     // unnamed, Ben's voice
            speaker("3", "Ben", voice: voice(1)),           // named elsewhere; Ben is taken by speaker 2 already
            speaker("4", "Carla", voice: voice(2)),         // named elsewhere, Cara's voice: linked, name stays
            speaker("5", "Speaker 5", voice: voice(6)),     // nobody known
        ]
        let linked = VoiceProfiles.link(incoming, previous: [], profiles: profiles)
        XCTAssertEqual(linked[0].profileID, anna.id.uuidString)
        XCTAssertEqual(linked[0].name, "anna")
        XCTAssertEqual(linked[1].profileID, ben.id.uuidString)
        XCTAssertEqual(linked[1].name, "Ben Berger")
        XCTAssertNil(linked[2].profileID)
        XCTAssertEqual(linked[3].profileID, cara.id.uuidString)
        XCTAssertEqual(linked[3].name, "Carla")
        XCTAssertNil(linked[4].profileID)
        XCTAssertEqual(linked[4].name, "Speaker 5")

        // The next version of the meeting comes without links: the earlier link stays while the name does.
        let again = VoiceProfiles.link(incoming.map { var s = $0; s.profileID = nil; return s }, previous: linked, profiles: profiles)
        XCTAssertEqual(again[3].profileID, cara.id.uuidString)
    }

    func testForeignLinkIsDropped() throws {
        let anna = VoiceProfile(name: "Anna", voice: voice(0), seconds: 60)
        let linked = VoiceProfiles.link([speaker("1", "Dora", profile: UUID().uuidString)], previous: [], profiles: [anna])
        XCTAssertNil(linked[0].profileID)
    }
}
