import Foundation

/// What a failed run or a failed day IS, decided once (#401).
///
/// Two places used to decide this independently: `PythonBridgeError.humanise`
/// for a whole run that died, and `GenerationFailureText` for one day that did.
/// They matched the same needles and gave Dan different answers, because the
/// wording and the matching were tangled together in each of them:
///
///   * `429` was "wait a minute" on one path and "wait about 30 seconds" on the
///     other.
///   * `overloaded` was rate limiting on one path and its own thing on the other.
///   * `401` was named as a bad API key on one path and reported as a generic
///     connection problem on the other, because only one of them looked for it.
///
/// So the matching lives here and nothing else does. The two message producers
/// switch on the kind and keep their own wording, because a sentence about a
/// whole run and a sentence about Thursday are genuinely different sentences.
enum RunFailureKind: Equatable {

    // Local tooling. Nothing Dan changes in the app will fix these.
    case ffmpegMissing
    case audioServiceUnreachable

    // The AI service. Separate cases rather than one, because the right thing to
    // do about each of them differs and the two old copies disagreed about it.
    case requestTooLarge
    case rateLimited
    case overloaded
    case authFailed
    case aiServiceError

    // The run produced something unusable.
    case outputUnreadable

    // Inputs. `fileMissing` is a file that moved; the rest are a step not done.
    case fileMissing
    case beforeAfterInputsMissing(day: String)
    case reelPhotosMissing
    case storyFallbackFailed

    /// Nothing recognised. Deliberately its own case rather than a default that
    /// borrows a neighbour's meaning: a caller that cannot tell "we know what
    /// this is" from "we do not" will eventually claim the wrong one.
    case unknown

    // MARK: - The one classifier

    /// Reads a failure's text and says what it is.
    ///
    /// `day` is the day key when the text came from one day's failure, and nil
    /// when it came from a whole run. Some kinds only exist per day (Tuesday's
    /// before/after inputs), so without it those cases cannot be reached and the
    /// text falls through to something more general, which is correct.
    ///
    /// ## The text must be scoped to one run
    ///
    /// Some needles below are HTTP status codes, which are three digits and
    /// therefore appear inside unrelated identifiers. `PythonBridgeLog` documents
    /// what that cost: an older entry in the shared log containing a UUID with
    /// `413` in it could hijack the classification and misreport a completely
    /// different failure. The digit matches here require a non-alphanumeric
    /// boundary on both sides, which stops the common form of that, but a
    /// caller still has to pass text from ONE run rather than a tail of a shared
    /// log (#90).
    static func of(_ text: String, day: String? = nil) -> RunFailureKind {
        let s = text.lowercased()

        // Order matters and is stated here rather than rediscovered per caller.
        //
        // Local tooling first: an ffmpeg failure often carries a stack trace that
        // mentions the AI client library, and reading it as a service problem
        // sends Dan to check his API key over a missing brew package.
        //
        // ABSENT, not merely mentioned. Every ffmpeg wrapper in postroll/media
        // prefixes its message with the word, so the word says nothing about
        // whether the binary is installed. Measuring real output showed a missing
        // photo arriving as "ffmpeg failed: ... No such file or directory", which
        // was read as a missing package: Dan was told to install something he
        // already had, and the route back to re-assign the photo was withheld
        // because a missing package is not fixable from the app (#403).
        if isAbsentBinary("ffmpeg", in: s) { return .ffmpegMissing }
        if s.contains("jamendo") { return .audioServiceUnreachable }

        // Then the specific service failures, before the generic one. A payload
        // that is too large is also "an anthropic api error", and the generic
        // reading of it tells Dan to retry something that will fail identically.
        if s.contains("request_too_large") || s.contains("request exceeds the maximum")
            || hasCode("413", in: s)
            // A prompt past the context window arrives as an ordinary 400, so
            // without this it read as a generic service error and Dan was told to
            // wait and retry something that fails identically every time. The only
            // thing that fixes it is sending less (#403).
            || s.contains("prompt is too long") {
            return .requestTooLarge
        }
        if s.contains("rate_limit") || s.contains("rate limit") || hasCode("429", in: s) {
            return .rateLimited
        }
        if s.contains("overloaded") || hasCode("529", in: s) { return .overloaded }
        // Also where 403 lands, on the words "API key": the key is real and the
        // account is not allowed to use what was asked for, and both are fixed
        // by looking at the key rather than by waiting.
        if s.contains("api key") || s.contains("authentication")
            || hasCode("401", in: s) || hasCode("403", in: s) {
            return .authFailed
        }
        // The service's own error markers, not a bare mention of its name.
        //
        // This is where the two old copies disagreed and one of them was simply
        // right. `GenerationFailureText` required "anthropic api error" and said
        // why in a comment; `PythonBridgeError` matched bare "anthropic", which
        // any traceback through the client library satisfies, so a ValueError in
        // Dan's own code was reported as a connection problem and told him to
        // check his API key. The strict rule wins, and a stack trace that merely
        // passes through the library now falls to the honest fallback (#401).
        // "anthropic api" rather than "anthropic api error": the client also
        // raises its own failures about the service, such as a reply that came
        // back carrying no text block at all, and those used to fall through to
        // the unrecognised fallback (#403). Still narrow enough that a traceback
        // through the library, "/x/anthropic/client.py", does not match.
        //
        // Three needles were removed from this branch in #522: "openai api",
        // which names a service the app has never called, and "apistatuserror"
        // and "apiconnectionerror", which expected the SDK exception's CLASS
        // name to appear in the text. It cannot. claude_client raises
        // `Anthropic API error: {e}`, and str() of an SDK exception is its
        // message, never its type, so those two could not have matched anything
        // the app is able to produce. What they were reaching for, a transport
        // failure that carries no HTTP status at all, is caught by the words in
        // front of it and is measured in the fixture as its own case.
        if s.contains("anthropic api") {
            return .aiServiceError
        }

        // Then the per-day input shortfalls, which need to know which day.
        if let day {
            if (day == "tuesday" || day == "friday")
                && (s.contains("raw") || s.contains("edited")) {
                return .beforeAfterInputsMissing(day: day)
            }
            if day == "thursday" && s.contains("photo") && s.contains("empty") {
                return .reelPhotosMissing
            }
        }

        if s.contains("no such file") || s.contains("filenotfounderror") { return .fileMissing }
        if s.contains("story fallback failed") { return .storyFallbackFailed }

        // Last, because these words appear inside other failures' stack traces.
        if s.contains("json") || s.contains("decode") || s.contains("parse") {
            return .outputUnreadable
        }

        return .unknown
    }

    /// Whether Dan can resolve this himself by changing what he gave the app.
    ///
    /// Decided on the kind rather than at each call site, because it controls
    /// whether the route back to the photo screen is offered and two answers to
    /// that question would send him to change inputs that were never the problem.
    ///
    /// `unknown` counts as fixable: the raw error is always shown beside it, and
    /// offering an extra route hides nothing. What it must not do is claim to know
    /// what went wrong, which is why it is not folded into a neighbour.
    var isFixableFromTheApp: Bool {
        switch self {
        case .ffmpegMissing, .audioServiceUnreachable, .rateLimited, .overloaded,
             .authFailed, .aiServiceError:
            return false
        case .requestTooLarge, .outputUnreadable, .fileMissing, .beforeAfterInputsMissing,
             .reelPhotosMissing, .storyFallbackFailed, .unknown:
            return true
        }
    }

    /// How long to wait before retrying, when waiting is the answer.
    ///
    /// One value per kind, used by every message, because the two old copies
    /// printed different waits for the same failure.
    var waitAdvice: String? {
        switch self {
        case .rateLimited: return "about 30 seconds"
        case .overloaded, .aiServiceError: return "a minute"
        default: return nil
        }
    }

    /// A three digit status code, bounded so it is not read out of the middle of
    /// an identifier. `a413b` and `1413` are not a 413.
    private static func hasCode(_ code: String, in text: String) -> Bool {
        text.range(of: "(?<![0-9a-z])\(code)(?![0-9a-z])",
                   options: [.regularExpression]) != nil
    }

    /// Whether a command line tool is MISSING, as opposed to named in a message.
    ///
    /// The distinction the measured output forced (#403). Python reports an absent
    /// binary as a `FileNotFoundError` naming the binary itself, and a shell
    /// reports it as not found; a tool that ran and failed says neither, and its
    /// real cause is further down its own stderr.
    private static func isAbsentBinary(_ name: String, in text: String) -> Bool {
        text.contains("no such file or directory: '\(name)'")
            || text.contains("no such file or directory: \"\(name)\"")
            || text.contains("\(name): command not found")
            || text.contains("\(name): not found")
            || text.contains("\(name) is not installed")
            || text.contains("\(name) not found on path")
    }
}
