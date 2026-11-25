import CoreLocation
import UIKit

/// Viewport and motion settings for the optional route-aware follow camera.
public struct NavigationFollowCameraConfiguration: Equatable {
    public struct SpeedZoomBand: Equatable {
        let speedBelow: CLLocationSpeed
        let minimumZoom: Double

        /// Sets the minimum zoom below an exclusive speed threshold in meters per second.
        public init(speedBelow: CLLocationSpeed, minimumZoom: Double) {
            self.speedBelow = speedBelow
            self.minimumZoom = minimumZoom
        }
    }

    public struct ZoomTransition: Equatable {
        let responseTime: TimeInterval
        let maximumLevelsPerSecond: Double

        /// Sets the smoothing time in seconds and the maximum rate in zoom levels per second.
        public init(responseTime: TimeInterval, maximumLevelsPerSecond: Double) {
            self.responseTime = max(0.01, responseTime)
            self.maximumLevelsPerSecond = max(0, maximumLevelsPerSecond)
        }
    }

    public struct NearbyTurnHold: Equatable {
        let completedTurnDistance: CLLocationDistance
        let nextTurnDistance: CLLocationDistance

        /// Holds the closer zoom when both the last fix before a completed turn and the
        /// next turn are within their respective thresholds in meters.
        public init(completedTurnDistance: CLLocationDistance, nextTurnDistance: CLLocationDistance) {
            self.completedTurnDistance = completedTurnDistance
            self.nextTurnDistance = nextTurnDistance
        }
    }

    public struct ManeuverPitch: Equatable {
        let distanceRange: ClosedRange<CLLocationDistance>
        let cruisingPitch: CGFloat

        /// Eases from the cruising pitch in degrees at the upper distance bound
        /// to a flat view at the lower bound. Distances are in meters.
        public init(distanceRange: ClosedRange<CLLocationDistance>, cruisingPitch: CGFloat) {
            self.distanceRange = distanceRange
            self.cruisingPitch = cruisingPitch
        }
    }

    let zoomRange: ClosedRange<Double>
    let speedZoomBands: [SpeedZoomBand]
    let maneuverPadding: UIEdgeInsets
    let zoomIn: ZoomTransition
    let zoomOut: ZoomTransition
    let zoomDeadband: Double
    let nearbyTurnHold: NearbyTurnHold?
    let maneuverPitch: ManeuverPitch?
    let maximumHeadingDegreesPerSecond: Double
    let maximumPitchDegreesPerSecond: Double
    let showsCourseArrow: Bool

    /// Creates a configuration for fitting the location and next maneuver in the viewport.
    ///
    /// - Parameters:
    ///   - zoomRange: Bounds for automatic zoom before the map's own zoom limits.
    ///   - speedZoomBands: Optional speed-dependent zoom floors. The lowest matching speed threshold wins.
    ///     Unknown speeds and speeds above all thresholds use the lower zoom bound.
    ///   - maneuverPadding: Extra fitting padding in points, added to the map's content inset.
    ///   - zoomIn: Smoothing and rate limit for zooming in.
    ///   - zoomOut: Smoothing and rate limit for zooming out.
    ///   - zoomDeadband: Ignore smaller automatic zoom changes.
    ///   - nearbyTurnHold: Optional thresholds for retaining the closer zoom between turns.
    ///   - maneuverPitch: Optional distance-based pitch. The follow camera's pitch is used otherwise.
    ///   - maximumHeadingDegreesPerSecond: Maximum turn rate of the camera.
    ///   - maximumPitchDegreesPerSecond: Maximum tilt rate of the camera.
    ///   - showsCourseArrow: Draw a course arrow on the MapLibre location marker while following.
    public init(
        zoomRange: ClosedRange<Double> = 0...22,
        speedZoomBands: [SpeedZoomBand] = [],
        maneuverPadding: UIEdgeInsets = .zero,
        zoomIn: ZoomTransition = .init(responseTime: 0.5, maximumLevelsPerSecond: 1),
        zoomOut: ZoomTransition = .init(responseTime: 0.5, maximumLevelsPerSecond: 1),
        zoomDeadband: Double = 0.1,
        nearbyTurnHold: NearbyTurnHold? = nil,
        maneuverPitch: ManeuverPitch? = nil,
        maximumHeadingDegreesPerSecond: Double = 90,
        maximumPitchDegreesPerSecond: Double = 45,
        showsCourseArrow: Bool = true
    ) {
        self.zoomRange = zoomRange
        self.speedZoomBands = speedZoomBands.sorted { $0.speedBelow < $1.speedBelow }
        self.maneuverPadding = maneuverPadding
        self.zoomIn = zoomIn
        self.zoomOut = zoomOut
        self.zoomDeadband = max(0, zoomDeadband)
        self.nearbyTurnHold = nearbyTurnHold
        self.maneuverPitch = maneuverPitch
        self.maximumHeadingDegreesPerSecond = max(0, maximumHeadingDegreesPerSecond)
        self.maximumPitchDegreesPerSecond = max(0, maximumPitchDegreesPerSecond)
        self.showsCourseArrow = showsCourseArrow
    }

    func minimumZoom(for speed: CLLocationSpeed) -> Double {
        if speed >= 0, let band = speedZoomBands.first(where: { speed < $0.speedBelow }) {
            return max(zoomRange.lowerBound, band.minimumZoom)
        }
        return zoomRange.lowerBound
    }
}
