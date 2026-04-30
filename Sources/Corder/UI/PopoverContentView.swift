import SwiftUI

struct PopoverContentView: View {
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Corder").font(.headline)
            Button("Start Recording") { /* Plan 2 */ }
                .disabled(true)
                .help("Recording arrives in Plan 2")
            Button("Open Library", action: onOpenLibrary)
            Text("Plan 1 — skeleton only")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 240)
    }
}
