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

    /// Links that arrived from an OmniFocus task note (#840). Read here rather
    /// than handled where they land, because on a cold launch the URL is
    /// delivered before this view exists.
    private var deepLinks = DeepLinkInbox.shared

    /// Whether a banner this app sends could reach anybody at all (#894).
    private var notifications = NotificationService.shared

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
            .navigationSplitViewColumnWidth(min: WindowFit.sidebarFloor, ideal: 265)
        } detail: {
            if appState.sidebarMode == .events {
                if let id = appState.selectedEventID,
                   let event = appState.events.first(where: { $0.id == id }) {
                    EventDetailView(event: event)
                        .background(PaintedSurfaces.page)
                } else {
                    WelcomeDetailView(
                        hasEvents: !appState.events.isEmpty,
                        onNew: { appState.presentNewEvent() }
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
        // A strip of their own below everything else, rather than an inset over
        // it (#695). The inset did not reach into the detail column's scroll
        // view, so the last 60pt of every scrolling screen sat underneath the
        // banner with no scroll travel left to bring it out, and on a stage
        // screen the last item is the stage's primary action.
        .bottomBanners {
            // Two conditions that both persist, stacked rather than competing
            // for one slot: a failing save and a checkout that is not on a clean
            // main can be true at the same time, and whichever lost would be
            // invisible while still true.
            if appState.checkoutNotice != nil || appState.saveFailure != nil
                || appState.deepLinkNotice != nil || appState.answeringCopyNotice != nil {
                VStack(spacing: Spacing.sm) {
                    // Which copy of PostRoll answered the link (#840). Above
                    // the rest of the stack because it changes what every other
                    // sentence here is ABOUT: a Debug build has its own events
                    // store, so an event created in it is simply not in the app
                    // Dan normally opens.
                    if let copy = appState.answeringCopyNotice {
                        BrandBanner(
                            icon: "exclamationmark.triangle.fill",
                            message: copy,
                            style: .warning,
                            actions: [BrandBannerAction(label: "Dismiss") {
                                appState.dismissAnsweringCopyNotice()
                            }])
                    }
                    // A click that opened no sheet (#840): either the link had
                    // already made its event, or it could not be read. Both
                    // have to be said. The first changes nothing visible when
                    // that event was already on screen, and the second is
                    // otherwise a link that silently did nothing.
                    //
                    // Dismissable, because unlike the two below it neither
                    // condition persists: it is about one click, and once it
                    // has been read there is nothing left to be true.
                    if let notice = appState.deepLinkNotice {
                        BrandBanner(
                            icon: notice.kind == .refused
                                ? "exclamationmark.triangle.fill" : "link",
                            message: notice.message,
                            style: notice.kind == .refused ? .error : .info,
                            actions: [BrandBannerAction(label: "Dismiss") {
                                appState.dismissDeepLinkNotice()
                            }])
                    }
                    if let notice = appState.checkoutNotice {
                        // Dismissable, unlike the one below it (#696). The
                        // state this was shown for is remembered, so waving it
                        // away is not undone by the next reading of the folder,
                        // and a branch switch or a new edit brings it back
                        // because that is a different thing to say.
                        BrandBanner(icon: CheckoutNotice.icon,
                                    message: notice,
                                    style: .warning,
                                    actions: [BrandBannerAction(
                                        label: CheckoutNotice.dismissLabel) {
                                            appState.dismissCheckoutNotice()
                                        }])
                    }
                    // Nothing this app announces can arrive (#894). Not
                    // dismissable, and above the save failure rather than below
                    // it, because unlike the two notices above it this one is
                    // about a condition that persists for the whole session and
                    // silences every OTHER thing the app would have said.
                    //
                    // The whole point of the notifications is the case where
                    // the window is closed, so this is the one sentence that
                    // has to be read while it is open.
                    if let complaint = NotificationNotice.message(
                        permission: notifications.permission,
                        hasAsked: notifications.hasAsked) {
                        BrandBanner(icon: "bell.slash.fill",
                                    message: complaint,
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
        // Both orders a cold launch can happen in (#840). `onAppear` catches
        // the link that was already waiting when this view was built, which is
        // the case a change-watcher alone cannot see because the change
        // happened first; `onChange` catches the click that comes in while the
        // window is already open, which `onAppear` alone cannot see because it
        // fires once.
        .onAppear { appState.handleWaitingDeepLinks(deepLinks) }
        .onChange(of: deepLinks.pending) { appState.handleWaitingDeepLinks(deepLinks) }
        // ONE sheet modifier for the whole window (#846).
        //
        // This was three, each bound to its own flag, and SwiftUI presents at
        // most one sheet per view: when two were asked for at once, one of them
        // silently did nothing and nothing said which. That was survivable
        // while all three were things Dan opened himself, because he could only
        // ask for one at a time. #840 ended it, by letting a `postroll://` link
        // raise the New Event form at any moment, including while the build
        // behind warning is up.
        //
        // Which one wins is now decided in `ModalQueue` and testable without a
        // window, rather than being whichever modifier SwiftUI happened to
        // honour. Nothing is dropped: the rest wait and come back.
        //
        // Dismissing goes through the state rather than clearing a value here,
        // because the build behind verdict is taken again every time the code
        // folder is read (#675): a sheet that only cleared itself would be put
        // straight back by the next reading and would reappear on every
        // activation, which is how a warning becomes something to click away on
        // reflex (L36).
        //
        // The dismissal names the sheet it is about (#855). SwiftUI reports a
        // dismissal AFTER the button that caused it has already run, and a
        // button whose action raises or withdraws something has by then put a
        // different sheet on screen. See `ModalQueue.dismissPresented`.
        .sheet(item: Binding(
            get: { appState.presentedSheet },
            set: { [showing = appState.presentedSheet?.kind] item in
                guard item == nil, let showing else { return }
                appState.dismissPresentedSheet(showing)
            }
        )) { sheet in
            switch sheet {
            case .newEvent:
                NewEventSheet(prefill: appState.newEventPrefill)
                    .environment(appState)
            case .outdatedDesigns:
                OutdatedDesignsSheet()
                    .environment(appState)
            case .buildBehind(let behind):
                BuildBehindSheet(behind: behind)
                    .environment(appState)
                    // The three managers that own background work. The sheet
                    // asks them whether anything is mid flight before it lets an
                    // update start, because installing quits the app (#686).
                    .environment(generationManager)
                    .environment(ocrManager)
                    .environment(exportManager)
            }
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
                // Whether the code folder is reachable, asked again rather than
                // answered once at launch (#856). It was set on the way in and
                // cleared nowhere, so a checkout put back while PostRoll sat
                // there left the warning standing for the rest of the session,
                // which is the case the notice exists for: the folder moves
                // precisely while the app is open, because that is when a
                // session moves it in the terminal.
                //
                // Cheap, unlike the reading below it: `LaunchProjectCheck` is
                // pure and looks at the filesystem, where that one runs git
                // three times, which is why only this half is taken inline.
                appState.applyProjectRoot(LaunchProjectCheck.outcome())
                Task { await refreshCheckoutNotice() }
            }
        // ONE alert modifier for the whole window, for the same reason there is
        // one sheet modifier above (#846).
        //
        // This was three, and two of the three are raised by launch checks that
        // both run on every launch: the code folder is read on this view's first
        // task, and the store is read as the state is built. Which alert is
        // shown when both want the screen is now decided in `ModalQueue`, where
        // it can be read and tested, rather than being whichever `.alert`
        // modifier SwiftUI happened to honour.
        //
        // The refusal to open the store is blocking, so it takes the screen and
        // cannot be dismissed. That was true before, as a binding whose setter
        // ignored its input; it is now a property of the alert itself, so it
        // holds wherever the alert is raised from.
        //
        // `presenting:` carries WHICH alert into the builders, and that is not
        // decoration (#855). The sheet above is keyed on identity, because
        // `.sheet(item:)` takes a value and `WindowSheet.id` differs per case,
        // so replacing one sheet with another tells SwiftUI the content changed.
        // `.alert(_:isPresented:)` takes only a Bool and carries no identity at
        // all, so when the refusal to open the events displaces the code folder
        // warning, which is the case the queue exists for and which happens at
        // launch, `isPresented` never leaves true and nothing says the content
        // changed. The previous alert's buttons can then sit under the new
        // one's title, which is worse than either condition alone because each
        // half of the screen reads as correct.
        .alert(
            appState.presentedAlert.map(WindowAlertText.title) ?? "",
            isPresented: Binding(
                get: { appState.presentedAlert != nil },
                set: { [showing = appState.presentedAlert?.kind] isShowing in
                    guard !isShowing, let showing else { return }
                    appState.dismissPresentedAlert(showing)
                }
            ),
            presenting: appState.presentedAlert
        ) { alert in
            switch alert {
            case .projectRoot:
                // Dismissible: everything that is not generation still works, so
                // trapping Dan behind it would take away more than the fault
                // does (#652).
                Button("OK", role: .cancel) {}
            case .dataLoad:
                // The way back, on the screen that reports the loss (#441). Five
                // verified-good generations sat beside the bad file with nothing
                // in the app able to offer them, and Dan does not use the
                // terminal, so the only restore path was one he could not take.
                if appState.restorableBackup != nil {
                    Button(StoreRestoreText.restoreLabel) { appState.restoreLatestBackup() }
                }
                Button("OK", role: .cancel) {}
            case .storeUnavailable:
                // A store that could not be read is a different situation from a
                // store that was read and turned out to be bad: the events are
                // still there, we just cannot see them, and saving is refused.
                // Neither button dismisses; one fixes it and one leaves.
                Button("Try Again") { appState.loadStore() }
                Button("Quit PostRoll") { NSApplication.shared.terminate(nil) }
            }
        } message: { alert in
            Text(WindowAlertText.message(alert))
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
        // One resolution of the checkout, applied through the same call the
        // activation above uses, so the launch answer and every refreshed one
        // cannot become two paths that disagree about what is on screen (L16).
        let outcome = LaunchProjectCheck.outcome()
        appState.applyProjectRoot(outcome)
        let repo: URL
        switch outcome {
        case .unreachable:
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
///
/// One thing here DOES outlive a single call, and it is held rather than
/// registered and forgotten: the window fit watch (#690) observes the window on
/// the default notification centre, which holds its observers unowned and
/// outlives whatever registered with them (L86). It lives on the coordinator,
/// so it is created once and released with this view rather than accumulating
/// one more observer every time SwiftUI rebuilds.
private struct WindowConfigurator: NSViewRepresentable {

    @MainActor
    final class Coordinator {
        /// Held, not registered and forgotten.
        ///
        /// Nothing tears it down, and that is the decision rather than the
        /// omission: this is the app's only window and it dies with the app, so
        /// there is no moment where the watch should stop. It is deliberately
        /// NOT stopped in `deinit` either, because a deinit is nonisolated and
        /// can run on any thread, and asserting an isolation that does not hold
        /// is a crash at teardown in exchange for cleanup nobody needs. The
        /// observers hold the window weakly, so the worst case if this object
        /// ever does go away first is a handful of blocks that do nothing.
        var watch: WindowFitWatch?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Force light mode globally. NSApplication.shared is safe here (app is
            // running); NSApp would crash if called during App.init() before AppKit
            // sets the global. This covers all panels including DatePicker calendar.
            NSApplication.shared.appearance = PaintedSurfaces.pinnedAppearance
            window.appearance = PaintedSurfaces.pinnedAppearance
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // creamDeep (not cream) — this is what fills the title-strip area
            // above the toolbar when titlebarAppearsTransparent is true
            window.backgroundColor = NSColor(Color.creamDeep)
            window.isOpaque = true
            // One spelling of the floor, shared with the guard that puts it
            // back. Two copies could disagree, and the one that lost would be
            // this one, silently (#690).
            window.minSize = WindowFit.floor

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

            // Last, so it judges the frame this method leaves behind rather
            // than the one it started with (#690).
            //
            // Both halves, and both are needed: a window restored from a
            // previous session already outside the usable area is pulled back
            // in here, so a broken window heals on open instead of reopening
            // broken, and the watch keeps it inside on every later resize,
            // move and screen change. A check that runs only at window
            // creation is exactly what was already here and it could not help,
            // because the layout pass that breaks it comes later.
            if let visible = WindowFit.visibleFrame(for: window) {
                WindowFit.fit(window, into: visible,
                              isFullScreen: window.styleMask.contains(.fullScreen))
            }
            if context.coordinator.watch == nil {
                context.coordinator.watch = WindowFit.watch(window)
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


