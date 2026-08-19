import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    // Handed on to the out of date sheet, which asks all three whether work is
    // mid flight before it lets PostRoll update itself (#686). Reading the
    // managers themselves registers no dependency on what is inside them, so
    // this costs the window nothing per tick.
    @Environment(GenerationManager.self) private var generationManager
    @Environment(OCRManager.self) private var ocrManager
    @Environment(ExportManager.self) private var exportManager

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

                PaintedSurfaces.edgeRule.frame(height: 0.5)

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
            // Two conditions that both persist, stacked rather than competing
            // for one slot: a failing save and a checkout that is not on a clean
            // main can be true at the same time, and whichever lost would be
            // invisible while still true.
            if appState.checkoutNotice != nil || appState.saveFailure != nil {
                VStack(spacing: Spacing.sm) {
                    if let notice = appState.checkoutNotice {
                        BrandBanner(icon: CheckoutNotice.icon,
                                    message: notice,
                                    style: .warning)
                    }
                    if let failure = appState.saveFailure {
                        BrandBanner(
                            icon: "exclamationmark.triangle.fill",
                            message: failure,
                            style: .error,
                            actions: [BrandBannerAction(label: SaveFailureNotice.retryLabel) {
                                appState.retrySave()
                            }]
                        )
                    }
                }
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
        // the middle of the window rather than left to be noticed.
        //
        // Dismissing goes through the state rather than clearing the value here,
        // because the verdict is taken again every time the code folder is read
        // (#675): a sheet that only cleared itself would be put straight back by
        // the next reading and would reappear on every activation, which is how a
        // warning becomes something to click away on reflex (L36).
        .sheet(item: Binding(
            get: { appState.buildBehind },
            set: { if $0 == nil { appState.dismissBuildBehind() } }
        )) { behind in
            BuildBehindSheet(behind: behind)
                .environment(appState)
                // The three managers that own background work. The sheet asks
                // them whether anything is mid flight before it lets an update
                // start, because installing quits the app (#686).
                .environment(generationManager)
                .environment(ocrManager)
                .environment(exportManager)
        }
        .task { await checkTheCodeFolder() }
        // A checkout moves while the app is open, which is the case the notice
        // exists for and the one a launch-time read cannot see (#668). Coming
        // back from the terminal that moved it is the whole scenario, and it
        // produces exactly this notification.
        //
        // The app coming forward rather than each window becoming key: the
        // reading runs git three times, and every window shuffle inside the app
        // would pay for it while answering the same thing.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshCheckoutNotice() }
            }
        // Said at launch rather than left for the first generation to discover,
        // because an app that cannot generate anything otherwise looks entirely
        // normal until Dan has picked a day and pressed a button (#652).
        //
        // Dismissible: everything that is not generation still works, so
        // trapping him behind it would take away more than the fault does.
        .alert(
            LaunchProjectCheck.title,
            isPresented: Binding(
                get: { appState.projectRootProblem != nil },
                set: { if !$0 { appState.projectRootProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.projectRootProblem.map(LaunchProjectCheck.message) ?? "")
        }
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

    /// Read the checkout again, because it may have moved (#668).
    ///
    /// Only the checkout, not the build freshness beside it: that answer cannot
    /// change while the app is open, and this one changes precisely then.
    ///
    /// Nothing is assigned here. The read announces itself and the subscription
    /// made at launch applies it, so there is one path from a reading to the
    /// sentence on the window rather than one per caller (L16).
    ///
    /// An unreachable checkout is left to the launch check that already reports
    /// it: raising the same alert every time the app is brought forward would
    /// make the app unusable while the folder is missing.
    ///
    /// Through the read that can skip itself (#676). This runs on every
    /// activation, and a reading runs git three times, one of them a status over
    /// the whole working tree, so clicking in and out of the app was paying for
    /// the same answer again. It also covers the activation that lands seconds
    /// after a generation has just read the same folder for its own log.
    private func refreshCheckoutNotice() async {
        guard case .ready(let repo) = LaunchProjectCheck.outcome() else { return }
        _ = await Task.detached { CheckoutRevision.readIfStale(inRepo: repo) }.value
    }

    /// Ask at launch what the code folder is and whether this build predates it.
    ///
    /// Only a `behind` verdict is put in front of Dan; not being able to tell is
    /// written to the log, because a popup with nothing actionable in it is one
    /// that gets dismissed on reflex, and the real warning would go with it.
    ///
    /// Neither answer stops here. Both are refreshed on every later reading of
    /// the same folder (#668, #675), which is what makes them true of the folder
    /// as it is rather than as it was when the app opened.
    private func checkTheCodeFolder() async {
        // First, and deliberately before the checkout is resolved: an update
        // that got as far as installing QUIT the app that started it, so this
        // launch is usually the first chance to say why it did not work, and a
        // checkout that has become unreachable must not take that reason with
        // it (#686, L164).
        appState.checkUpdateOutcome()
        // Subscribed before anything is read, so the reading taken below and
        // every one a generation takes afterwards land the same way (#668).
        appState.watchCheckoutReadings()
        // One resolution of the checkout for both checks, so they cannot end up
        // disagreeing about whether there is one.
        //
        // An unreachable checkout is reported and nothing else is attempted:
        // build freshness runs git inside that folder, so with no folder there
        // is no verdict to reach, and the answer Dan needs is the one already
        // in hand (#652).
        let repo: URL
        switch LaunchProjectCheck.outcome() {
        case .unreachable(let problem):
            appState.projectRootProblem = problem
            return
        case .ready(let root):
            repo = root
        }
        // Which code a generation would run, from the same folder and the same
        // detached task (#664). Off the main actor for the same reason as the
        // check below it: it runs git, three times, and the thread drawing the
        // window is not where that belongs.
        let revision = await Task.detached { CheckoutRevision.read(inRepo: repo) }.value
        // Applied here as well as through the subscription above, so the notice
        // at launch does not depend on the subscription having been made. The
        // same reading applied twice is the same sentence.
        appState.apply(revision)
        if case .unknown(let reason) = revision {
            // To the log rather than to the window, the same way an unreadable
            // build freshness verdict goes: there is nothing here Dan can act
            // on, and a notice he cannot act on is one he learns to ignore.
            NSLog("[PostRoll] checkout revision unknown: \(reason)")
        }

        // Asked here as well as through the subscription above, for the same
        // reason the reading is applied twice: the answer at launch must not
        // depend on the subscription having been made. The same verdict reached
        // twice is the same sheet, and the second one is refused by the
        // dismissal check if Dan has already waved it away.
        await appState.refreshBuildFreshness(inRepo: repo)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            } else {
                Text("Create an event to begin\nyour weekly posting workflow.")
                    .font(.light(13))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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


