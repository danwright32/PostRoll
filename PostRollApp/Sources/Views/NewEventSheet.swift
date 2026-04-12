import SwiftUI

struct NewEventSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var org = ""
    @State private var venue = ""
    @State private var date = Date()
    @State private var shootType = ShootType.fullShow

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !org.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cream.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {

                        // Sheet title
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New Event")
                                .font(.signPainter(32))
                                .foregroundStyle(Color.warmDark)
                            RoseGoldDivider()
                        }
                        .padding(.top, Spacing.lg)

                        // Event details
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            BrandSectionLabel("Event Details")
                            BrandTextField("Event name", text: $name)
                            BrandTextField("Organization", text: $org)
                            BrandTextField("Venue (optional)", text: $venue)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Date")
                                    .font(.light(11))
                                    .foregroundStyle(Color.warmMid)
                                DatePicker("", selection: $date, displayedComponents: .date)
                                    .labelsHidden()
                                    .tint(Color.roseGold)
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
                        HStack {
                            Button("Cancel") { dismiss() }
                                .buttonStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.warmMid)
                            Spacer()
                            Button("Create Event") { createEvent() }
                                .buttonStyle(BrandButtonStyle())
                                .disabled(!isValid)
                                .opacity(isValid ? 1 : 0.4)
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
        let event = Event(
            name: name.trimmingCharacters(in: .whitespaces),
            org: org.trimmingCharacters(in: .whitespaces),
            venue: venue.trimmingCharacters(in: .whitespaces),
            date: date,
            shootType: shootType
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
            .foregroundStyle(Color.warmMid)
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
            .foregroundStyle(Color.warmDark)
            .focusEffectDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.creamDeep)
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
                        .strokeBorder(isSelected ? Color.roseGold : Color.creamEdge, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(Color.roseGold)
                            .frame(width: 10, height: 10)
                    }
                }
                Image(systemName: type.systemImage)
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Color.roseGold : Color.warmMid)
                Text(type.rawValue)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.warmDark : Color.warmMid)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}
