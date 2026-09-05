import SwiftUI
import AppKit

/// A handle shown as a link to its Instagram profile, or as plain text when
/// there is nothing worth opening (#973).
///
/// The collaborator panel listed each candidate as plain text, so filling in
/// the numbers behind "Add numbers" meant reading the handle off the screen,
/// switching to a browser and typing it in by hand, once per account. The sheet
/// itself says "Open their profile and read these off a few recent posts", so
/// opening the profile is the expected next step.
///
/// `ProfileLink` decides both the address and whether there is one, so this
/// draws the two states and nothing more.
struct ProfileHandleText: View {
    let handle: String
    /// A profile URL the research step stored and checked, where one exists.
    /// Preferred over the constructed address by `ProfileLink`.
    ///
    /// No default (#987, L168). A checked address is what separates a
    /// confirmed account from a convention, and a screen that silently
    /// inherited "there is none" would go on opening the constructed address
    /// while every call site read as correct. Passing nil is fine, and says
    /// out loud that this surface has nothing checked to offer.
    let storedProfileURL: String?
    var font: Font = .system(size: 12, weight: .medium)

    var body: some View {
        if let url = ProfileLink.url(handle: handle, storedProfileURL: storedProfileURL) {
            Button { NSWorkspace.shared.open(url) } label: {
                Text(handle)
                    .font(font)
                    // Underlined and in the accent, so it reads as a control
                    // standing still rather than only under a pointer: a
                    // control that looks like a label until you hover is one
                    // nobody finds (L49). `pageAccentText` is the accent at the
                    // level TEXT needs, not the one an icon or a rule needs
                    // (L149).
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .underline()
            }
            .buttonStyle(.plain)
            .help(ProfileLink.accessibilityLabel(handle: handle))
            .accessibilityLabel(ProfileLink.accessibilityLabel(handle: handle))
        } else {
            // Exactly as it was before: a value that is not an account has
            // nowhere to go, and a dead link that looks live is worse than no
            // link, because pressing it is the only way to find out.
            Text(handle)
                .font(font)
                .foregroundStyle(PaintedSurfaces.bodyText)
                .textSelection(.enabled)
        }
    }
}
