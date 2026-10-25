import AppKit
import CoreImage.CIFilterBuiltins
import Foundation

/// Freigabe im Heimnetz: oMLX lauscht auf allen Schnittstellen und verlangt einen API-Schlüssel.
/// Andere Geräte (iPhone, iPad, PC) nutzen dann den Web-Chat von oMLX oder jede OpenAI-kompatible App.
enum HomeNetwork {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "lanEnabled") }

    /// Schlüssel, solange die Freigabe an ist (sonst nil – dann lauscht der Server nur lokal ohne Schlüssel).
    static var key: String? { enabled ? Keychain.get("lanKey") : nil }

    static func newKey() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let key = "kl-" + String((0..<32).map { _ in alphabet.randomElement()! })
        Keychain.set("lanKey", key)
        return key
    }

    /// Schlüssel der Engine: im Heimnetz der Freigabe-Schlüssel, sonst ein lokaler (nur auf diesem Mac).
    /// Ohne Freigabe dürfen Programme auf dem Mac auch ohne Schlüssel chatten; Verwaltung und Statistik
    /// der Engine verlangen ihn immer.
    static var engineKey: String { key ?? localKey }

    nonisolated(unsafe) private static var cachedLocalKey: String?
    static var localKey: String {
        if let k = cachedLocalKey { return k }
        let k = Keychain.get("localEngineKey") ?? {
            let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let new = "kl-local-" + String((0..<32).map { _ in alphabet.randomElement()! })
            Keychain.set("localEngineKey", new)
            return new
        }()
        cachedLocalKey = k
        return k
    }

    /// Header für Anfragen an den eigenen Server.
    static func authorize(_ req: inout URLRequest) {
        req.setValue("Bearer \(engineKey)", forHTTPHeaderField: "Authorization")
    }

    static var hostName: String {
        let local = ProcessInfo.processInfo.hostName
        if let name = SCLocalHostName(), !name.isEmpty { return name + ".local" }
        return local
    }

    static var ipAddress: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            if name == "en0" { break }
        }
        return address
    }

    static var webChatURL: String { "http://\(hostName):\(Paths.port)/admin/chat" }
    static var apiURL: String { "http://\(hostName):\(Paths.port)/v1" }

    static func qrCode(_ text: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: size / output.extent.width, y: size / output.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func SCLocalHostName() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard let data = try? p.runAndReadBlocking(pipe) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
