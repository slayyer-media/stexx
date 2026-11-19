import MapKit
import SwiftUI

/// Stexx+ travel mode: pick where to browse from by panning the map or
/// searching a city. The square drawn on the map is the 500 m cell that is
/// sent; others only ever see you somewhere in it, as a rounded distance.
struct TravelModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @State private var model: TravelModeModel?

    var body: some View {
        Group {
            if let model {
                TravelPicker(model: model)
            } else {
                Theme.ink.ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil { model = TravelModeModel(appState: appState, api: api) }
        }
    }
}

/// Opens the travel picker from a navigation stack (Nearby's banner).
struct TravelRoute: Hashable {}

private struct TravelPicker: View {
    @Bindable var model: TravelModeModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var search = TravelPlaceSearch()
    @State private var camera: MapCameraPosition
    @State private var isSearchPresented = false
    @State private var savedCount = 0

    /// About 4 km across: the 500 m cell stays clearly visible.
    private static let span: CLLocationDistance = 4000

    init(model: TravelModeModel) {
        self.model = model
        if let center = model.center {
            _camera = State(initialValue: .region(Self.region(around: center)))
        } else {
            // Start where the phone is (shown on this device only); nothing
            // is sent until "Browse from here".
            _camera = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        map
            .safeAreaInset(edge: .bottom, spacing: 0) { card }
            .navigationTitle("Travel mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .tabBar)
            .searchable(
                text: $search.query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search a city")
            )
            .searchSuggestions {
                ForEach(search.results) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.stexxBody)
                                .foregroundStyle(Theme.frost)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.stexxSub)
                                    .foregroundStyle(Theme.steel)
                            }
                        }
                    }
                }
            }
            .task(id: model.selection) { await model.nameSelection() }
            .sensoryFeedback(.success, trigger: savedCount)
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if let cell = model.selection {
                MapPolygon(coordinates: LocationFuzzer.corners(of: cell).map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .foregroundStyle(Theme.frost.opacity(0.08))
                .stroke(Theme.rim, lineWidth: 1)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            let center = context.region.center
            model.centerChanged(to: .init(latitude: center.latitude, longitude: center.longitude))
        }
        .overlay { reticle }
        .accessibilityLabel("Map. Move it to choose where to browse from.")
    }

    /// Marks the map's center: the point whose cell is selected.
    private var reticle: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.frost.opacity(0.9), lineWidth: 1)
                .frame(width: 14, height: 14)
            Circle()
                .fill(Theme.frost)
                .frame(width: 3, height: 3)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(model.isCurrentPlace ? "Browsing from" : "Browse from")
                Text("Approximate")
                    .stexxLabelStyle(.micro, color: Theme.ice)
                    .fixedSize()
            }

            HStack(spacing: Theme.Spacing.s) {
                Text(placeTitle)
                    .stexxTitleStyle(.title)
                    .foregroundStyle(model.placeName == nil ? Theme.steel : Theme.frost)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if model.isNaming && model.placeName == nil {
                    ProgressView().controlSize(.small).tint(Theme.steel)
                }
            }
            .accessibilityElement(children: .combine)

            Text("Others see you somewhere in this \(StexxFormat.distance(LocationFuzzer.defaultCellMeters)) square, as a rounded distance, never as an exact spot. It's rounded on this phone before it's sent.")
                .font(.stexxSub)
                .foregroundStyle(Theme.steel)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.stexxSub)
                    .foregroundStyle(Theme.danger)
            }

            Button {
                Task { await browse() }
            } label: {
                WideLabel(primaryTitle, systemImage: "airplane")
            }
            .stexxPrimaryButton()
            .disabled(model.selection == nil || model.isSaving || model.isCurrentPlace)

            if model.isOn {
                Button {
                    Task { await turnOff() }
                } label: {
                    WideLabel("Turn off travel mode")
                }
                .stexxSecondaryButton()
                .disabled(model.isSaving)
            }
        }
        .padding(Theme.Spacing.l)
        .blackGlass(in: shape)
        .rimLight(shape)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
    }

    private var placeTitle: String {
        if let name = model.placeName { return name }
        if model.selection == nil { return String(localized: "Move the map") }
        return model.isNaming ? String(localized: "Finding the place…") : String(localized: "Somewhere here")
    }

    private var primaryTitle: LocalizedStringKey {
        if model.isCurrentPlace { return "You're browsing from here" }
        return model.isOn ? "Move here" : "Browse from here"
    }

    // MARK: Actions

    private func pick(_ suggestion: TravelPlaceSearch.Suggestion) {
        isSearchPresented = false
        search.query = ""
        Task {
            guard let point = await search.locate(suggestion) else {
                model.errorMessage = String(localized: "Couldn't find that place. Try moving the map instead.")
                return
            }
            model.errorMessage = nil
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
                camera = .region(Self.region(around: point))
            }
            model.centerChanged(to: point)
            model.suggestName(suggestion.title)
        }
    }

    private func browse() async {
        if await model.browseFromSelection() {
            savedCount += 1
            dismiss()
        }
    }

    private func turnOff() async {
        if await model.turnOff() {
            savedCount += 1
            dismiss()
        }
    }

    private static func region(around point: TravelModeModel.Point) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            latitudinalMeters: span,
            longitudinalMeters: span
        )
    }
}

// MARK: - Nearby banner

/// Nearby's travel-mode pill: where you're browsing from, tap to change,
/// × to turn it off. Flat (it scrolls with the grid), no rim light.
struct TravelBanner: View {
    let placeName: String?
    var isBusy = false
    let onOpen: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        HStack(spacing: Theme.Spacing.s) {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "airplane")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ice)
                    Text("Browsing from")
                        .stexxLabelStyle(.micro)
                        .fixedSize()
                    Text(placeName ?? String(localized: "your travel spot"))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.frost)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens travel mode")

            if isBusy {
                ProgressView().controlSize(.mini).tint(Theme.steel)
            } else {
                Button(action: onTurnOff) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.steel)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn off travel mode")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(shape.fill(Theme.ink1))
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

#Preview("Picker") {
    NavigationStack {
        TravelModeView()
    }
    .previewEnvironment(plus: true)
}

#Preview("Banner") {
    TravelBanner(placeName: "Lisbon, Portugal", onOpen: {}, onTurnOff: {})
        .padding()
        .background(Theme.ink)
        .preferredColorScheme(.dark)
}
