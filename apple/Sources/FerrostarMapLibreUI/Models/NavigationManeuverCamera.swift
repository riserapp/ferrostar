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

            init?(validating coordinate: CLLocationCoordinate2D) {
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                self.init(coordinate: coordinate)
            }

            var coordinate: CLLocationCoordinate2D {
                .init(latitude: latitude, longitude: longitude)
            }
        }

        struct CompoundManeuvers: Equatable {
            let first: Turn
            let second: Turn
            let stepCountBeforeFirst: Int
            let path: [Turn]

            func containsNextTurn(in progress: RouteProgress) -> Bool {
                (progress.remainingStepCount == stepCountBeforeFirst && progress.nextTurn == first) ||
                    isApproachingSecond(in: progress)
            }

            func isApproachingSecond(in progress: RouteProgress) -> Bool {
                progress.remainingStepCount == stepCountBeforeFirst - 1 && progress.nextTurn == second
            }
        }

        let remainingStepCount: Int
        let distanceToTurn: CLLocationDistance
        let nextTurn: Turn?
        let outgoingPath: [Turn]
        let compoundManeuvers: CompoundManeuvers?
    }

    struct Update: Equatable {
        let location: CLLocation
        let followZoom: Double
        let pitch: Double
        let automaticallyAdjustsZoom: Bool
        let configuration: NavigationFollowCameraConfiguration
        let progress: RouteProgress?
    }

    struct Viewport: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets
    }

    private weak var map: MLNMapView?
    private var latestUpdate: Update?
    private var lastAppliedUpdate: Update?
    private var lastAppliedViewport: Viewport?
    private var previousProgress: RouteProgress?
    private var closeTurnZoom: Double?
    private var compoundManeuvers: RouteProgress.CompoundManeuvers?
    private var courseArrow: CAShapeLayer?

    static func outgoingPath(
        from turn: RouteProgress.Turn,
        through coordinates: some Sequence<CLLocationCoordinate2D>,
        distance: CLLocationDistance
    ) -> [RouteProgress.Turn] {
        guard distance > 0 else { return [] }
        var path: [RouteProgress.Turn] = []
        var previous = turn
        var previousLocation = CLLocation(latitude: turn.latitude, longitude: turn.longitude)
        var remaining = distance
        for coordinate in coordinates {
            guard let point = RouteProgress.Turn(validating: coordinate) else { break }
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let segment = location.distance(from: previousLocation)
            guard segment.isFinite, segment > 0 else { continue }
            if segment >= remaining {
                path.append(.init(coordinate: interpolatedCoordinate(
                    from: previous.coordinate, to: point.coordinate, fraction: remaining / segment
                )))
                break
            }
            path.append(point)
            remaining -= segment
            previous = point
            previousLocation = location
        }
        return path
    }

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
        lastAppliedViewport = nil
        previousProgress = nil
        closeTurnZoom = nil
        compoundManeuvers = nil
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
        let viewport = Viewport(size: map.bounds.size, insets: map.contentInset)
        let viewportChanged = configuration.maneuverFraming != nil && lastAppliedViewport != viewport
        let elapsed = previous.map { update.location.timestamp.timeIntervalSince($0.location.timestamp) } ?? 0
        let settingsChanged = previous.map {
            $0.followZoom != update.followZoom || $0.pitch != update.pitch ||
                $0.automaticallyAdjustsZoom != update.automaticallyAdjustsZoom || configurationChanged
        } ?? true
        // Route metadata can change without a new fix. Keep it for the next transition.
        guard elapsed > 0 || settingsChanged || viewportChanged else { return }

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
            compoundManeuvers = nil
        }
        lastAppliedUpdate = update
        lastAppliedViewport = viewport
        let puckInterval = update.location.timestamp.timeIntervalSince(lastLocation.timestamp)
        let interval = hasNewPosition && puckInterval > 0 ? puckInterval : elapsed
        // Keep center, bearing, pitch and zoom on the measured location cadence.
        let duration = interval > 0 ? min(1, max(0.15, interval)) : 0.45
        let rider = update.location.coordinate
        let nextTurn = update.progress?.nextTurn.map { [$0] } ?? []
        let baseFit = update.automaticallyAdjustsZoom
            ? cameraFitting(nextTurn, from: rider, using: map.camera, on: map, padding: configuration.maneuverPadding)
            : nil

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
        pose.centerCoordinate = rider
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
        let activeCompound = compoundManeuvers(for: update)
        var framingWeight = maneuverFramingWeight(for: update)
        if let activeCompound, let progress = update.progress, activeCompound.isApproachingSecond(in: progress) {
            // The second turn just became the next one. Keep the whole pair in view through the handoff.
            framingWeight = 1
        }
        let maneuverFit: (center: CLLocationCoordinate2D, zoom: Double)?
        if framingWeight > 0, let framing = configuration.maneuverFraming {
            let padding = framing.viewportPadding
            maneuverFit = cameraFitting(
                activeCompound?.path ?? nextTurn + (update.progress?.outgoingPath ?? []),
                from: rider,
                using: pose,
                on: map,
                padding: .init(top: padding, left: padding, bottom: padding, right: padding)
            )
        } else {
            maneuverFit = nil
        }
        var desiredZoom = targetZoom(for: update, on: map, fittedZoom: baseFit?.zoom)
        if let maneuverFit, maneuverFit.zoom < desiredZoom {
            let fitZoom = max(configuration.zoomRange.lowerBound, maneuverFit.zoom)
            desiredZoom += (fitZoom - desiredZoom) * framingWeight
        }
        desiredZoom = min(map.maximumZoomLevel, max(map.minimumZoomLevel, desiredZoom))
        let zoom = animatedZoom(toward: desiredZoom, from: map.zoomLevel, for: update, duration: duration)
        if let maneuverFit {
            // Keep the rider in frame while the existing zoom animation widens the map.
            let centerWeight = min(framingWeight, pow(2, maneuverFit.zoom - zoom))
            pose.centerCoordinate = Self.interpolatedCoordinate(
                from: rider, to: maneuverFit.center, fraction: centerWeight
            )
        }
        pose.altitude = MLNAltitudeForZoomLevel(zoom, pose.pitch, pose.centerCoordinate.latitude, map.bounds.size)
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

    private func targetZoom(for update: Update, on map: MLNMapView, fittedZoom: Double?) -> Double {
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

        let fittedTarget = min(
            configuration.zoomRange.upperBound,
            max(configuration.minimumZoom(for: update.location.speed), fittedZoom ?? map.zoomLevel)
        )
        return max(fittedTarget, closeTurnZoom ?? fittedTarget)
    }

    private func cameraFitting(
        _ points: [RouteProgress.Turn],
        from location: CLLocationCoordinate2D,
        using pose: MLNMapCamera,
        on map: MLNMapView,
        padding: UIEdgeInsets
    ) -> (center: CLLocationCoordinate2D, zoom: Double)? {
        guard !points.isEmpty else { return nil }
        let viewport = map.bounds.inset(by: map.contentInset).inset(by: padding)
        guard !viewport.isEmpty else { return nil }

        var bounds = MLNCoordinateBounds(sw: location, ne: location)
        for point in points {
            // Preserve the short span across the antimeridian.
            let longitude = location.longitude + (point.longitude - location.longitude).remainder(dividingBy: 360)
            bounds.sw.latitude = min(bounds.sw.latitude, point.latitude)
            bounds.ne.latitude = max(bounds.ne.latitude, point.latitude)
            bounds.sw.longitude = min(bounds.sw.longitude, longitude)
            bounds.ne.longitude = max(bounds.ne.longitude, longitude)
        }
        guard bounds.sw.latitude != bounds.ne.latitude || bounds.sw.longitude != bounds.ne.longitude else { return nil }
        let camera = map.camera(pose, fitting: bounds, edgePadding: padding)
        let zoom = MLNZoomLevelForAltitude(
            camera.altitude, camera.pitch, camera.centerCoordinate.latitude, map.bounds.size
        )
        guard zoom.isFinite, CLLocationCoordinate2DIsValid(camera.centerCoordinate) else { return nil }
        return (camera.centerCoordinate, zoom)
    }

    private func maneuverFramingWeight(for update: Update) -> Double {
        guard update.automaticallyAdjustsZoom,
              let range = update.configuration.maneuverFraming?.distanceRange,
              let distance = update.progress?.distanceToTurn else { return 0 }
        if distance <= range.lowerBound { return 1 }
        if distance >= range.upperBound { return 0 }
        return 1 - easedFraction((distance - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func compoundManeuvers(for update: Update) -> RouteProgress.CompoundManeuvers? {
        guard update.automaticallyAdjustsZoom, let progress = update.progress else {
            compoundManeuvers = nil
            return nil
        }
        if let compoundManeuvers, compoundManeuvers.containsNextTurn(in: progress) {
            return compoundManeuvers
        }
        compoundManeuvers = progress.compoundManeuvers
        return compoundManeuvers
    }

    private func animatedZoom(toward target: Double, from current: Double, for update: Update, duration: TimeInterval) -> Double {
        guard update.automaticallyAdjustsZoom else { return target }
        let delta = target - current
        guard abs(delta) > update.configuration.zoomDeadband else { return current }
        let transition = delta < 0 ? update.configuration.zoomOut : update.configuration.zoomIn
        let response = 1 - exp(-duration / transition.responseTime)
        return limitedMove(
            from: current,
            toward: current + delta * response,
            maximumChange: transition.maximumLevelsPerSecond * duration
        )
    }

    private static func interpolatedCoordinate(
        from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, fraction: Double
    ) -> CLLocationCoordinate2D {
        let longitudeDelta = (end.longitude - start.longitude).remainder(dividingBy: 360)
        return .init(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: (start.longitude + longitudeDelta * fraction).remainder(dividingBy: 360)
        )
    }

    private func limitedMove(from current: Double, toward target: Double, maximumChange: Double) -> Double {
        current + min(maximumChange, max(-maximumChange, target - current))
    }

    private func easedFraction(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }
}
