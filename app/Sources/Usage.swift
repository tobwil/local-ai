import Foundation
import Observation

/// Nutzungszahlen der Engine (wie im oMLX-Webinterface) und Zustand des Macs (Wärme, Speicher).
@MainActor @Observable
final class UsageMonitor {
    struct Engine {
        var tokensServed = 0, promptTokens = 0, completionTokens = 0, cachedTokens = 0, requests = 0
        var cacheEfficiency = 0.0, prefillTPS = 0.0, generationTPS = 0.0, uptime = 0.0
    }

    private(set) var session: Engine?
    private(set) var alltime: Engine?
    private(set) var modelMemory: (used: Int64, max: Int64)?
    private(set) var pressure = ""
    private(set) var activeRequests = 0
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var temperature: Double?
    private(set) var updated: Date?

    func refresh() async {
        thermal = ProcessInfo.processInfo.thermalState
        temperature = await Task.detached { ThermalSensors.chipTemperature() }.value
        async let s = fetch(scope: "session")
        async let a = fetch(scope: "alltime")
        let (sj, aj) = await (s, a)
        session = sj.map(Self.parse)
        alltime = aj.map(Self.parse)
        if let models = sj?["active_models"] as? [String: Any] {
            let used = (models["model_memory_used"] as? NSNumber)?.int64Value ?? 0
            let max = (models["model_memory_max"] as? NSNumber)?.int64Value ?? 0
            modelMemory = max > 0 ? (used, max) : nil
            pressure = (models["memory_pressure"] as? [String: Any])?["pressure_level"] as? String ?? ""
            activeRequests = models["total_active_requests"] as? Int ?? 0
        }
        updated = Date()
    }

    private func fetch(scope: String) async -> [String: Any]? {
        var req = URLRequest(url: Paths.server.appendingPathComponent("admin/api/stats").appending(queryItems: [URLQueryItem(name: "scope", value: scope)]))
        req.timeoutInterval = 3
        HomeNetwork.authorize(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parse(_ j: [String: Any]) -> Engine {
        func i(_ k: String) -> Int { (j[k] as? NSNumber)?.intValue ?? 0 }
        func d(_ k: String) -> Double { (j[k] as? NSNumber)?.doubleValue ?? 0 }
        return Engine(tokensServed: i("total_tokens_served"), promptTokens: i("total_prompt_tokens"),
                      completionTokens: i("total_completion_tokens"), cachedTokens: i("total_cached_tokens"),
                      requests: i("total_requests"), cacheEfficiency: d("cache_efficiency"),
                      prefillTPS: d("avg_prefill_tps"), generationTPS: d("avg_generation_tps"), uptime: d("uptime_seconds"))
    }

    var thermalText: String {
        switch thermal {
        case .nominal: return "kühl"
        case .fair: return "warm"
        case .serious: return "heiß – Tempo sinkt"
        case .critical: return "kritisch – stark gedrosselt"
        @unknown default: return "unbekannt"
        }
    }
}

/// Chip-Temperatur über die Temperatursensoren von macOS (IOHID, ohne Administratorrechte).
/// Die Funktionen sind nicht dokumentiert – fehlen sie, liefert die Funktion nil und nur der Wärmezustand wird gezeigt.
enum ThermalSensors {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    static func chipTemperature() -> Double? {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateClient.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Temperatursensoren: Usage Page 0xff00, Usage 5
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        var dies: [Double] = [], all: [Double] = []
        let temperatureEvent: Int64 = 15
        for service in services {
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Int32(temperatureEvent << 16))
            guard value > 10, value < 130 else { continue }
            all.append(value)
            if name.localizedCaseInsensitiveContains("tdie") || name.localizedCaseInsensitiveContains("tdev") { dies.append(value) }
        }
        let pick = dies.isEmpty ? all : dies
        return pick.max()
    }
}
