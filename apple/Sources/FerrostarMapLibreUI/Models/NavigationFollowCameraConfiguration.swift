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

    public struct ManeuverFraming: Equatable {
        let distanceRange: ClosedRange<CLLocationDistance>
        let outgoingDistance: CLLocationDistance
        let viewportPadding: CGFloat
        let compoundManeuverDistance: CLLocationDistance?
        let framesRoundaboutsThroughExit: Bool
        let roundaboutExitZoomHoldDistance: CLLocationDistance

        /// Fully frame the nearby maneuver at the lower bound, fading to rider-centered
        /// framing by the upper bound. Include up to outgoingDistance meters after the turn.
        /// Reserve viewportPadding points around the fitted area for the marker and route line.
        /// Set compoundManeuverDistance to frame two maneuvers together when their route separation
        /// is within that many meters. By default, the camera frames only the next maneuver.
        /// Enable framesRoundaboutsThroughExit to keep the entry and exit steps framed together
        /// when the route identifies them, independent of their separation.
        /// Set roundaboutExitZoomHoldDistance to keep the exit zoom as a minimum for that
        /// many meters traveled along the route after a recognized roundabout exit.
        public init(
            distanceRange: ClosedRange<CLLocationDistance>,
            outgoingDistance: CLLocationDistance,
            viewportPadding: CGFloat = 0,
            compoundManeuverDistance: CLLocationDistance? = nil,
            framesRoundaboutsThroughExit: Bool = false,
            roundaboutExitZoomHoldDistance: CLLocationDistance = 0
        ) {
            self.distanceRange = distanceRange
            self.outgoingDistance = max(0, outgoingDistance)
            self.viewportPadding = max(0, viewportPadding)
            self.compoundManeuverDistance = compoundManeuverDistance
            self.framesRoundaboutsThroughExit = framesRoundaboutsThroughExit
            self.roundaboutExitZoomHoldDistance = roundaboutExitZoomHoldDistance.isFinite
                ? max(0, roundaboutExitZoomHoldDistance) : 0
        }
    }

    public struct RouteLookahead: Equatable {
        public struct LongSegment: Equatable {
            let distanceToTurnRange: ClosedRange<CLLocationDistance>
            let riderAnchorOffset: CGFloat

            /// Blends into a longer lookahead over a range of distances to the next turn.
            /// At and above the upper bound, the camera fits the rest of the current step.
            /// Distances are in meters. The optional rider anchor offset shifts the rider down
            /// by a fraction of the usable viewport height, from zero up to but excluding one half.
            public init(
                distanceToTurnRange: ClosedRange<CLLocationDistance>,
                riderAnchorOffset: CGFloat = 0
            ) {
                self.distanceToTurnRange = distanceToTurnRange
                self.riderAnchorOffset = (0..<0.5).contains(riderAnchorOffset) ? riderAnchorOffset : 0
            }

            func weight(for distanceToTurn: CLLocationDistance) -> Double {
                guard distanceToTurn.isFinite, distanceToTurn > distanceToTurnRange.lowerBound else { return 0 }
                if distanceToTurn >= distanceToTurnRange.upperBound { return 1 }
                let fraction = (distanceToTurn - distanceToTurnRange.lowerBound) /
                    (distanceToTurnRange.upperBound - distanceToTurnRange.lowerBound)
                return fraction * fraction * (3 - 2 * fraction)
            }
        }

        let distanceRange: ClosedRange<CLLocationDistance>
        let travelTime: TimeInterval
        let maneuverSpacingMultiplier: Double
        let longSegment: LongSegment?

        /// Bounds the length of road ahead used for zoom fitting. Speed extends the
        /// lookahead, and the typical distance between upcoming maneuvers can shorten it.
        /// A long-segment configuration allows a wider view when there is no turn nearby.
        /// Distances are in meters and travelTime is in seconds.
        public init(
            distanceRange: ClosedRange<CLLocationDistance>,
            travelTime: TimeInterval,
            maneuverSpacingMultiplier: Double,
            longSegment: LongSegment? = nil
        ) {
            self.distanceRange = distanceRange
            self.travelTime = max(0, travelTime)
            self.maneuverSpacingMultiplier = max(0, maneuverSpacingMultiplier)
            self.longSegment = longSegment
        }

        func distance(
            for speed: CLLocationSpeed,
            maneuverSpacings: [CLLocationDistance],
            distanceToTurn: CLLocationDistance
        ) -> CLLocationDistance {
            let forwardSpeed = speed.isFinite ? max(0, speed) : 0
            let spacings = maneuverSpacings.filter { $0.isFinite && $0 > 0 }.sorted()
            let midpoint = spacings.count / 2
            let typicalSpacing = spacings.isEmpty
                ? distanceRange.upperBound
                : (spacings[(spacings.count - 1) / 2] + spacings[midpoint]) / 2 * maneuverSpacingMultiplier
            let speedDistance = distanceRange.lowerBound + forwardSpeed * travelTime
            let normalDistance = max(
                distanceRange.lowerBound, min(distanceRange.upperBound, speedDistance, typicalSpacing)
            )
            let weight = longSegment?.weight(for: distanceToTurn) ?? 0
            guard weight > 0 else { return normalDistance }
            let extendedDistance = max(normalDistance, distanceToTurn)
            return normalDistance + (extendedDistance - normalDistance) * weight
        }
    }

    public struct BearingAnticipation: Equatable {
        let lookaheadDistance: CLLocationDistance
        let maximumDeviation: CLLocationDirection
        let minimumSpeed: CLLocationSpeed

        /// Looks ahead along the route by a distance in meters, limiting the difference
        /// from the rider's course in degrees. Minimum speed is in meters per second.
        public init(
            lookaheadDistance: CLLocationDistance,
            maximumDeviation: CLLocationDirection,
            minimumSpeed: CLLocationSpeed
        ) {
            self.lookaheadDistance = max(0, lookaheadDistance)
            self.maximumDeviation = min(180, max(0, maximumDeviation))
            self.minimumSpeed = max(0, minimumSpeed)
        }
    }

    public struct LowSpeedCenterStabilization: Equatable {
        let maximumScreenShift: CGFloat
        let maximumSpeed: CLLocationSpeed

        /// Ignores camera center shifts of up to maximumScreenShift screen points
        /// at speeds up to maximumSpeed meters per second.
        public init(maximumScreenShift: CGFloat, maximumSpeed: CLLocationSpeed) {
            self.maximumScreenShift = max(0, maximumScreenShift)
            self.maximumSpeed = max(0, maximumSpeed)
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
    let maneuverFraming: ManeuverFraming?
    let routeLookahead: RouteLookahead?
    let bearingAnticipation: BearingAnticipation?
    let lowSpeedCenterStabilization: LowSpeedCenterStabilization?

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
    ///   - maneuverFraming: Optionally center the rider and a nearby maneuver together.
    ///   - routeLookahead: Optionally use bounded route geometry for zoom fitting and frame the full approach to nearby turns.
    ///   - bearingAnticipation: Optionally steer the camera slightly into the upcoming road.
    ///   - lowSpeedCenterStabilization: Optionally suppress small camera center changes at low speed.
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
        showsCourseArrow: Bool = true,
        maneuverFraming: ManeuverFraming? = nil,
        routeLookahead: RouteLookahead? = nil,
        bearingAnticipation: BearingAnticipation? = nil,
        lowSpeedCenterStabilization: LowSpeedCenterStabilization? = nil
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
        self.maneuverFraming = maneuverFraming
        self.routeLookahead = routeLookahead
        self.bearingAnticipation = bearingAnticipation
        self.lowSpeedCenterStabilization = lowSpeedCenterStabilization
    }

    func minimumZoom(for speed: CLLocationSpeed) -> Double {
        if speed >= 0, let band = speedZoomBands.first(where: { speed < $0.speedBelow }) {
            return max(zoomRange.lowerBound, band.minimumZoom)
        }
        return zoomRange.lowerBound
    }
}
