import Foundation
import SwiftUI

/// A file moving in one direction, as the UI sees it.
struct Transfer: Identifiable, Equatable {
    enum Direction { case toPhone, fromPhone }
    enum State: Equatable { case running, done, failed(String) }

    let id: Int
    let name: String
    let size: Int64
    let direction: Direction
    var moved: Int64 = 0
    var state: State = .running
    /// Where a received file ended up, for "Reveal in Finder".
    var url: URL?

    var fraction: Double {
        size > 0 ? min(1, Double(moved) / Double(size)) : (state == .done ? 1 : 0)
    }
}

/// Files moving between this Mac and the phone.
///
/// Chunked rather than sent whole: a video would otherwise sit in memory twice
/// on both devices, and one enormous frame would block the heartbeat and the
/// screen mirror behind it in the socket's send queue. Each chunk carries its
/// transfer id and offset, so it is written straight to the right place and
/// arriving out of order costs nothing.
///
/// Incoming files are written to a temporary file and only moved into Downloads
/// once complete, so an interrupted transfer never leaves a truncated file
/// looking like a real one.
@MainActor
final class FileTransfers: ObservableObject {
    /// Newest first, so the UI shows what just happened without scrolling.
    @Published private(set) var transfers: [Transfer] = []

    /// Chunk payload: [4-byte id][8-byte offset][bytes].
    nonisolated static let header = 12
    nonisolated static let chunk = 128 * 1024
    /// Refuse absurd transfers outright rather than filling the disk.
    private static let maxSize: Int64 = 8 * 1024 * 1024 * 1024
    /// Bounds open file handles and staged partial files.
    private static let maxConcurrent = 4

    private var nextID = 1
    private var handles: [Int: FileHandle] = [:]
    private var staging: [Int: URL] = [:]
    private weak var pairing: PairingManager?

    func attach(to pairing: PairingManager) { self.pairing = pairing }

    // MARK: Sending

    func send(_ url: URL) {
        guard let pairing, pairing.isConnected else { return }
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let id = nextID
        nextID += 1
        transfers.insert(Transfer(id: id, name: name, size: size, direction: .toPhone), at: 0)
        pairing.sendFileStart(id: id, name: name, size: size, mime: Self.mime(for: url))

        Task { [weak self] in
            let ok = await Self.stream(url: url, id: id, pairing: pairing) { moved in
                await MainActor.run { self?.advance(id: id, moved: moved) }
            }
            if ok {
                pairing.sendFileEnd(id: id)
            } else {
                pairing.sendFileCancel(id: id)
                self?.fail(id: id, "Couldn't read the file")
            }
        }
    }

    /// Reads and ships the file chunk by chunk. Nonisolated and self-contained
    /// so nothing mutable crosses a concurrency boundary.
    private nonisolated static func stream(
        url: URL, id: Int, pairing: PairingManager,
        progress: @Sendable (Int64) async -> Void
    ) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            guard let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty else { return true }
            guard await pairing.sendFileChunk(id: id, offset: offset, data: data) else { return false }
            offset += Int64(data.count)
            await progress(offset)
        }
    }

    // MARK: Receiving

    func begin(id: Int, name: String, size: Int64, mime: String) {
        // The phone is authenticated, but that is not the same as being trusted
        // with this Mac's disk: every field here arrives from the other side.
        guard size >= 0, size <= Self.maxSize, handles.count < Self.maxConcurrent else {
            pairing?.sendFileCancel(id: id)
            return
        }
        let safe = Self.sanitise(name)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tethr-\(id)-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return }
        handles[id] = handle
        staging[id] = temp
        transfers.insert(Transfer(id: id, name: safe, size: size, direction: .fromPhone), at: 0)
    }

    func write(id: Int, offset: Int64, data: Data) {
        guard let handle = handles[id],
              let declared = transfers.first(where: { $0.id == id })?.size else { return }
        // Without this a chunk claiming a huge offset would punch out a file far
        // larger than the transfer ever declared.
        guard offset >= 0, offset + Int64(data.count) <= declared else {
            cancel(id: id, reason: "Chunk outside the declared size")
            pairing?.sendFileCancel(id: id)
            return
        }
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: data)
        advance(id: id, moved: offset + Int64(data.count))
    }

    func finish(id: Int) {
        guard let handle = handles.removeValue(forKey: id),
              let temp = staging.removeValue(forKey: id),
              let index = transfers.firstIndex(where: { $0.id == id })
        else { return }
        try? handle.close()

        let destination = Self.uniqueDownloadURL(named: transfers[index].name)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
            Self.quarantine(destination)
            transfers[index].url = destination
            transfers[index].state = .done
            transfers[index].moved = transfers[index].size
        } catch {
            try? FileManager.default.removeItem(at: temp)
            transfers[index].state = .failed("Couldn't save to Downloads")
        }
    }

    func cancel(id: Int, reason: String = "Cancelled") {
        if let handle = handles.removeValue(forKey: id) { try? handle.close() }
        if let temp = staging.removeValue(forKey: id) { try? FileManager.default.removeItem(at: temp) }
        fail(id: id, reason)
    }

    /// The phone confirming it stored what we sent.
    func completed(id: Int, ok: Bool) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = ok ? .done : .failed("The phone couldn't save it")
        if ok { transfers[index].moved = transfers[index].size }
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: Internals

    private func advance(id: Int, moved: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].moved = moved
    }

    private func fail(id: Int, _ reason: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .failed(reason)
    }

    /// Marks the file as downloaded from elsewhere, so Gatekeeper treats it the
    /// way it treats a browser download rather than something this Mac made.
    private static func quarantine(_ url: URL) {
        let value = "0083;\(String(format: "%x", Int(Date().timeIntervalSince1970)));Tethr;"
        _ = value.withCString { bytes in
            setxattr(url.path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
        }
    }

    /// Never overwrite: a second "report.pdf" becomes "report 2.pdf".
    private static func uniqueDownloadURL(named name: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var candidate = downloads.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = downloads.appendingPathComponent(next)
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// The name comes from the other device, so it is untrusted: strip anything
    /// that could steer the write out of Downloads.
    private static func sanitise(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "tethr-file" : String(base.prefix(120))
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}
