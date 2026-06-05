//
//  ContentView.swift
//  BAHAR QC
//
//  Landing screen + AR session host. Mirrors the prototype's flow:
//  1. Landing card explains the experience.
//  2. Start AR → presents an ARKit horizontal-plane scene with a water plane
//     that rises to the GPS-looked-up flood depth.
//

import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var showingAR = false

    var body: some View {
        #if os(iOS)
        if showingAR {
            ARSessionView(onExit: { showingAR = false })
        } else {
            LandingView(onStart: { showingAR = true })
        }
        #else
        LandingView(onStart: {})
            .overlay(alignment: .bottom) {
                Text("AR features require iOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        #endif
    }
}

// MARK: - Landing

private struct LandingView: View {
    let onStart: () -> Void

    @ViewBuilder
    private var noahLogo: some View {
        #if os(iOS)
        if let uiImage = UIImage(named: "NOAH LOGO") {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            noahLogo
                .frame(maxWidth: 220, maxHeight: 80)

            VStack(spacing: 6) {
                Text("BAHAR")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .tracking(2)
                Text("Baha Augmented Reality")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Metro Manila's First AR Flood App")
                    .font(.headline)
                Text("Powered by UP NOAH's 100-year flood return model. Point your camera at the ground to see the expected flood depth at your current location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()

            Button(action: onStart) {
                Text("Start AR")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Text("Prototype — designed for outdoor, ground-level use. Geolocation accuracy may vary depending on GPS signal and device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - AR session

#if os(iOS)
private struct ARSessionView: View {
    let onExit: () -> Void

    @StateObject private var location = LocationManager()
    @State private var flood = FloodData()
    @State private var floodReady = false
    @State private var loadError: String?
    @State private var depth: Double = 0
    @State private var gauge: MMDAGauge = .none
    @State private var groundFound = false
    @State private var arError: String?
    @State private var underwater: Bool = false

    var body: some View {
        ZStack {
            ARContainerView(
                floodDepth: depth,
                onGroundFound: { groundFound = true },
                onSessionError: { msg in arError = msg },
                onUnderwaterChange: { isUnder in underwater = isUnder }
            )
            .ignoresSafeArea()

            // Underwater POV overlay — full-screen blue-tinted submerged view
            // with caustics + light shaft + bubbles. Activates when the AR
            // camera drops below the detected waterline.
            UnderwaterPOVOverlay(active: underwater)

            if let arError {
                VStack(spacing: 6) {
                    Text("AR session error").font(.caption.bold())
                    Text(arError).font(.caption).multilineTextAlignment(.center)
                    Text("Check Settings → BAHAR QC → Camera permission.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .padding()
            }

            VStack {
                depthCard
                    .padding(.top, 60)
                gpsBar
                    .padding(.top, 8)
                Spacer()
                if !groundFound {
                    Text("Point camera at the ground to detect floor")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 60)
                }
            }
            .padding(.horizontal)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Text("✕ Exit")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
            }
            .padding()
        }
        .task {
            // Start GPS immediately so the user sees it warming up while the
            // 38 MB flood grid memory-maps in the background.
            location.start()
            await loadFloodData()
        }
        .onChange(of: location.lastLocation) { newValue in
            guard let coord = newValue?.coordinate else { return }
            Task { await refreshDepth(latitude: coord.latitude, longitude: coord.longitude) }
        }
        .onDisappear { location.stop() }
    }

    private var depthCard: some View {
        VStack(spacing: 8) {
            if gauge.category == .none {
                Text(gauge.category.fullName)
                    .font(.caption.bold())
                    .foregroundStyle(badgeColor)
            } else {
                Text(gauge.category.abbreviation)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(badgeColor, in: Capsule())

                Text(gauge.description)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(gauge.category.fullName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var gpsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill")
            Text(gpsText)
                .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    private var gpsText: String {
        if let err = loadError { return err }
        if !floodReady { return "Loading flood data…" }
        switch location.authorizationStatus {
        case .notDetermined: return "Requesting location…"
        case .denied, .restricted: return "Location denied"
        default: break
        }
        guard let loc = location.lastLocation else { return "Waiting for GPS…" }
        return String(format: "%.5f, %.5f  ±%.0fm",
                      loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)
    }

    private var badgeColor: Color {
        switch gauge.category {
        case .none:  return .green
        case .patv:  return .green
        case .nplv:  return .orange
        case .npatv: return .red
        }
    }

    private func loadFloodData() async {
        do {
            try await flood.load()
            floodReady = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshDepth(latitude: Double, longitude: Double) async {
        let d = await flood.depth(latitude: latitude, longitude: longitude) ?? 0
        let g = await flood.gauge(for: d)
        await MainActor.run {
            depth = d
            gauge = g
        }
    }
}
#endif

#Preview {
    LandingView(onStart: {})
}
