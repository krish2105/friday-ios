import FoundationModels
import Network
import UIKit

/// Battery, storage, connectivity and thermal state.
struct DeviceTool: Tool {
    let name = "deviceStatus"
    let description = "Battery, storage, network connection and temperature of this iPhone."

    @Generable
    struct Arguments {
        @Guide(description: "One of: battery, storage, network, temperature, all")
        let aspect: String
    }

    func call(arguments: Arguments) async throws -> String {
        let aspect = arguments.aspect.trimmingCharacters(in: .whitespaces).lowercased()
        let wantsAll = aspect.isEmpty || aspect == "all"

        var parts: [String] = []
        if wantsAll || aspect.contains("batt") { parts.append(await Self.battery()) }
        if wantsAll || aspect.contains("storage") || aspect.contains("space") { parts.append(Self.storage()) }
        if wantsAll || aspect.contains("net") || aspect.contains("wifi") { parts.append(await Self.connection()) }
        if wantsAll || aspect.contains("temp") || aspect.contains("thermal") { parts.append(Self.thermal()) }

        guard !parts.isEmpty else { return await Self.battery() }
        return parts.joined(separator: " ")
    }

    // MARK: - Battery

    @MainActor
    private static func battery() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        // −1 means unavailable, which is what the Simulator always reports.
        guard device.batteryLevel >= 0 else {
            return "Battery level isn't readable on this device."
        }

        let percent = Int((device.batteryLevel * 100).rounded())
        let state: String = switch device.batteryState {
        case .charging: ", charging"
        case .full: ", fully charged"
        case .unplugged: ""
        case .unknown: ""
        @unknown default: ""
        }
        return "Battery is at \(percent)%\(state)."
    }

    // MARK: - Storage

    private static func storage() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return "Free storage isn't readable right now."
        }
        let formatted = Measurement(value: Double(available), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
        return "There is \(formatted) of free storage."
    }

    // MARK: - Connection

    private static func connection() async -> String {
        let monitor = NWPathMonitor()

        // Taking the first value from a stream avoids the double-resume hazard
        // of wrapping a repeating callback in a continuation.
        let paths = AsyncStream<NWPath> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0) }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            continuation.onTermination = { _ in monitor.cancel() }
        }

        for await path in paths {
            guard path.status == .satisfied else { return "There is no network connection." }
            if path.usesInterfaceType(.wifi) { return "Connected over Wi-Fi." }
            if path.usesInterfaceType(.cellular) { return "Connected over cellular." }
            if path.usesInterfaceType(.wiredEthernet) { return "Connected over ethernet." }
            return "Connected."
        }
        return "The network state isn't readable right now."
    }

    // MARK: - Thermal

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Temperature is normal."
        case .fair: "Running slightly warm."
        case .serious: "Running hot."
        case .critical: "Overheating."
        @unknown default: "Temperature is normal."
        }
    }
}
