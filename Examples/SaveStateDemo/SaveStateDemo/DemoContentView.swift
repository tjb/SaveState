import SaveState
import SwiftUI

struct DemoContentView: View {
    let state: DemoState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The trial reads time through SaveStateClock rather than
                    // Date(), so the clock control can move it. The clock isn't
                    // observable, so this redraws on a timer.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        access(at: SaveStateClock.now)
                    }
                }
                Section("State") {
                    LabeledContent("Greeting", value: state.greeting)
                    LabeledContent("Environment", value: state.environment.rawValue)
                    LabeledContent("Project limit", value: "\(state.projectLimit)")
                    LabeledContent("Discount", value: state.discount.formatted(.percent))
                    LabeledContent("Seeded projects", value: "\(state.seededProjects)")
                }
                if state.showsTips {
                    Section {
                        Label("Tap the ladybug to open the debug panel.", systemImage: "lightbulb")
                    }
                }
            }
            .navigationTitle("SaveState Demo")
        }
    }

    @ViewBuilder
    private func access(at now: Date) -> some View {
        if state.isPremium {
            Label("Premium", systemImage: "crown.fill")
                .accessibilityIdentifier("demo.premium")
        } else if state.trialEnd > now {
            Label(
                "Trial ends \(RelativeDateTimeFormatter().localizedString(for: state.trialEnd, relativeTo: now))",
                systemImage: "hourglass"
            )
            .accessibilityIdentifier("demo.trial")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Your trial has ended", systemImage: "lock.fill")
                    .font(.headline)
                Text("Subscribe to keep your projects.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("demo.paywall")
        }
    }
}
