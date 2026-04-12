import SwiftUI

struct EventListView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingDeleteID: Event.ID?
    @State private var recentlyDeleted: Event?
    @State private var showUndoBanner = false
    @State private var undoDismissWork: DispatchWorkItem?

    var body: some View {
        @Bindable var appState = appState

        // Manual selection — avoids the system blue highlight.
        // Tap gesture sets selectedEventID; custom listRowBackground shows rose-gold tint.
        List {
            ForEach(appState.events) { event in
                let isSelected = appState.selectedEventID == event.id
                EventRow(event: event)
                    .tag(event.id)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(isSelected ? Color.roseGold.opacity(0.12) : Color.clear)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { appState.selectedEventID = event.id }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            pendingDeleteID = event.id
                        }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamDeep)
        .navigationTitle("")
        .alert("Delete Event?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID,
                   let event = appState.events.first(where: { $0.id == id }) {
                    recentlyDeleted = event
                    appState.deleteEvent(id: id)
                    undoDismissWork?.cancel()
                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = true }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                        recentlyDeleted = nil
                    }
                    undoDismissWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            if let id = pendingDeleteID,
               let event = appState.events.first(where: { $0.id == id }) {
                Text("\"\(event.name)\" will be permanently removed.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showingNewEvent = true
                } label: {
                    Label("New Event", systemImage: "plus")
                        .foregroundStyle(Color.roseGold)
                }
                .buttonStyle(.plain)
                .help("New Event (⌘N)")
            }
        }
        .overlay {
            if appState.events.isEmpty {
                EmptySidebarView()
            }
        }
        .overlay(alignment: .bottom) {
            if showUndoBanner {
                UndoBanner {
                    undoDismissWork?.cancel()
                    if let event = recentlyDeleted { appState.addEvent(event) }
                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                    recentlyDeleted = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Event name in SignPainter — the visual thread to the generated assets
            Text(event.name)
                .font(.signPainter(16))
                .foregroundStyle(Color.warmDark)
                .lineLimit(1)

            HStack(spacing: 3) {
                Text(event.org)
                Text("·")
                Text(event.displayDate)
            }
            .font(.light(11))
            .foregroundStyle(Color.warmMid)
            .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: event.shootType.systemImage)
                    .imageScale(.small)
                Text(event.shootType.rawValue)
                Spacer()
                StagePill(stage: event.stage)
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.warmMid)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Stage Pill

struct StagePill: View {
    let stage: EventStage

    private var pillColor: Color {
        switch stage {
        case .created:          return Color.warmMid
        case .programUploaded:  return Color(red: 175/255, green: 130/255, blue: 120/255)
        case .ocrDone:          return Color.roseGold
        case .photosAssigned:   return Color(red: 165/255, green: 120/255, blue:  85/255)
        case .assetsGenerated:  return Color(red: 150/255, green: 125/255, blue:  70/255)
        case .captionsReviewed: return Color(red: 110/255, green: 140/255, blue: 110/255)
        case .exported:         return Color(red:  80/255, green: 130/255, blue:  90/255)
        }
    }

    var body: some View {
        Text(stage.rawValue)
            .font(.system(size: 9, weight: .medium))
            .tracking(0.3)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pillColor.opacity(0.14))
            .foregroundStyle(pillColor)
            .clipShape(Capsule())
    }
}

// MARK: - Undo Banner

private struct UndoBanner: View {
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text("Event deleted.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.roseGold)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.creamDeep)
        .overlay(Rectangle().fill(Color.creamEdge).frame(height: 0.5), alignment: .top)
    }
}

// MARK: - Empty Sidebar

private struct EmptySidebarView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No events")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)
            Text("Click + or press ⌘N to start.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.creamDeep)
    }
}
