import Foundation
import Observation
import Security
import SwiftData

/// A recording on the Plaud recorder.
struct PlaudRecording: Identifiable, Hashable {
    let sessionId: UInt32
    let size: Int
    var imported: Bool

    var id: UInt32 { sessionId }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(sessionId)) }
}

/// What an import produced: an audio file in the recordings store.
struct PlaudImportedAudio {
    let fileName: String
    let duration: Double
    let date: Date
}

/// Connects to a Plaud recorder over Bluetooth, lists its recordings and copies them into Porridge.
@MainActor
@Observable
final class PlaudImporter {
    private(set) var signedIn: Bool
    private(set) var status = ""
    private(set) var recordings: [PlaudRecording] = []
    /// Connecting or reading the list.
    private(set) var isWorking = false
    /// The recording being copied right now, and how far it is (0...1).
    private(set) var importingId: UInt32?
    private(set) var progress = 0.0
    var errorMessage: String?

    @ObservationIgnored private var account = PlaudAccount.load()
    @ObservationIgnored private var privateKey: SecKey?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private lazy var ble: PlaudBLE = {
        let ble = PlaudBLE()
        ble.onLog = { [weak self] text in self?.status = text }
        return ble
    }()

    private static let importedKey = "plaud.importedSessions"

    init() {
        signedIn = PlaudAccount.load().userToken != nil
    }

    // MARK: Account

    func signIn(token: String, refreshToken: String? = nil) {
        account.userToken = token
        account.refreshToken = refreshToken
        account.apiHost = PlaudAPI.hostFromToken(token)
        account.save()
        signedIn = true
    }

    /// The sign-in stopped working (token expired, renewal refused): forget the tokens, keep the keys
    /// and device signatures (they stay valid), and ask for a new sign-in.
    private func expireSignIn() {
        account.userToken = nil
        account.refreshToken = nil
        account.save()
        signedIn = false
        recordings = []
        status = ""
    }

    /// A user token Plaud still accepts. Renews it with the refresh token shortly before it runs out,
    /// the way web.plaud.ai does; without a refresh token an expired sign-in ends here.
    private func validUserToken() async throws -> String {
        guard let token = account.userToken else { throw PlaudAPIError.message("Please sign in to Plaud first.") }
        guard let expiry = PlaudAPI.expiry(of: token), expiry.timeIntervalSinceNow < 120 else { return token }
        guard let refreshToken = account.refreshToken else {
            expireSignIn()
            throw PlaudAPIError.unauthorized
        }
        status = "Renewing the Plaud sign-in …"
        do {
            let renewed = try await PlaudAPI(userToken: token, host: account.apiHost).refreshUserToken(refreshToken: refreshToken)
            account.userToken = renewed.userToken
            if let fresh = renewed.refreshToken { account.refreshToken = fresh }
            account.apiHost = renewed.host
            account.save()
            return renewed.userToken
        } catch {
            PlaudLog.log("token renewal failed: \(error)")
            expireSignIn()
            throw PlaudAPIError.unauthorized
        }
    }

    func signOut() {
        ble.disconnect()
        PlaudAccount.clear()
        account = PlaudAccount()
        privateKey = nil
        recordings = []
        signedIn = false
        status = ""
    }

    // MARK: List

    /// Connects to the recorder (if needed) and reads its recordings.
    func refresh() async {
        guard signedIn, !isWorking, importingId == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await ensureReady()
            let imported = Self.importedSessions
            recordings = try await ble.listSessions()
                .map { PlaudRecording(sessionId: $0.sessionId, size: Int($0.size), imported: imported.contains($0.sessionId)) }
                .sorted { $0.sessionId > $1.sessionId }
            status = recordings.isEmpty ? "No recordings on the recorder." : ""
        } catch {
            ble.disconnect()
            errorMessage = Self.message(for: error)
            status = ""
        }
    }

    private static func message(for error: Error) -> String {
        if let ble = error as? PlaudBLEError { return ble.description }
        if let api = error as? PlaudAPIError { return api.description }
        return error.localizedDescription
    }

    // MARK: Import

    /// Copies one recording off the recorder, decrypts it and stores it as audio.
    func importRecording(_ recording: PlaudRecording) async -> PlaudImportedAudio? {
        guard importingId == nil, !isWorking else { return nil }
        importingId = recording.sessionId
        progress = 0
        cancelRequested = false
        defer { importingId = nil }
        do {
            try await ensureReady()
            guard let key = privateKey else { throw PlaudBLEError.message("missing keys") }
            let info = PlaudRecordingInfo(sessionId: recording.sessionId, size: UInt32(recording.size))
            let part = Self.partURL(for: recording.sessionId)
            let raw = try await pullWithResume(info, partURL: part)
            try? FileManager.default.removeItem(at: part)

            guard raw.prefix(8) == Data("PLAUD.AI".utf8) else {
                throw PlaudBLEError.message("The recorder sent the recording in a format Porridge does not know.")
            }
            status = "Converting …"
            let ogg = try PlaudCrypto.decryptRecordingFile(raw, privateKey: key)
            // The cipher has no checksum, so damaged bytes would still "decrypt": the audio's own page checksums prove the copy whole.
            guard PlaudCrypto.isCompleteOgg(ogg) else {
                throw PlaudBLEError.message("The copy of this recording is damaged. Please try again.")
            }
            let fileName = AudioStore.newFileName(extension: "m4a")
            let duration = try await Task.detached(priority: .userInitiated) {
                try OpusOggDecoder.decode(ogg: ogg, to: AudioStore.url(for: fileName))
            }.value
            Self.markImported(recording.sessionId)
            if let index = recordings.firstIndex(where: { $0.sessionId == recording.sessionId }) {
                recordings[index].imported = true
            }
            status = ""
            return PlaudImportedAudio(fileName: fileName, duration: duration, date: recording.date)
        } catch PlaudBLEError.cancelled {
            status = ""
            return nil
        } catch {
            errorMessage = Self.message(for: error)
            status = ""
            return nil
        }
    }

    func cancelImport() {
        guard importingId != nil else { return }
        cancelRequested = true
        ble.cancelTransfer()
    }

    /// Download with progress kept on disk. A broken transfer leaves the part file, and the next attempt starts after it.
    private func pullWithResume(_ info: PlaudRecordingInfo, partURL: URL) async throws -> Data {
        let total = Int(info.size)
        var reconnects = 0
        try? FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        while true {
            var saved = (try? Data(contentsOf: partURL)) ?? Data()
            if total > 0, saved.count > total { saved = Data() }
            if total > 0, saved.count == total { return saved }
            let writer = try PlaudPartWriter(url: partURL, keep: saved.count)
            defer { writer.close() }
            do {
                let pulled = try await ble.pullFile(info, existing: saved, onChunk: writer.append, onProgress: { got, total in
                    if total > 0 { self.progress = Double(got) / Double(total) }
                })
                return pulled.data
            } catch let error as PlaudBLEError where error.isRetryable && reconnects < 2 && !cancelRequested {
                reconnects += 1
                writer.close()
                status = "Connection lost. Reconnecting …"
                ble.disconnect()
                try await ensureReady()
            }
        }
    }

    // MARK: Connection

    private func ensureReady() async throws {
        let token = try await validUserToken()
        var api = PlaudAPI(userToken: token, host: account.apiHost)
        if account.privatePEM == nil {
            status = "Fetching your encryption key …"
            do {
                let key = try await api.genKey()
                account.privatePEM = key.priv
                account.publicPEM = key.pub
                account.apiHost = key.host
                api.host = key.host
                account.save()
            } catch PlaudAPIError.unauthorized {
                expireSignIn()
                throw PlaudAPIError.unauthorized
            }
        }
        if privateKey == nil, let pem = account.privatePEM {
            privateKey = try PlaudCrypto.importRSAPrivateKey(pem: Data(pem.utf8))
        }
        if ble.isConnected { return }

        // Bluetooth links fail for passing reasons; each attempt starts from a clean link.
        let attempts = 3
        for attempt in 1...attempts {
            do {
                try await connectAndUnlock(api: api, token: token)
                return
            } catch {
                ble.disconnect()
                PlaudLog.log("connect attempt \(attempt) failed: \(error)")
                let retryable = (error as? PlaudBLEError)?.isRetryable ?? false
                guard retryable, attempt < attempts else { throw error }
                status = "Connection failed. Retrying \(attempt + 1) of \(attempts) …"
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    private func connectAndUnlock(api: PlaudAPI, token: String) async throws {
        status = "Looking for the recorder …"
        try await ble.connect(knownSerials: Set(account.signatures.keys))
        let saved = ble.isKnownPeripheral ? account.lastSerial : nil
        guard let serial = ble.discoveredSerial ?? saved else {
            throw PlaudBLEError.message("Could not read the serial number of the recorder.")
        }
        if account.signatures[serial] == nil {
            status = "Authorising the recorder …"
            do {
                let signed = try await api.snSign(serial: serial)
                account.signatures[serial] = signed.sig
                account.apiHost = signed.host
                account.save()
            } catch PlaudAPIError.unauthorized {
                expireSignIn()
                throw PlaudBLEError.fatal(PlaudAPIError.unauthorized.description)
            } catch {
                throw PlaudBLEError.fatal("Could not get the recorder's signature from Plaud: \(error)")
            }
        }
        guard let publicPEM = account.publicPEM, let signature = account.signatures[serial], let key = privateKey else {
            throw PlaudBLEError.message("missing keys")
        }
        try await ble.unlockProtocol20(signatureBase64: signature, privateKey: key, publicKeyPEM: publicPEM)
        try await ble.handshake(token: PlaudAPI.subject(of: token) ?? serial)
        account.lastSerial = serial
        account.save()
        // Recording ids are start times from the recorder's clock, so keep it right (the Plaud app does too).
        do { try await ble.syncClock() } catch { PlaudLog.log("clock sync failed: \(error)") }
        status = ""
    }

    func disconnect() {
        ble.disconnect()
    }

    /// Stores an imported recording as a new note and starts transcribing it.
    static func addNote(_ audio: PlaudImportedAudio, context: ModelContext, processing: ProcessingService) {
        let note = Note()
        note.createdAt = audio.date
        note.updatedAt = audio.date
        note.title = Note.defaultMeetingTitle(for: audio.date)
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = audio.fileName
        note.duration = audio.duration
        note.inputName = "Plaud"
        if let info = AudioStore.audioInfo(for: audio.fileName) { note.channelCount = info.channels }
        context.insert(note)
        try? context.save()
        processing.enqueue(.transcript(note.id))
    }

    // MARK: Bookkeeping

    private static var importedSessions: Set<UInt32> {
        Set((UserDefaults.standard.array(forKey: importedKey) as? [Int])?.map { UInt32($0) } ?? [])
    }

    private static func markImported(_ sessionId: UInt32) {
        var all = importedSessions
        all.insert(sessionId)
        UserDefaults.standard.set(all.map { Int($0) }, forKey: importedKey)
    }

    private static func partURL(for sessionId: UInt32) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Plaud", isDirectory: true).appendingPathComponent("plaud_\(sessionId).part")
    }
}

/// Appends downloaded bytes to the part file; on a write error it cuts the file back to the last good byte.
private final class PlaudPartWriter {
    private let url: URL
    private let handle: FileHandle
    private var good: UInt64
    private var pending = Data()
    private var broken = false

    init(url: URL, keep: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        good = UInt64(keep)
        try handle.truncate(atOffset: good)
        try handle.seekToEnd()
    }

    func append(_ chunk: Data) {
        guard !broken else { return }
        pending.append(chunk)
        if pending.count >= 65_536 { flush() }
    }

    func flush() {
        guard !broken, !pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: pending)
            good += UInt64(pending.count)
            pending.removeAll()
        } catch {
            broken = true
            pending.removeAll()
            if (try? handle.truncate(atOffset: good)) == nil { try? FileManager.default.removeItem(at: url) }
        }
    }

    func close() {
        flush()
        try? handle.close()
    }
}
