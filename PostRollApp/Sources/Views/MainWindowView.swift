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
                .background(PaintedSurfaces.deepPage)

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
                        .background(PaintedSurfaces.page)
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
        // A save that has started failing (#446). Deliberately a banner pinned to
        // the bottom of the window rather than an alert: a failing disk fails
        // every debounced keystroke, and a modal per keystroke is unusable. It
        // stays until a save succeeds, because the condition does.
        //
        // At the bottom rather than in the toolbar because a toolbar can condense
        // and hide what it holds (L79), and this is the message that says the
        // work on screen exists nowhere else.
        .safeAreaInset(edge: .bottom) {
            if let failure = appState.saveFailure {
                BrandBanner(
                    icon: "exclamationmark.triangle.fill",
                    message: failure,
                    style: .error,
                    actions: [BrandBannerAction(label: SaveFailureNotice.retryLabel) {
                        appState.retrySave()
                    }]
                )
                .padding(Spacing.md)
                .background(PaintedSurfaces.page)
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
        // The app being older than the code it was built from is the one thing
        // that makes a shipped fix look like it never worked, so it is said in
        // the middle of the window at launch rather than left to be noticed.
        .sheet(item: $appState.buildBehind) { behind in
            BuildBehindSheet(builtAt: behind.builtAt,
                             latestCommit: behind.latestCommit,
                             remedy: behind.remedy,
                             repo: AppPaths.projectRoot)
        }
        .task { await checkBuildFreshness() }
        .alert(
            "Saved events could not be read",
            isPresented: Binding(
                get: { appState.dataLoadWarning != nil },
                set: { if !$0 { appState.dataLoadWarning = nil } }
            )
        ) {
            // The way back, on the screen that reports the loss (#441). Five
            // verified-good generations sat beside the bad file with nothing in
            // the app able to offer them, and Dan does not use the terminal, so
            // the only restore path was one he could not take.
            if appState.restorableBackup != nil {
                Button(StoreRestoreText.restoreLabel) { appState.restoreLatestBackup() }
            }
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

    /// Ask once, at launch, whether this build predates the code.
    ///
    /// Off the main actor: it stats a file and runs git, and neither belongs on
    /// the thread drawing the window. Only a `behind` verdict is put in front of
    /// Dan; not being able to tell is written to the log, because a popup with
    /// nothing actionable in it is one that gets dismissed on reflex, and the
    /// real warning would go with it.
    private func checkBuildFreshness() async {
        let repo = AppPaths.projectRoot
        let verdict = await Task.detached { BuildFreshness.check(repo: repo) }.value
        switch verdict {
        case let .behind(builtAt, latestCommit, remedy):
            appState.buildBehind = BuildBehind(builtAt: builtAt,
                                               latestCommit: latestCommit,
                                               remedy: remedy)
        case .current:
            break
        case let .cannotTell(reason):
            NSLog("[PostRoll] build freshness unknown: \(reason)")
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
                .foregroundStyle(PaintedSurfaces.mastheadWordmark.opacity(Opacity.subtle))

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
        .background(PaintedSurfaces.page)
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


