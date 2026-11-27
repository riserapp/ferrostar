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
            .onChange(of: followCameraUpdate) { update in
                maneuverCamera.update(update, locationManager: activeNavigatingLocationManager)
            }
            .onChange(of: viewport) { _ in
                guard ownsFollowCamera, followCameraConfiguration?.maneuverFraming != nil else { return }
                // Wait for the map representable to apply the new bounds and insets.
                Task { @MainActor in
                    maneuverCamera.applyLatestUpdate(locationManager: activeNavigatingLocationManager)
                }
            }
            .onAppear {
                maneuverCamera.update(followCameraUpdate, locationManager: activeNavigatingLocationManager)
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

    private var followCameraUpdate: NavigationManeuverCamera.Update? {
        guard ownsFollowCamera, let followCameraConfiguration,
              let navigationState, let userLocation = navigationState.preferredUserLocation,
              case let .trackingUserLocationWithCourse(zoom, pitch, _) = camera.state
        else { return nil }

        let progress: NavigationManeuverCamera.RouteProgress?
        if navigationState.currentDeviation == .noDeviation, !navigationState.isCalculatingNewRoute,
           let steps = navigationState.remainingSteps,
           let distance = navigationState.currentProgress?.distanceToNextManeuver,
           distance.isFinite, distance >= 0 {
            let outgoingStep = steps.dropFirst().first
            let nextTurn = (outgoingStep?.geometry.first?.clLocationCoordinate2D)
                .flatMap(NavigationManeuverCamera.RouteProgress.Turn.init(validating:))
            let outgoingPath: [NavigationManeuverCamera.RouteProgress.Turn]
            let compoundManeuvers: NavigationManeuverCamera.RouteProgress.CompoundManeuvers?
            if let framing = followCameraConfiguration.maneuverFraming, let outgoingStep, let nextTurn,
               automaticallyAdjustsFollowZoom, distance < framing.distanceRange.upperBound {
                outgoingPath = NavigationManeuverCamera.outgoingPath(
                    from: nextTurn,
                    through: outgoingStep.geometry.dropFirst().lazy.map(\.clLocationCoordinate2D),
                    distance: framing.outgoingDistance
                )
                compoundManeuvers = makeCompoundManeuvers(
                    in: steps, from: nextTurn, outgoingStep: outgoingStep, framing: framing
                )
            } else {
                outgoingPath = []
                compoundManeuvers = nil
            }
            progress = .init(
                remainingStepCount: steps.count,
                distanceToTurn: distance,
                nextTurn: nextTurn,
                outgoingPath: outgoingPath,
                compoundManeuvers: compoundManeuvers
            )
        } else {
            progress = nil
        }

        return .init(
            location: userLocation.clLocation,
            followZoom: zoom,
            pitch: pitch,
            automaticallyAdjustsZoom: automaticallyAdjustsFollowZoom,
            configuration: followCameraConfiguration,
            progress: progress
        )
    }

    private func makeCompoundManeuvers(
        in steps: [RouteStep],
        from firstTurn: NavigationManeuverCamera.RouteProgress.Turn,
        outgoingStep: RouteStep,
        framing: NavigationFollowCameraConfiguration.ManeuverFraming
    ) -> NavigationManeuverCamera.RouteProgress.CompoundManeuvers? {
        typealias Turn = NavigationManeuverCamera.RouteProgress.Turn
        guard let maximumSeparation = framing.compoundManeuverDistance,
              outgoingStep.distance > 0, outgoingStep.distance <= maximumSeparation,
              let nextStep = steps.dropFirst(2).first, nextStep.geometry.count > 1,
              let secondStart = nextStep.geometry.first?.clLocationCoordinate2D,
              let secondTurn = Turn(validating: secondStart),
              let firstEnd = outgoingStep.geometry.last?.clLocationCoordinate2D,
              CLLocationCoordinate2DIsValid(firstEnd),
              CLLocation(latitude: firstEnd.latitude, longitude: firstEnd.longitude)
                .distance(from: CLLocation(latitude: secondStart.latitude, longitude: secondStart.longitude)) <= 10
        else { return nil }

        let pathBetweenTurns = outgoingStep.geometry.compactMap { Turn(validating: $0.clLocationCoordinate2D) }
        let outgoingPath = NavigationManeuverCamera.outgoingPath(
            from: secondTurn,
            through: nextStep.geometry.dropFirst().lazy.map(\.clLocationCoordinate2D),
            distance: framing.outgoingDistance
        )
        return .init(
            first: firstTurn,
            second: secondTurn,
            stepCountBeforeFirst: steps.count,
            path: pathBetweenTurns + [secondTurn] + outgoingPath
        )
    }

    private func updateCameraIfNeeded() {
        guard !ownsFollowCamera else { return }
        if let userLocation = navigationState?.preferredUserLocation,
           // There is no reason to push an update if the coordinate and heading are the same.
           // That's all that gets displayed, so it's all that MapLibre should care about.
           activeNavigatingLocationManager.lastLocation.coordinate != userLocation.coordinates.clLocationCoordinate2D ||
           activeNavigatingLocationManager.lastLocation.course != userLocation.clLocation.course
        {
            activeNavigatingLocationManager.lastLocation = userLocation.clLocation
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
