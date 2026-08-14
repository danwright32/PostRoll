import SwiftUI
import Observation

/// Which event row the pointer is over (#457).
///
/// Its own object so that writing it does not invalidate whatever else is on
/// the view that owns it. `EventListView`'s body derives `filteredEvents`, a
/// filter plus a search plus a sort over every Event, and an Event is a large
/// value carrying its days, its photo paths and the whole week's generated
/// result. While the hover lived on that view, every enter and leave paid the
/// whole derivation again, once per row the mouse crossed (L59).
@MainActor
@Observable
final class EventListHover {
    var eventID: Event.ID?
}

/// The background behind one row of the event list.
///
/// Its own view because it is the ONLY thing that reads the hover. A view that
/// reads an observable property is the view that re-renders when it changes, so
/// keeping the read down here is what confines a hover to the two rows whose
/// backgrounds actually changed.
struct EventRowBackground: View {

    let eventID: Event.ID
    let isSelected: Bool
    let hover: EventListHover
    let selectionNamespace: Namespace.ID

    /// Selection wins: a selected row is already the strongest thing on the
    /// list, and warming it further on hover would say the click had not
    /// landed yet.
    private var isHovered: Bool { hover.eventID == eventID && !isSelected }

    #if POSTROLL_TESTS
    /// The same answer, reachable from a test. Behind the test-only flag so the
    /// shipping app cannot start reading the hover from somewhere new, which is
    /// the thing #457 is about.
    var isHoveredForTesting: Bool { isHovered }
    #endif

    var body: some View {
        Group {
            if isSelected {
                // Glider + bookmark strip slide together as one unit
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(Color.roseGold.opacity(0.12))
                    // Bookmark strip: a slim rose-gold spine at the leading edge
                    Capsule()
                        .fill(Color.roseGold)
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                }
                .matchedGeometryEffect(id: "selectionBG", in: selectionNamespace)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            } else if isHovered {
                // Pre-selection warmth: the row glows before the click lands
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Color.roseGold.opacity(0.05))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                // Opaque background prevents the system accent-color
                // selection highlight from bleeding through.
                Color.creamDeep
            }
        }
    }
}
