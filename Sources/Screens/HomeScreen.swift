import SwiftUI

struct HomeScreen: View {
    @Binding var cityHallInput: CityHallInput?

    var body: some View {
        TabView {
            NavigationStack { KycScreen() }
                .tabItem { Label("tab_kyc", systemImage: "person.text.rectangle") }

            NavigationStack { SigningScreen() }
                .tabItem { Label("tab_signing", systemImage: "signature") }

            NavigationStack { AuthScreen() }
                .tabItem { Label("tab_auth", systemImage: "shield.lefthalf.filled") }
        }
        .tint(Color.electricBlue)
        .fullScreenCover(item: $cityHallInput) { input in
            CityHallAuthScreen(input: input, onDismiss: { cityHallInput = nil })
        }
    }
}
