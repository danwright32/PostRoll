import Foundation

/// Which of an event's screens can be reached directly, and why not when they
/// cannot (#183).
///
/// `EventDetailView` routes purely on `event.stage`, so exactly one screen is
/// reachable at any moment and moving between them meant walking the back
/// button one screen at a time, each click writing a new stage as a side
/// effect. Getting from Export back to the Thursday reel was two clicks and two
/// stage writes, with no indication of where you were in the sequence. Editing
/// an asset after reaching export is an ordinary thing to want, and it read as
/// being trapped. #182 is what that looks like when it goes wrong: one missing
/// back button made an event completely unreachable.
///
/// Pure and separate from the view so the rules can be tested without a window.
enum StageNavigation {

    /// The stages the bar offers, in order.
    ///
    /// `.programUploaded` is deliberately absent. It is not a place, it is the
    /// OCR run in progress, and its screen STARTS that run: putting it on a bar
    /// would offer a button that silently spends money re-reading a program
    /// that has already been read.
    static let steps: [EventStage] = [
        .created, .ocrDone, .photosAssigned, .assetsGenerated, .exported,
    ]

    /// Short label for the bar. Not `displayLabel`, which describes a milestone
    /// reached ("Assets Generated"); these name the screen you are going to.
    static func title(_ stage: EventStage) -> String {
        switch stage {
        case .created, .programUploaded: return "Program"
        case .ocrDone:                   return "Review"
        case .photosAssigned:            return "Photos"
        case .assetsGenerated:           return "Generate"
        case .captionsReviewed:          return "Captions"
        case .exported:                  return "Export"
        }
    }

    /// Which bar step is highlighted for a given stage.
    ///
    /// `.captionsReviewed` is the caption review screen, which is reached from
    /// Generate and shares its step; `.programUploaded` is the OCR run, which
    /// belongs to Program. Without this the bar would show nothing highlighted
    /// on two of the seven stages, which reads as being nowhere.
    static func step(containing stage: EventStage) -> EventStage {
        switch stage {
        case .programUploaded:  return .created
        case .captionsReviewed: return .assetsGenerated
        default:                return stage
        }
    }

    /// Why `stage` cannot be opened yet, or nil when it can.
    ///
    /// A reason rather than a bool, because a control that greys out with no
    /// explanation reads as broken, and the reason is the actionable part: it
    /// says which piece of work is missing.
    static func blockedReason(for stage: EventStage, in event: Event) -> String? {
        switch stage {
        case .created, .programUploaded:
            return nil

        case .ocrDone, .photosAssigned:
            // Both screens read the program: one reviews it, the other assigns
            // photos against its performers and pieces.
            return event.ocrResult == nil
                ? "Read the program first, so there is something to review."
                : nil

        case .assetsGenerated:
            guard event.ocrResult != nil else {
                return "Read the program first, so there is something to review."
            }
            let hasPhotos = event.days.values.contains {
                !$0.photoPaths.isEmpty || $0.rawPhotoPath != nil
                    || $0.editedPhotoPath != nil || !$0.clipPaths.isEmpty
            }
            return hasPhotos ? nil : "Assign photos to at least one day first."

        case .captionsReviewed, .exported:
            // The export screen copies what a generation run produced. Opening
            // it with nothing generated would offer to export an empty folder.
            return event.weekResult == nil
                ? "Generate the week's captions and graphics first."
                : nil
        }
    }

    static func canOpen(_ stage: EventStage, in event: Event) -> Bool {
        blockedReason(for: stage, in: event) == nil
    }

    /// Whether this step is behind where the event has got to, so the bar can
    /// show progress as well as offer navigation.
    static func isBehind(_ stage: EventStage, current: EventStage) -> Bool {
        guard let a = EventStage.allCases.firstIndex(of: stage),
              let b = EventStage.allCases.firstIndex(of: step(containing: current))
        else { return false }
        return a < b
    }
}
