import SwiftUI
import EidKit
import OpenTelemetryApi

class AppDelegate: NSObject, UIApplicationDelegate {
    var pendingURL: URL? = nil

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            pendingURL = url
        }
        return true
    }
}

@main
struct EidKitApp: App
{
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        do {
            OpenTelemetry.registerTracerProvider(tracerProvider: TelemetrySetup.provider)
            try EidKitSdk.configure(EidKitConfig(licenseToken: "eidkit-demo-app", onSpan: TelemetrySetup.adapter.onSpan))
            TelemetrySetup.emitProbeSpan()
        } catch {
            print("EidKit configuration failed: \(error)")
        }

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

    @State private var cityHallInput: CityHallInput? = nil

    private func handleURL(_ url: URL) {
        let isCustomScheme = url.scheme == "eidkit" && url.host == "auth"
        let isUniversalLink = url.scheme == "https" && url.host == "idp.eidkit.ro" && url.path.hasPrefix("/auth")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard (isCustomScheme || isUniversalLink),
              let session = components?.queryItems?.first(where: { $0.name == "session" })?.value,
              let callback = components?.queryItems?.first(where: { $0.name == "callback" })?.value
        else { return }
        let service = components?.queryItems?.first(where: { $0.name == "service" })?.value ?? ""
        let nonce   = components?.queryItems?.first(where: { $0.name == "nonce" })?.value ?? ""
        cityHallInput = CityHallInput(
            sessionToken: session,
            callbackUrl: callback,
            serviceName: service,
            nonce: nonce
        )
    }

    var body: some Scene {
        WindowGroup {
            HomeScreen(cityHallInput: $cityHallInput)
                .environment(\.locale, appLocale)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .forEach { $0.backgroundColor = UIColor(red: 0.059, green: 0.090, blue: 0.165, alpha: 1) }
                    if let url = appDelegate.pendingURL {
                        appDelegate.pendingURL = nil
                        handleURL(url)
                    }
                }
                .onOpenURL { url in handleURL(url) }
        }
    }
}
