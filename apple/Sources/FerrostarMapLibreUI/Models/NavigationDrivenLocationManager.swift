import CoreLocation
import MapLibre
import MapLibreSwiftUI

/// A map location manager that can be directly fed by navigation state updates.
public protocol NavigationDrivenLocationManager: MLNLocationManager, AnyObject {
    var lastLocation: CLLocation { get set }
    var lastHeading: CLHeading? { get set }

    /// An optional display fix prepared by the host before it publishes navigation state.
    /// The camera applies it with its own animation when the timestamp and coordinate match.
    var preparedNavigationLocation: CLLocation? { get }
}

public extension NavigationDrivenLocationManager {
    var preparedNavigationLocation: CLLocation? { nil }
}

extension StaticLocationManager: NavigationDrivenLocationManager {}
