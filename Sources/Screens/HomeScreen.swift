import SwiftUI

struct HomeScreen: View {
    
    var body: some View {
        TabView {
            NavigationStack { KycScreen().safeAreaInset(edge: .top, spacing: 0) { DemoModeBanner() } }
                .tabItem { Label("tab_kyc", systemImage: "person.text.rectangle") }

            NavigationStack { SigningScreen().safeAreaInset(edge: .top, spacing: 0) { DemoModeBanner() } }
                .tabItem { Label("tab_signing", systemImage: "signature") }

            NavigationStack { AuthScreen().safeAreaInset(edge: .top, spacing: 0) { DemoModeBanner() } }
                .tabItem { Label("tab_auth", systemImage: "shield.lefthalf.filled") }
        }
        .tint(Color.electricBlue)
    }
}
