import SwiftUI
import EidKit
import OpenTelemetryApi

@main
struct EidKitApp: App 
{
    private let isDemoMode: Bool

    init() {
        var demoMode = true
        do {
            OpenTelemetry.registerTracerProvider(tracerProvider: TelemetrySetup.provider)
            try EidKitSdk.configure(EidKitConfig(licenseToken: "eidkit-demo-app", onSpan: TelemetrySetup.adapter.onSpan))
            demoMode = false
            TelemetrySetup.emitProbeSpan()
        } catch {
            print("EidKit configuration failed: \(error)")
        }
        isDemoMode = demoMode

        let surfaceDark = UIColor(red: 0.059, green: 0.090, blue: 0.165, alpha: 1)

        // Navigation bar — solid dark background, white title text
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = surfaceDark
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().tintColor = UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1)

        // Tab bar — dark background, blue selected, dim unselected
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = surfaceDark
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
        UITabBar.appearance().unselectedItemTintColor = UIColor.white.withAlphaComponent(0.45)
    }

    var body: some Scene {
        WindowGroup {
            HomeScreen(isDemoMode: isDemoMode)
                .environment(\.locale, appLocale)
                .preferredColorScheme(.dark)
                .onAppear {
                    // UIWindow.appearance() is ignored by SwiftUI — set it directly after creation
                    UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .forEach { $0.backgroundColor = UIColor(red: 0.059, green: 0.090, blue: 0.165, alpha: 1) }
                }
        }
    }
}
