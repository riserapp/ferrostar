import CoreLocation
import MapLibre
import QuartzCore
import UIKit

/// Applies one native camera transition for each reported navigation fix.
@MainActor
final class NavigationManeuverCamera {
    struct RouteProgress: Equatable {
        struct Turn: Equatable {
            let latitude: CLLocationDegrees
            let longitude: CLLocationDegrees

            init(coordinate: CLLocationCoordinate2D) {
                latitude = coordinate.latitude
                longitude = coordinate.longitude
            }
        }

        let remainingStepCount: Int
        let distanceToTurn: CLLocationDistance
        let nextTurn: Turn?
    }

    struct Update: Equatable {
        let location: CLLocation
        let followZoom: Double
        let pitch: Double
        let automaticallyAdjustsZoom: Bool
        let configuration: NavigationFollowCameraConfiguration
        let progress: RouteProgress?
    }

    private weak var map: MLNMapView?
    private var latestUpdate: Update?
    private var lastAppliedUpdate: Update?
    private var previousProgress: RouteProgress?
    private var closeTurnZoom: Double?
    private var courseArrow: CAShapeLayer?

    private func makeCourseArrow() -> CAShapeLayer {
        let arrow = CAShapeLayer()
        arrow.bounds = CGRect(x: 0, y: 0, width: 32, height: 36)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 16, y: 2))
        path.addLine(to: CGPoint(x: 30, y: 33))
        path.addLine(to: CGPoint(x: 16, y: 27))
        path.addLine(to: CGPoint(x: 2, y: 33))
        path.close()
        arrow.path = path.cgPath
        arrow.strokeColor = UIColor.white.cgColor
        arrow.lineWidth = 2.5
        arrow.lineJoin = .round
        arrow.zPosition = 1
        return arrow
    }

    func attach(to map: MLNMapView) {
        stop()
        self.map = map
    }

    func stop() {
        courseArrow?.removeFromSuperlayer()
        courseArrow?.removeAllAnimations()
        latestUpdate = nil
        lastAppliedUpdate = nil
        previousProgress = nil
        closeTurnZoom = nil
    }

    func update(_ update: Update?, locationManager: any NavigationDrivenLocationManager) {
        guard let update else {
            stop()
            return
        }
        if let latestUpdate, update.location.timestamp < latestUpdate.location.timestamp {
            return
        }
        latestUpdate = update
        applyLatestUpdate(locationManager: locationManager)
    }

    func applyLatestUpdate(locationManager: any NavigationDrivenLocationManager) {
        guard let update = latestUpdate,
              let map, map.style != nil, !map.bounds.isEmpty,
              CLLocationCoordinate2DIsValid(update.location.coordinate)
        else { return }

        let previous = lastAppliedUpdate
        let configuration = update.configuration
        let configurationChanged = previous?.configuration != configuration
        let elapsed = previous.map { update.location.timestamp.timeIntervalSince($0.location.timestamp) } ?? 0
        let settingsChanged = previous.map {
            $0.followZoom != update.followZoom || $0.pitch != update.pitch ||
                $0.automaticallyAdjustsZoom != update.automaticallyAdjustsZoom || configurationChanged
        } ?? true
        // Route metadata can change without a new fix. Keep it for the next transition.
        guard elapsed > 0 || settingsChanged else { return }

        let lastLocation = locationManager.lastLocation
        let hasNewPosition = lastLocation.coordinate.latitude != update.location.coordinate.latitude ||
            lastLocation.coordinate.longitude != update.location.coordinate.longitude ||
            lastLocation.course != update.location.course

        if map.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
            if hasNewPosition { locationManager.lastLocation = update.location }
            return
        }

        if configurationChanged {
            previousProgress = nil
            closeTurnZoom = nil
        }
        lastAppliedUpdate = update
        let puckInterval = update.location.timestamp.timeIntervalSince(lastLocation.timestamp)
        let interval = hasNewPosition && puckInterval > 0 ? puckInterval : elapsed
        // Keep center, bearing, pitch and zoom on the measured location cadence.
        let duration = interval > 0 ? min(1, max(0.15, interval)) : 0.45
        let desiredZoom = min(map.maximumZoomLevel, max(map.minimumZoomLevel, targetZoom(for: update, on: map)))
        let currentZoom = map.zoomLevel
        let zoomDelta = desiredZoom - currentZoom
        let zoom: Double
        if update.automaticallyAdjustsZoom, abs(zoomDelta) <= configuration.zoomDeadband {
            zoom = currentZoom
        } else if update.automaticallyAdjustsZoom {
            // The next maneuver can be much farther away on the first fix after a turn.
            let transition = zoomDelta < 0 ? configuration.zoomOut : configuration.zoomIn
            let response = 1 - exp(-duration / transition.responseTime)
            zoom = limitedMove(
                from: currentZoom,
                toward: currentZoom + zoomDelta * response,
                maximumChange: transition.maximumLevelsPerSecond * duration
            )
        } else {
            zoom = desiredZoom
        }

        var desiredPitch = update.pitch
        if let pitch = configuration.maneuverPitch, let progress = update.progress {
            let distance = pitch.distanceRange
            let span = distance.upperBound - distance.lowerBound
            let fraction = span > 0
                ? (progress.distanceToTurn - distance.lowerBound) / span
                : (progress.distanceToTurn > distance.lowerBound ? 1.0 : 0.0)
            desiredPitch = Double(pitch.cruisingPitch) * easedFraction(fraction)
            if map.minimumPitch > 0 { map.minimumPitch = 0 }
            if map.maximumPitch < pitch.cruisingPitch { map.maximumPitch = pitch.cruisingPitch }
        }

        // Native location updates still drive the puck. This controller owns the camera while following.
        if map.userTrackingMode != .none {
            map.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        }
        if !map.showsUserLocation {
            map.showsUserLocation = true
        }

        let pose = map.camera
        pose.centerCoordinate = update.location.coordinate
        if update.location.course >= 0, update.location.course.isFinite {
            let headingDelta = (update.location.course - pose.heading).remainder(dividingBy: 360)
            let heading = limitedMove(
                from: pose.heading,
                toward: pose.heading + headingDelta,
                maximumChange: configuration.maximumHeadingDegreesPerSecond * duration
            )
            pose.heading = (heading + 360).truncatingRemainder(dividingBy: 360)
        }
        pose.pitch = limitedMove(
            from: Double(pose.pitch),
            toward: desiredPitch,
            maximumChange: configuration.maximumPitchDegreesPerSecond * duration
        )
        pose.altitude = MLNAltitudeForZoomLevel(zoom, pose.pitch, update.location.coordinate.latitude, map.bounds.size)
        if hasNewPosition {
            locationManager.lastLocation = update.location
        }
        if configuration.showsCourseArrow {
            updateCourseArrow(on: map, course: update.location.course, heading: pose.heading, duration: duration)
        } else {
            courseArrow?.removeFromSuperlayer()
            courseArrow?.removeAllAnimations()
        }
        map.setCamera(
            pose,
            withDuration: duration,
            animationTimingFunction: CAMediaTimingFunction(name: .linear),
            edgePadding: .zero,
            completionHandler: nil
        )
    }

    private func updateCourseArrow(
        on map: MLNMapView,
        course: CLLocationDirection,
        heading: CLLocationDirection,
        duration: TimeInterval
    ) {
        guard let userLocation = map.userLocation, let annotationView = map.view(for: userLocation) else { return }

        // The native annotation still owns placement and interpolation of the puck.
        let targetAngle = (course.isFinite && course >= 0 ? course - heading : 0) * .pi / 180
        let arrow = courseArrow ?? makeCourseArrow()
        courseArrow = arrow
        let isInstalled = arrow.superlayer === annotationView.layer
        let transform = (arrow.presentation() ?? arrow).transform
        let displayedAngle = Double(atan2(transform.m12, transform.m11))
        let angleDelta = (targetAngle - displayedAngle).remainder(dividingBy: 2 * .pi)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.position = CGPoint(x: annotationView.bounds.midX, y: annotationView.bounds.midY)
        arrow.fillColor = map.tintColor.cgColor
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(targetAngle)))
        if !isInstalled {
            annotationView.layer.addSublayer(arrow)
        }
        CATransaction.commit()

        if isInstalled {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = displayedAngle
            rotation.toValue = displayedAngle + angleDelta
            rotation.duration = duration
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            arrow.add(rotation, forKey: "courseRotation")
        }
    }

    private func targetZoom(for update: Update, on map: MLNMapView) -> Double {
        guard update.automaticallyAdjustsZoom, let progress = update.progress else {
            previousProgress = nil
            closeTurnZoom = nil
            return update.followZoom
        }

        let configuration = update.configuration
        if let previousProgress, progress.remainingStepCount != previousProgress.remainingStepCount {
            if let hold = configuration.nearbyTurnHold,
               progress.remainingStepCount == previousProgress.remainingStepCount - 1,
               previousProgress.nextTurn != nil, previousProgress.distanceToTurn <= hold.completedTurnDistance,
               progress.nextTurn != nil, progress.distanceToTurn <= hold.nextTurnDistance {
                closeTurnZoom = min(configuration.zoomRange.upperBound, map.zoomLevel)
            } else {
                // Start easing back toward the fitted zoom as soon as there's room after the turn.
                closeTurnZoom = nil
            }
        }
        previousProgress = progress

        let fittedZoom = zoomFittingTurn(
            progress.nextTurn, from: update.location.coordinate, on: map, padding: configuration.maneuverPadding
        )
        let fittedTarget = min(
            configuration.zoomRange.upperBound,
            max(configuration.minimumZoom(for: update.location.speed), fittedZoom)
        )
        return max(fittedTarget, closeTurnZoom ?? fittedTarget)
    }

    private func zoomFittingTurn(
        _ turn: RouteProgress.Turn?,
        from location: CLLocationCoordinate2D,
        on map: MLNMapView,
        padding: UIEdgeInsets
    ) -> Double {
        guard let turn, location.latitude != turn.latitude || location.longitude != turn.longitude else {
            return map.zoomLevel
        }

        // Fit the shorter longitude span for a maneuver across the antimeridian.
        let longitude = location.longitude + (turn.longitude - location.longitude).remainder(dividingBy: 360)
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: min(location.latitude, turn.latitude),
                                       longitude: min(location.longitude, longitude)),
            ne: CLLocationCoordinate2D(latitude: max(location.latitude, turn.latitude),
                                       longitude: max(location.longitude, longitude))
        )
        let viewport = map.bounds.inset(by: map.contentInset).inset(by: padding)
        guard !viewport.isEmpty else { return map.zoomLevel }

        let camera = map.camera(map.camera, fitting: bounds, edgePadding: padding)
        let zoom = MLNZoomLevelForAltitude(
            camera.altitude, camera.pitch, camera.centerCoordinate.latitude, map.bounds.size
        )
        return zoom.isFinite ? zoom : map.zoomLevel
    }

    private func limitedMove(from current: Double, toward target: Double, maximumChange: Double) -> Double {
        current + min(maximumChange, max(-maximumChange, target - current))
    }

    private func easedFraction(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }
}
