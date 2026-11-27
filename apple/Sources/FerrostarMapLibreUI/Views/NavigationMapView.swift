import Combine
import CoreLocation
import FerrostarCore
import struct FerrostarCoreFFI.RouteStep
import FerrostarSwiftUI
import MapKit
import MapLibre
import MapLibreSwiftDSL
import MapLibreSwiftUI
import SwiftUI

/// The most generic map view in Ferrostar.
///
/// This view includes renders a route line and includes a default camera.
/// It does not include other UI elements like instruction banners.
/// This is the basis of higher level views like
/// ``DynamicallyOrientingNavigationView``.
public struct NavigationMapView: View {
    @Environment(\.mapContentInset) private var hostMapContentInset
    @Environment(\.navigationMapViewRouteOverlayConfiguration) private var routeConfig
    @Environment(\.navigationMapViewContentInsetConfiguration) private var contentInsetConfig

    let styleURL: URL
    var mapViewContentInset: UIEdgeInsets = .zero
    var onStyleLoaded: (MLNStyle) -> Void
    var onUserTrackingModeChanged: (MLNUserTrackingMode, Bool) -> Void
    let userLayers: [StyleLayerDefinition]
    let activity: MapActivity
    private let followCameraConfiguration: NavigationFollowCameraConfiguration?
    private let automaticallyAdjustsFollowZoom: Bool
    private let navigationStateUpdates: AnyPublisher<NavigationState?, Never>?
    @State private var maneuverCamera = NavigationManeuverCamera()

    // TODO: Configurable camera and user "puck" rotation modes

    private let navigationState: NavigationState?
    private let locationManagerConfiguration: NavigationLocationManagerConfiguration?
    @State private var defaultNavigatingLocationManager: any NavigationDrivenLocationManager =
        StaticLocationManager(initialLocation: CLLocation())

    // MARK: Camera Settings

    @Binding var camera: MapViewCamera

    /// Initialize a map view tuned for turn by turn navigation.
    ///
    /// - Parameters:
    ///   - styleURL: The map's style url.
    ///   - camera: The camera binding that represents the current camera on the map.
    ///   - navigationState: The current ferrostar navigation state provided by ferrostar core.
    ///   - locationManagerConfiguration: Optional custom managers for navigating/non-navigating modes.
    ///     Keep manager instances stable (do not construct inline in `body`).
    ///   - followCameraConfiguration: Opt in to route-aware course following with the given settings.
    ///     Pass nil to use the map's built-in follow camera.
    ///   - automaticallyAdjustsFollowZoom: Use route progress to adjust zoom in the route-aware camera.
    ///   - navigationStateUpdates: Optional main-thread updates to drive the follow camera between SwiftUI redraws.
    ///   - onStyleLoaded: The map's style has loaded and the camera can be manipulated (e.g. to user tracking).
    ///   - makeMapContent: Custom maplibre symbols to display on the map view.
    public init(
        styleURL: URL,
        camera: Binding<MapViewCamera>,
        navigationState: NavigationState?,
        locationManagerConfiguration: NavigationLocationManagerConfiguration? = nil,
        activity: MapActivity = .standard,
        followCameraConfiguration: NavigationFollowCameraConfiguration? = nil,
        automaticallyAdjustsFollowZoom: Bool = true,
        navigationStateUpdates: AnyPublisher<NavigationState?, Never>? = nil,
        onUserTrackingModeChanged: @escaping (MLNUserTrackingMode, Bool) -> Void = { _, _ in },
        onStyleLoaded: @escaping ((MLNStyle) -> Void),
        @MapViewContentBuilder _ makeMapContent: () -> [StyleLayerDefinition] = { [] }
    ) {
        self.styleURL = styleURL
        _camera = camera
        self.navigationState = navigationState
        self.locationManagerConfiguration = locationManagerConfiguration
        self.onUserTrackingModeChanged = onUserTrackingModeChanged
        self.onStyleLoaded = onStyleLoaded
        userLayers = makeMapContent()
        self.activity = activity
        self.followCameraConfiguration = followCameraConfiguration
        self.automaticallyAdjustsFollowZoom = automaticallyAdjustsFollowZoom
        self.navigationStateUpdates = navigationStateUpdates
    }

    public var body: some View {
        GeometryReader { geometry in
            let viewport = NavigationManeuverCamera.Viewport(
                size: geometry.size, insets: calculatedMapViewInsets(for: geometry).uiEdgeInsets
            )
            MapView(
                makeViewController: makeMapController(),
                styleURL: styleURL,
                camera: $camera,
                locationManager: activeLocationManager,
                activity: activity
            ) {
                // TODO: Create logic and style for route previews. Unless ferrostarCore will handle this internally.
                routeConfig.routeOverlay(navigationState)

                updateCameraIfNeeded()

                // Overlay any additional user layers.
                userLayers
            }
            .mapContentInset(viewport.insets)
            .mapControls {
                // No controls
            }
            .mapCameraDisabled(ownsFollowCamera)
            .onMapUserTrackingModeChanged(onUserTrackingModeChanged)
            .onMapStyleLoaded { style in
                onStyleLoaded(style)
                maneuverCamera.applyLatestUpdate(locationManager: activeNavigatingLocationManager)
            }
            .onChange(of: navigationStateUpdates == nil ? followCameraUpdate(for: navigationState) : nil) { update in
                maneuverCamera.update(update, locationManager: activeNavigatingLocationManager)
            }
            .onReceive(navigationStateUpdates ?? Empty().eraseToAnyPublisher()) { state in
                updateFollowCamera(for: state)
            }
            .onChange(of: streamingCameraSettings) { _ in
                updateFollowCamera(for: navigationState)
            }
            .onChange(of: viewport) { _ in
                guard ownsFollowCamera, followCameraConfiguration?.maneuverFraming != nil else { return }
                // Wait for the map representable to apply the new bounds and insets.
                Task { @MainActor in
                    maneuverCamera.applyLatestUpdate(locationManager: activeNavigatingLocationManager)
                }
            }
            .onAppear {
                updateFollowCamera(for: navigationState)
            }
            .onDisappear { maneuverCamera.stop() }
            .ignoresSafeArea(.all)
        }
    }

    private func makeMapController() -> MLNMapViewController {
        let controller = MLNMapViewController(initialStyleURL: styleURL, activity: activity)
        maneuverCamera.attach(to: controller.mapView)
        return controller
    }

    private func calculatedMapViewInsets(for geometry: GeometryProxy) -> NavigationMapViewContentInsetMode {
        if navigationState?.isNavigating == true {
            return contentInsetConfig.bundle
                .dynamicWithCameraState(camera.state, isLandscape: geometry.isLandscape)(geometry)
        }

        if let hostMapContentInset {
            return .edgeInset(hostMapContentInset)
        }

        switch camera.state {
        case .rect, .showcase:
            if geometry.isLandscape {
                return contentInsetConfig.getShowcaseLandscapeInset(for: geometry)
            } else {
                return contentInsetConfig.getShowcasePortraitInset(for: geometry)
            }
        default:
            return .edgeInset(UIEdgeInsets(
                top: geometry.safeAreaInsets.top,
                left: geometry.safeAreaInsets.leading,
                bottom: geometry.safeAreaInsets.bottom,
                right: geometry.safeAreaInsets.trailing
            ))
        }
    }

    private var ownsFollowCamera: Bool {
        followCameraConfiguration != nil && navigationState?.isNavigating == true &&
            camera.isTrackingUserLocationWithCourse
    }

    private struct StreamingCameraSettings: Equatable {
        let camera: MapViewCamera
        let configuration: NavigationFollowCameraConfiguration?
        let automaticallyAdjustsZoom: Bool
    }

    private var streamingCameraSettings: StreamingCameraSettings? {
        guard navigationStateUpdates != nil else { return nil }
        return .init(camera: camera, configuration: followCameraConfiguration,
                     automaticallyAdjustsZoom: automaticallyAdjustsFollowZoom)
    }

    private func updateFollowCamera(for state: NavigationState?) {
        maneuverCamera.update(followCameraUpdate(for: state), locationManager: activeNavigatingLocationManager)
    }

    private func followCameraUpdate(for navigationState: NavigationState?) -> NavigationManeuverCamera.Update? {
        guard let followCameraConfiguration, navigationState?.isNavigating == true,
              let navigationState, let userLocation = navigationState.preferredUserLocation,
              case let .trackingUserLocationWithCourse(zoom, pitch, _) = camera.state
        else { return nil }

        let routeLocation = userLocation.clLocation
        let puckLocation = preparedPuckLocation(for: routeLocation)
        let location = followCameraLocation(from: routeLocation, using: puckLocation)
        let progress: NavigationManeuverCamera.RouteProgress?
        if navigationState.currentDeviation == .noDeviation, !navigationState.isCalculatingNewRoute,
           let steps = navigationState.remainingSteps,
           let tripProgress = navigationState.currentProgress,
           tripProgress.distanceToNextManeuver.isFinite, tripProgress.distanceToNextManeuver >= 0 {
            let distance = tripProgress.distanceToNextManeuver
            let currentStep = steps.first
            let tracksRoundaboutExit = automaticallyAdjustsFollowZoom &&
                (followCameraConfiguration.maneuverFraming?.roundaboutExitZoomHoldDistance ?? 0) > 0
            let currentStepStart = tracksRoundaboutExit
                ? currentStep?.geometry.first.flatMap {
                    NavigationManeuverCamera.RouteProgress.Turn(validating: $0.clLocationCoordinate2D)
                }
                : nil
            let outgoingStep = steps.dropFirst().first
            let nextTurn = (outgoingStep?.geometry.first?.clLocationCoordinate2D)
                .flatMap(NavigationManeuverCamera.RouteProgress.Turn.init(validating:))
            let outgoingPath: [NavigationManeuverCamera.RouteProgress.Turn]
            let compoundManeuvers: NavigationManeuverCamera.RouteProgress.CompoundManeuvers?
            if let framing = followCameraConfiguration.maneuverFraming, let outgoingStep, let nextTurn,
               automaticallyAdjustsFollowZoom, distance < framing.distanceRange.upperBound {
                compoundManeuvers = makeCompoundManeuvers(
                    in: steps, from: nextTurn, outgoingStep: outgoingStep, framing: framing
                )
                // The compound path already includes the outgoing preview for the second turn.
                outgoingPath = compoundManeuvers == nil ? NavigationManeuverCamera.routePrefix(
                    from: nextTurn,
                    through: outgoingStep.geometry.dropFirst().lazy.map(\.clLocationCoordinate2D),
                    distance: framing.outgoingDistance
                ) : []
            } else {
                outgoingPath = []
                compoundManeuvers = nil
            }
            progress = .init(
                remainingStepCount: steps.count,
                distanceToTurn: distance,
                remainingDistance: tripProgress.distanceRemaining,
                currentStepStart: currentStepStart,
                nextTurn: nextTurn,
                startsRoundaboutExitHoldAtNextTurn: tracksRoundaboutExit &&
                    shouldHoldZoomAfterManeuver(currentStep: currentStep, outgoingStep: outgoingStep),
                outgoingPath: outgoingPath,
                compoundManeuvers: compoundManeuvers,
                approach: automaticallyAdjustsFollowZoom ? makeApproach(
                    in: navigationState,
                    steps: steps,
                    from: location,
                    distanceToTurn: distance,
                    configuration: followCameraConfiguration
                ) : nil
            )
        } else {
            progress = nil
        }

        return .init(
            location: location,
            preparedPuckLocation: puckLocation,
            followZoom: zoom,
            pitch: pitch,
            automaticallyAdjustsZoom: automaticallyAdjustsFollowZoom,
            configuration: followCameraConfiguration,
            progress: progress
        )
    }

    private func preparedPuckLocation(for location: CLLocation) -> CLLocation? {
        guard let prepared = activeNavigatingLocationManager.preparedNavigationLocation,
              prepared.timestamp == location.timestamp, prepared.coordinate == location.coordinate else { return nil }
        return prepared
    }

    private func followCameraLocation(from location: CLLocation, using preparedPuckLocation: CLLocation?) -> CLLocation {
        guard !location.course.isFinite || location.course < 0 else { return location }
        let deliveredPuckLocation = navigationStateUpdates == nil ? nil : activeNavigatingLocationManager.lastLocation
        // Reuse a course fallback the host supplied for this exact fix.
        guard let puckLocation = preparedPuckLocation ?? deliveredPuckLocation,
              puckLocation.course.isFinite, puckLocation.course >= 0, puckLocation.timestamp == location.timestamp,
              puckLocation.coordinate == location.coordinate else { return location }
        if puckLocation.speed == location.speed {
            return puckLocation
        }
        // A display fallback may normalize unknown speed. Keep route speed for camera fitting.
        return CLLocation(coordinate: location.coordinate, altitude: location.altitude,
                          horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy,
                          course: puckLocation.course, speed: location.speed, timestamp: location.timestamp)
    }

    private func makeApproach(
        in state: NavigationState,
        steps: [RouteStep],
        from rider: CLLocation,
        distanceToTurn: CLLocationDistance,
        configuration: NavigationFollowCameraConfiguration
    ) -> NavigationManeuverCamera.RouteProgress.Approach? {
        typealias Turn = NavigationManeuverCamera.RouteProgress.Turn
        guard configuration.routeLookahead != nil || configuration.bearingAnticipation != nil,
              case let .navigating(segmentIndex, _, _, _, _, _, _, _, _, _, _) = state.tripState,
              let segmentIndex, let index = Int(exactly: segmentIndex),
              let geometry = steps.first?.geometry, index < geometry.count - 1,
              let origin = Turn(validating: rider.coordinate)
        else { return nil }

        // Ferrostar reports the snapped segment origin. Start at the rider and
        // skip the part of the step we've already traveled, even on a hairpin.
        let remaining = geometry.dropFirst(index + 1)
        let coordinates = remaining.lazy.map(\.clLocationCoordinate2D)
        let outgoing = steps.dropFirst().first?.geometry
        let hasConnectedTurn = routeStepsJoin(
            geometry.last?.clLocationCoordinate2D, outgoing?.first?.clLocationCoordinate2D
        )

        let lookaheadBounds: NavigationManeuverCamera.RouteBounds?
        if let lookahead = configuration.routeLookahead {
            let spacings = steps.dropFirst().prefix(3).map(\.distance)
            let distance = lookahead.distance(
                for: rider.speed, maneuverSpacings: spacings, distanceToTurn: distanceToTurn
            )
            if distance >= distanceToTurn {
                // The full remaining step can be large. Keep only its bounds.
                lookaheadBounds = .init(from: origin.coordinate) { visit in
                    for coordinate in coordinates {
                        if let point = Turn(validating: coordinate) {
                            visit(point)
                        }
                    }
                }
            } else {
                lookaheadBounds = .init(from: origin.coordinate) { visit in
                    NavigationManeuverCamera.visitRoutePrefix(
                        from: origin, through: coordinates, distance: distance, visit: visit
                    )
                }
            }
        } else {
            lookaheadBounds = nil
        }

        let maneuverPath: [Turn]
        if configuration.routeLookahead != nil, let framing = configuration.maneuverFraming,
           distanceToTurn <= framing.distanceRange.upperBound, hasConnectedTurn {
            maneuverPath = NavigationManeuverCamera.routePrefix(
                from: origin, through: coordinates, distance: framing.distanceRange.upperBound + framing.outgoingDistance
            )
        } else {
            maneuverPath = []
        }

        var bearingTarget: Turn?
        if let anticipation = configuration.bearingAnticipation,
           rider.course.isFinite, rider.course >= 0, rider.speed.isFinite, rider.speed >= anticipation.minimumSpeed {
            let afterTurn = hasConnectedTurn && distanceToTurn < anticipation.lookaheadDistance
                ? outgoing?.dropFirst() ?? []
                : []
            let bearingCoordinates = [remaining, afterTurn].lazy.joined().map(\.clLocationCoordinate2D)
            NavigationManeuverCamera.visitRoutePrefix(
                from: origin, through: bearingCoordinates, distance: anticipation.lookaheadDistance
            ) { bearingTarget = $0 }
        }

        return .init(lookaheadBounds: lookaheadBounds, maneuverPath: maneuverPath, bearingTarget: bearingTarget)
    }

    private func routeStepsJoin(_ firstEnd: CLLocationCoordinate2D?, _ secondStart: CLLocationCoordinate2D?) -> Bool {
        guard let firstEnd, let secondStart,
              CLLocationCoordinate2DIsValid(firstEnd), CLLocationCoordinate2DIsValid(secondStart)
        else { return false }
        return CLLocation(latitude: firstEnd.latitude, longitude: firstEnd.longitude)
            .distance(from: CLLocation(latitude: secondStart.latitude, longitude: secondStart.longitude)) <= 10
    }

    private func makeCompoundManeuvers(
        in steps: [RouteStep],
        from firstTurn: NavigationManeuverCamera.RouteProgress.Turn,
        outgoingStep: RouteStep,
        framing: NavigationFollowCameraConfiguration.ManeuverFraming
    ) -> NavigationManeuverCamera.RouteProgress.CompoundManeuvers? {
        typealias Turn = NavigationManeuverCamera.RouteProgress.Turn
        let nearby = framing.compoundManeuverDistance.map { outgoingStep.distance <= $0 } ?? false
        let throughRoundabout = framing.framesRoundaboutsThroughExit &&
            isRoundaboutExitStep(after: steps.first, circulatingStep: outgoingStep)
        guard outgoingStep.distance.isFinite, outgoingStep.distance > 0, outgoingStep.geometry.count > 1,
              nearby || throughRoundabout,
              let nextStep = steps.dropFirst(2).first, throughRoundabout || nextStep.geometry.count > 1,
              let secondStart = nextStep.geometry.first?.clLocationCoordinate2D,
              let secondTurn = Turn(validating: secondStart),
              routeStepsJoin(outgoingStep.geometry.last?.clLocationCoordinate2D, secondStart)
        else { return nil }

        var path = outgoingStep.geometry.compactMap { Turn(validating: $0.clLocationCoordinate2D) }
        path.append(secondTurn)
        NavigationManeuverCamera.visitRoutePrefix(
            from: secondTurn,
            through: nextStep.geometry.dropFirst().lazy.map(\.clLocationCoordinate2D),
            distance: framing.outgoingDistance
        ) { path.append($0) }
        return .init(
            first: firstTurn,
            second: secondTurn,
            stepCountBeforeFirst: steps.count,
            path: path,
            endsAtRoundaboutExit: throughRoundabout
        )
    }

    private func isRoundaboutExitStep(after approach: RouteStep?, circulatingStep: RouteStep) -> Bool {
        let numberedEntry = circulatingStep.roundaboutExitNumber != nil
        let markedEntry = approach.map(hasRoundaboutEntryInstruction) == true
        guard numberedEntry || markedEntry else { return false }

        // OSRM-style routes can have a numbered circulation step without banner instructions.
        return hasRoundaboutExitInstruction(circulatingStep) ||
            (numberedEntry && circulatingStep.visualInstructions.isEmpty)
    }

    private func shouldHoldZoomAfterManeuver(currentStep: RouteStep?, outgoingStep: RouteStep?) -> Bool {
        guard let currentStep, let outgoingStep else { return false }
        if hasRoundaboutExitInstruction(currentStep) ||
            currentStep.visualInstructions.contains(where: { $0.primaryContent.maneuverType == .roundaboutTurn }) {
            return true
        }

        // Some routers describe entry and exit as one maneuver. In that case,
        // use the upcoming maneuver boundary for the hold, just like the route arrow.
        return hasRoundaboutEntryInstruction(currentStep) &&
            !isRoundaboutExitStep(after: currentStep, circulatingStep: outgoingStep)
    }

    private func hasRoundaboutEntryInstruction(_ step: RouteStep) -> Bool {
        step.visualInstructions.contains {
            switch $0.primaryContent.maneuverType {
            case .roundabout, .rotary: return true
            default: return false
            }
        }
    }

    private func hasRoundaboutExitInstruction(_ step: RouteStep) -> Bool {
        step.visualInstructions.contains {
            switch $0.primaryContent.maneuverType {
            case .exitRoundabout, .exitRotary: return true
            default: return false
            }
        }
    }

    private func updateCameraIfNeeded() {
        guard !ownsFollowCamera, let routeLocation = navigationState?.preferredUserLocation?.clLocation else { return }
        let locationManager = activeNavigatingLocationManager
        let location = preparedPuckLocation(for: routeLocation) ?? routeLocation
        // The puck shows only the coordinate and heading.
        if locationManager.lastLocation.coordinate != location.coordinate ||
            locationManager.lastLocation.course != location.course {
            locationManager.lastLocation = location
        }
    }

    private var activeNavigatingLocationManager: any NavigationDrivenLocationManager {
        locationManagerConfiguration?.navigatingLocationManager ?? defaultNavigatingLocationManager
    }

    private var activeLocationManager: (any MLNLocationManager)? {
        if navigationState?.isNavigating == true {
            return activeNavigatingLocationManager
        }
        return locationManagerConfiguration?.nonNavigatingLocationManager
    }
}

#Preview("Navigation Map View") {
    // TODO: Make map URL configurable but gitignored
    let state = NavigationState.modifiedPedestrianExample(droppingNWaypoints: 4)

    guard case let .navigating(_, _, snappedUserLocation: userLocation, _, _, _, _, _, _, _, _) = state.tripState else {
        return EmptyView()
    }

    return NavigationMapView(
        styleURL: URL(string: "https://demotiles.maplibre.org/style.json")!,
        camera: .constant(.center(userLocation.clLocation.coordinate, zoom: 12)),
        navigationState: state,
        onStyleLoaded: { _ in }
    )
}

#Preview("Route-Aware Follow Camera") {
    NavigationMapView(
        styleURL: URL(string: "https://demotiles.maplibre.org/style.json")!,
        camera: .constant(.automotiveNavigation()),
        navigationState: NavigationState.modifiedPedestrianExample(droppingNWaypoints: 4),
        followCameraConfiguration: .init(
            zoomRange: 13...18,
            maneuverPadding: .init(top: 12, left: 12, bottom: 12, right: 12),
            maneuverPitch: .init(distanceRange: 30...100, cruisingPitch: 40)
        ),
        onStyleLoaded: { _ in }
    )
}
