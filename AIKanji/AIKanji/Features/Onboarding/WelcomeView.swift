import SwiftUI

struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("AI 幹事")
                    .font(.largeTitle.bold())
                Text("Find a restaurant everyone can agree on.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                NavigationLink("Create Event") { CreateEventView() }
                    .buttonStyle(.borderedProminent)
                NavigationLink("Join Event") { JoinEventView() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

#Preview {
    WelcomeView()
}
