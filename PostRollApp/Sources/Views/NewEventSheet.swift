import SwiftUI

struct NewEventSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// What a `postroll://` link brought, or nil for a new event typed by hand
    /// (#840).
    ///
    /// The form is filled from it and then nothing else happens: the sheet is
    /// the review step, and Create is still what writes. A link that is stale
    /// or wrong is visible here before it becomes an event.
    let prefill: DeepLink.EventDraft?

    @State private var name: String
    @State private var org: String
    @State private var venue: String
    @State private var venueContext: String
    @State private var date: Date
    /// Deliberately NOT prefilled. The link has no shoot type to give: Downbeat
    /// knows the genre, which is a different axis, and nothing over there
    /// answers whether this is a performance, a photo call or a rehearsal. So
    /// the picker goes on doing the job it already does.
    @State private var shootType = ShootType.fullShow

    init(prefill: DeepLink.EventDraft? = nil) {
        self.prefill = prefill
        _name = State(initialValue: prefill?.name ?? "")
        _org = State(initialValue: prefill?.org ?? "")
        _venue = State(initialValue: prefill?.venue ?? "")
        _venueContext = State(initialValue: prefill?.venueContext ?? "")
        _date = State(initialValue: prefill?.date ?? Date())
    }

    /// Why this cannot be created yet, from the same predicate that disables the
    /// button, so a greyed control can never sit beside nothing (#402).
    private var refusal: String? {
        NewEventValidation.refusal(name: name)
    }

    private var isValid: Bool { refusal == nil }

    var body: some View {
        NavigationStack {
            ZStack {
                PaintedSurfaces.page.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {

                        // Sheet title
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New Event")
                                .font(.signPainter(32))
                                .foregroundStyle(PaintedSurfaces.bodyText)
                            RoseGoldDivider()
                        }
                        .padding(.top, Spacing.lg)

                        // Event details
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            BrandSectionLabel("Event Details")
                            BrandTextField("Event name", text: $name)
                            // Named as optional in the field itself rather
                            // than in a hint beside it, so the one place Dan
                            // looks while filling the form is the place that
                            // says so (#689).
                            BrandTextField("Organization (optional)", text: $org)
                            BrandTextField("Venue (optional)", text: $venue)
                            BrandTextField("Specific hall/room (optional, for blog context)", text: $venueContext)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Date")
                                    .font(.light(11))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                DatePicker("", selection: $date, displayedComponents: .date)
                                    .labelsHidden()
                                    .tint(PaintedSurfaces.iconAccent)
                            }
                        }

                        // Shoot type
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            BrandSectionLabel("Shoot Type")
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(ShootType.allCases, id: \.self) { type in
                                    ShootTypeOption(
                                        type: type,
                                        isSelected: shootType == type,
                                        onSelect: { shootType = type }
                                    )
                                }
                            }
                        }

                        // Actions
                        VStack(alignment: .trailing, spacing: Spacing.sm) {
                            if let refusal {
                                RefusalNote(message: refusal)
                            }
                            HStack {
                                Button("Cancel") { dismiss() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                Spacer()
                                Button("Create Event") { createEvent() }
                                    .buttonStyle(BrandButtonStyle())
                                    // Return commits this only when Dan opened
                                    // the sheet himself (#844).
                                    //
                                    // A link raises it and brings PostRoll to
                                    // the front at a moment he did not choose,
                                    // which on a cold launch is seconds after
                                    // he clicked and moved on to something
                                    // else. As the default action, Create then
                                    // sits under whatever he types next, and
                                    // what it commits is an event whose whole
                                    // point is that it was reviewed first.
                                    //
                                    // Measured: an event reached the real store
                                    // from a link with nobody deliberately
                                    // pressing anything, and a hands off probe
                                    // ruled out the code committing on its own.
                                    .keyboardShortcut(prefill == nil ? .defaultAction : nil)
                                    .disabled(!isValid)
                                    .opacity(isValid ? 1 : 0.4)
                            }
                        }
                        .padding(.bottom, Spacing.xl)
                    }
                    .padding(.horizontal, Spacing.xl)
                }
            }
            .frame(width: 440)
            .navigationBarBackButtonHidden()
        }
    }

    private func createEvent() {
        // Built through the one place that builds one, rather than here, since
        // #840 gave the form a second filler: the folding rule (#688) and the
        // booking id would otherwise have two spellings.
        //
        // The booking id comes from the link and from nowhere else, so an event
        // typed by hand carries none and a second click on a link matches only
        // the event that link made.
        let event = NewEventForm.event(
            name: name,
            org: org,
            venue: venue,
            venueContext: venueContext,
            date: date,
            shootType: shootType,
            bookingID: prefill?.bookingID
        )
        appState.addEvent(event)
        dismiss()
    }
}

// MARK: - Shared sub-components

struct BrandSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(PaintedSurfaces.secondaryText)
    }
}

struct BrandTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .font(.system(size: 13))
            .foregroundStyle(PaintedSurfaces.bodyText)
            .focusEffectDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(PaintedSurfaces.deepPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(
                                focused ? Color.roseGold : Color.creamEdge,
                                lineWidth: focused ? 1.5 : 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct ShootTypeOption: View {
    let type: ShootType
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? PaintedSurfaces.accentBorder : PaintedSurfaces.edgeRule, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(PaintedSurfaces.iconAccent)
                            .frame(width: 10, height: 10)
                    }
                }
                Image(systemName: type.systemImage)
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? PaintedSurfaces.iconAccent : PaintedSurfaces.secondaryText)
                Text(type.rawValue)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? PaintedSurfaces.bodyText : PaintedSurfaces.secondaryText)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}
