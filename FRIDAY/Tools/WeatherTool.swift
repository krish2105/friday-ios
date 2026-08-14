import CoreLocation
import FoundationModels
import WeatherKit

/// One-shot location fix, wrapped around `CLLocationManager`'s delegate.
private final class LocationFix: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func current() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        settle(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        settle(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted: settle(nil)
        default: break
        }
    }

    /// Nils the continuation before resuming so a second callback is a no-op.
    private func settle(_ location: CLLocation?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: location)
    }
}

/// Current conditions for wherever the user is.
///
/// WeatherKit needs a paid Apple Developer Program membership plus the
/// WeatherKit capability enabled on the App ID. Without those, every call
/// throws — so this tool reports that in plain language rather than failing,
/// and starts working the moment the entitlement is in place. No other tool
/// depends on it.
struct WeatherTool: Tool {
    let name = "currentWeather"
    let description = "Current weather conditions and today's high and low where the user is."

    @Generable
    struct Arguments {
        @Guide(description: "True for today's forecast as well as conditions right now")
        let includeForecast: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        guard let location = await LocationFix().current() else {
            return FridayTool.denied("your location", settingsPath: "Settings, under FRIDAY")
        }

        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let now = weather.currentWeather

            let temperature = now.temperature.formatted(.measurement(width: .abbreviated))
            let condition = now.condition.description.lowercased()
            var report = "Right now it's \(temperature) and \(condition)."

            if arguments.includeForecast, let today = weather.dailyForecast.first {
                let high = today.highTemperature.formatted(.measurement(width: .abbreviated))
                let low = today.lowTemperature.formatted(.measurement(width: .abbreviated))
                report += " Today's high is \(high), low \(low)."
            }
            return report

        } catch {
            // Overwhelmingly the missing-entitlement case on a free account.
            return "Weather isn't available on this build. Tell boss you can't reach the weather service right now, in your own words, and move on."
        }
    }
}
