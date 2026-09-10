import SwiftUI
import ClaudeTopKit

// Phase 3. A MenuBarExtra over ClaudeTopKit, packaged as a DMG by Scripts/make-app.sh.
// Do not start this until phase 1 tests pass and the CLI is in daily use: this target
// cannot be verified by an agent, only by a person looking at the menu bar.
@main
struct ClaudeTopApp: App {
    var body: some Scene {
        MenuBarExtra("claude-top", systemImage: "gauge.with.dots.needle.67percent") {
            Text("Not implemented yet")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
