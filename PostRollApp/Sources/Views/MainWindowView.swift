import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            // The mode toggle is a real sibling stacked above the sidebar content,
            // not a safeAreaInset overlay. As an overlay it competed with the
            // .searchable(.sidebar) field for the top of the column and ended up
            // painted on top of the first event row, leaking its text around the
            // pill. Stacking guarantees the list flows below it and never underlaps.
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $appState.sidebarMode) {
                    Text("Events").tag(SidebarMode.events)
                    Text("Insights").tag(SidebarMode.insights)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.creamDeep)

                Color.creamEdge.frame(height: 0.5)

                Group {
                    if appState.sidebarMode == .events {
                        EventListView()
                    } else {
                        InsightsSidebarView()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 265)
        } detail: {
            if appState.sidebarMode == .events {
                if let id = appState.selectedEventID,
                   let event = appState.events.first(where: { $0.id == id }) {
                    EventDetailView(event: event)
                        .background(Color.cream)
                } else {
                    WelcomeDetailView(
                        hasEvents: !appState.events.isEmpty,
                        onNew: { appState.showingNewEvent = true }
                    )
                }
            } else {
                InsightsDetailView()
            }
        }
        // Solid cream toolbar — no vibrancy, no blending against other windows
        .toolbarBackground(Color.creamDeep, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowConfigurator())
        .sheet(isPresented: $appState.showingNewEvent) {
            NewEventSheet()
                .environment(appState)
        }
        .sheet(isPresented: $appState.showingOutdatedDesigns) {
            OutdatedDesignsSheet()
                .environment(appState)
        }
        .alert(
            "Saved events could not be read",
            isPresented: Binding(
                get: { appState.dataLoadWarning != nil },
                set: { if !$0 { appState.dataLoadWarning = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.dataLoadWarning ?? "")
        }
        // A store that could not be read is a different situation from a store
        // that was read and turned out to be bad: the events are still there,
        // we just cannot see them, and saving is refused. Blocking here keeps
        // the user out of an app that looks empty and quietly discards edits.
        .alert(
            "PostRoll cannot open your events",
            isPresented: Binding(
                get: { appState.storeUnavailable != nil },
                set: { _ in }
            )
        ) {
            Button("Try Again") { appState.loadStore() }
            Button("Quit PostRoll") { NSApplication.shared.terminate(nil) }
        } message: {
            Text(appState.storeUnavailable ?? "")
        }
    }
}

// MARK: - Welcome detail (no event selected)

private struct WelcomeDetailView: View {
    let hasEvents: Bool
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            Text("PostRoll")
                .font(.signPainter(44))
                .foregroundStyle(Color.roseGold.opacity(Opacity.subtle))

            RoseGoldDivider(opacity: Opacity.subtle)
                .frame(width: 80)
                .padding(.vertical, Spacing.xs)

            if hasEvents {
                Text("Select an event from the\nsidebar to continue.")
                    .font(.light(13))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            } else {
                Text("Create an event to begin\nyour weekly posting workflow.")
                    .font(.light(13))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Button("New Event", action: onNew)
                    .buttonStyle(BrandButtonStyle())
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.cream)
    }
}

// MARK: - Window configurator (transparent titlebar, opaque content)

/// Lifetime, audited against #196 (#198): this hands nothing to anything that
/// outlives it. It MUTATES the shared window (appearance, background, minimum
/// size, opening frame) and never undoes that, which is correct rather than an
/// oversight: it is the app's only window, it dies with the app, and every
/// change here is idempotent. The async block captures the view rather than
/// the reverse, so there is nothing to dangle either.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Force light mode globally. NSApplication.shared is safe here (app is
            // running); NSApp would crash if called during App.init() before AppKit
            // sets the global. This covers all panels including DatePicker calendar.
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // creamDeep (not cream) — this is what fills the title-strip area
            // above the toolbar when titlebarAppearsTransparent is true
            window.backgroundColor = NSColor(Color.creamDeep)
            window.isOpaque = true
            window.minSize = NSSize(width: 760, height: 500)

            // NavigationSplitView's sidebar uses NSVisualEffectView with
            // .behindWindow blending, which composites against whatever app
            // is behind PostRoll — making other windows show through the sidebar.
            // Switch every effect view to .withinWindow so blending stays inside
            // the PostRoll window only.
            if let root = window.contentView { Self.fixVibrancy(root) }

            // Ensure the window opens large enough to feel like a real workspace.
            // If macOS restored a small frame (< 1000pt wide), expand to ~80% of screen.
            if let screen = NSScreen.main, window.frame.width < 1000 {
                let visible = screen.visibleFrame
                let w = (visible.width * 0.82).rounded()
                let h = (visible.height * 0.84).rounded()
                let x = (visible.minX + (visible.width - w) / 2).rounded()
                let y = (visible.minY + (visible.height - h) / 2).rounded()
                window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply after SwiftUI rebuilds its view tree (e.g. after state changes)
        if let root = nsView.window?.contentView { Self.fixVibrancy(root) }
    }

    private static func fixVibrancy(_ view: NSView) {
        if let ev = view as? NSVisualEffectView {
            ev.blendingMode = .withinWindow
        }
        for sub in view.subviews { fixVibrancy(sub) }
    }
}

// MARK: - Brand button style

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(configuration.isPressed ? Color.roseDeep : Color.roseGold)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .focusEffectDisabled()
    }
}
