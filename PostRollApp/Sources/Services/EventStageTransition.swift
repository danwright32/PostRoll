import Foundation

/// Moves an event to a new stage without discarding anything written since the
/// screen was opened (#103).
///
/// The bug this exists to prevent: a screen holds `event` as a captured prop,
/// which is a snapshot from the moment it was built. Both the Back button and
/// the Advance button on the photo assignment screen did
/// `var ev = event; ev.stage = ...; appState.updateEvent(ev)`, so pressing
/// either wrote that snapshot back over the live record. On Advance this ran
/// immediately after `save()` had just persisted every photo assignment,
/// tag, note and crop offset, and undid all of it.
///
/// A stage change must therefore only ever be applied to the LIVE record.
enum EventStageTransition {

    /// The live event with `stage` applied, or nil if it is no longer there.
    ///
    /// Takes the whole array rather than one event so the caller cannot supply
    /// its stale copy by accident: the live record is looked up here.
    static func applying(_ stage: EventStage,
                         toEventWithID id: Event.ID,
                         in events: [Event]) -> Event? {
        guard var live = events.first(where: { $0.id == id }) else { return nil }
        live.stage = stage
        return live
    }
}
