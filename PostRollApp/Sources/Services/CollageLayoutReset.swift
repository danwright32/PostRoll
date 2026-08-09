import Foundation

/// Going back to the automatic collage layout (#161).
///
/// Once a day had a saved cell override, the renderer took that branch and
/// used the stored coordinates forever. Keeping a manual arrangement by
/// default is right, but there was no way back, and after the gallery-mat
/// change any day with an override kept the old edge-to-edge geometry and
/// could not opt in to the new design at all.
enum CollageLayoutReset {

    /// Everything the reset changes, in one value so the view cannot do half
    /// of it. Leaving a cell selected against a layout that no longer exists
    /// points the size slider at a cell index the new plan may not have.
    struct Outcome: Equatable {
        /// Always nil: clearing this is what sends the next render back
        /// through the shape-aware planner.
        var cellOverride: [CollageCell]?
        /// Always nil: the previous selection referred to the old plan.
        var selectedCellIndex: Int?
        /// The stored image was rendered from the override, so it has to be
        /// rebuilt or the screen keeps showing the arrangement just discarded.
        var shouldRegenerate: Bool
    }

    /// Whether to show the control at all.
    ///
    /// Only when there IS an override, so it never offers to undo something
    /// that was never done.
    static func isOffered(cellOverride: [CollageCell]?) -> Bool {
        cellOverride != nil
    }

    static func apply(cellOverride: [CollageCell]?) -> Outcome {
        guard isOffered(cellOverride: cellOverride) else {
            // Nothing to reset: do not trigger a paid or slow rebuild for a
            // press that changes nothing.
            return Outcome(cellOverride: nil, selectedCellIndex: nil,
                           shouldRegenerate: false)
        }
        return Outcome(cellOverride: nil, selectedCellIndex: nil,
                       shouldRegenerate: true)
    }
}
