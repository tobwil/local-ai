import Foundation
import Metal

struct Hardware {
    let chip: String
    let memoryGiB: Int
    /// Was Metal einem Prozess standardmäßig an GPU-Speicher erlaubt (recommendedMaxWorkingSetSize).
    let gpuLimitGB: Double
    let freeDiskGB: Double
    /// Speicherbandbreite in GB/s laut Apple; nil, wenn der Chip nicht in der Tabelle steht.
    let bandwidthGBs: Double?

    static func detect() -> Hardware {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unbekannter Chip"
        let memory = ProcessInfo.processInfo.physicalMemory
        let gpu = MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) / 1e9 }
            ?? Double(memory) / 1e9 * 0.66
        return Hardware(chip: chip,
                        memoryGiB: Int((Double(memory) / 1_073_741_824).rounded()),
                        gpuLimitGB: gpu,
                        freeDiskGB: freeDisk(),
                        bandwidthGBs: bandwidth(for: chip))
    }

    static func freeDisk() -> Double {
        let values = try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
    }

    // Längere Namen zuerst, damit "M4 Pro" nicht als "M4" erkannt wird.
    private static let bandwidthTable: [(String, Double)] = [
        ("M1 Ultra", 800), ("M1 Max", 400), ("M1 Pro", 200), ("M1", 68),
        ("M2 Ultra", 800), ("M2 Max", 400), ("M2 Pro", 200), ("M2", 100),
        ("M3 Ultra", 819), ("M3 Max", 400), ("M3 Pro", 150), ("M3", 100),
        ("M4 Max", 546), ("M4 Pro", 273), ("M4", 120),
        ("M5", 153),
    ]

    private static func bandwidth(for chip: String) -> Double? {
        bandwidthTable.first { chip.contains($0.0) }?.1
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
