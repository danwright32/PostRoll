import Foundation

/// The window's own source, for the guards that must prove something is drawn
/// there rather than merely described somewhere.
///
/// One reader, not one per guard. `SaveFailureBannerTests` and
/// `CheckoutBannerTests` both need MainWindowView with its comments stripped,
/// and two copies of that would be free to disagree about what stripping means.
///
/// Comments are stripped because prose explaining a banner must not be able to
/// satisfy a check for the banner (L103): an assertion is otherwise green on a
/// comment saying the thing was removed.
enum MainWindowSource {

    /// Every line of MainWindowView, trimmed, with whole-line comments dropped.
    static func stripped() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/MainWindowView.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The braced block the first line containing `needle` opens, that line
    /// included, or nil when nothing in `code` contains it.
    ///
    /// A whole-file search is answered by any occurrence anywhere in the file,
    /// which in a window this size is a near certainty (L135): the checkout
    /// notice is WRITTEN in `checkBuildFreshness` two hundred lines below the
    /// banner, so a guard asking whether MainWindowView mentions it passes with
    /// the entire banner deleted. Scoping to the block is what makes the
    /// assertion about the drawing.
    ///
    /// Nil rather than an empty string, because a search that matched nothing
    /// and a block that holds nothing are different answers and only one of
    /// them means the guard has been left with nothing to check (L100).
    static func block(openedBy needle: String, in code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(needle) }) else {
            return nil
        }

        var depth = 0
        var opened = false
        var body: [String] = []
        for line in lines[start...] {
            for character in line {
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            body.append(line)
            if opened && depth <= 0 { break }
        }
        return opened ? body.joined(separator: "\n") : nil
    }

    /// One line of whitespace-collapsed text, so an assertion can require two
    /// things of ONE match instead of two matches that may sit anywhere (L172).
    static func flattened(_ block: String) -> String {
        block.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }
}
