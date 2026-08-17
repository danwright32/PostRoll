import Foundation

/// What was running when a bridge call failed, in the words the person uses
/// for it (#626).
///
/// `PythonBridgeError` is thrown from sixteen places across program reads,
/// generation and export, and every sentence it produced began "Generation".
/// That is right for one caller and wrong for the others, and it was wrongest
/// on the screen that says a paid program read did not work: the heading says
/// the program could not be read and the sentence under it named a different
/// stage of the app. Each sentence was defensible where it was written and the
/// contradiction existed only in the reading (L118).
///
/// The subject is supplied by whoever STARTED the work, because that is the
/// only place that knows. `other` is the default rather than a guess: a caller
/// that says nothing gets a vague sentence instead of a confidently wrong one,
/// and a vague sentence is never the wrong claim (L93).
enum PythonBridgeWork: CaseIterable {
    case programRead
    case generation
    case export
    case other

    /// How a failure sentence names it.
    var subject: String {
        switch self {
        case .programRead: return "The program read"
        case .generation:  return "Generation"
        case .export:      return "The export"
        case .other:       return "The run"
        }
    }
}

enum PythonBridgeError: LocalizedError {
    case scriptFailed(exitCode: Int32, stderr: String)
    case outputMissing
    case invalidOutput(String)
    case timedOut(seconds: TimeInterval)
    /// An OCR run that died partway but had already read some of the programme
    /// (#479). Each batch of a large programme is a paid call and is written to
    /// disk as it finishes, so the pages already read survive the stop. Carried
    /// as an error rather than returned as a result on purpose: this is not a
    /// finished read, and half a cast list presented as a complete one is worse
    /// than a failure, because nothing then tells Dan to check the rest.
    case partialOCR(OCRResult, reason: String)
    /// The Python checkout could not be reached, so nothing was launched (#648).
    ///
    /// Thrown BEFORE the subprocess rather than classified from its wreckage.
    /// By the time a run has failed, all that comes back is the shell's own
    /// `cd` line, which reads as a missing file and was reported as one: Dan
    /// was told to check that his photos had not moved. Refusing up front is
    /// what keeps the cause nameable.
    case projectRootUnavailable(AppPaths.ProjectRootProblem)

    /// The safe wording, for the many call sites that reach this through
    /// `localizedDescription` and cannot say what they were doing.
    var errorDescription: String? { message(whileDoing: .other) }

    /// The same failure, named in the language of the work that failed.
    func message(whileDoing work: PythonBridgeWork) -> String {
        switch self {
        case .scriptFailed(_, let stderr):
            return Self.humanise(stderr: stderr, work: work)
        case .outputMissing:
            return "\(work.subject) finished but produced no output. Check that the program PDF has readable text and try again."
        case .invalidOutput(let reason):
            // Every call site writes a reason and this switch used to discard
            // all of them, so "No OCR result. Complete the OCR step first."
            // and "Cover regeneration did not produce a cover path." arrived
            // as the same sentence, and the one naming the step to go back to
            // was the one that never showed up (#365).
            let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let whereToLook = "If it keeps failing, check \(AppPaths.logsDirDisplayPath)."
            guard !detail.isEmpty else {
                return "\(work.subject) produced something PostRoll could not read. Try again. \(whereToLook)"
            }
            return "\(detail)\n\n\(whereToLook)"
        case .timedOut(let seconds):
            return "\(work.subject) was still running after \(Int(seconds / 60)) minutes and was stopped. Check your internet connection and try again."
        // The same sentence whoever the caller is: not being able to find the
        // code folder has nothing to do with which stage asked for it.
        case .projectRootUnavailable(let problem):
            return ProjectRootText.message(problem)
        case .partialOCR(let result, let reason):
            let read = [
                result.performers.isEmpty ? nil : "\(result.performers.count) performer\(result.performers.count == 1 ? "" : "s")",
                result.pieces.isEmpty ? nil : "\(result.pieces.count) piece\(result.pieces.count == 1 ? "" : "s")",
            ].compactMap { $0 }.joined(separator: " and ")
            let found = read.isEmpty ? "some of the programme" : read
            return "Only part of the programme was read before this stopped: "
                + "\(found) came through, and the rest of the pages did not. "
                + "Check the cast list and notes against the printed programme "
                + "before generating, or run the scan again.\n\n\(reason)"
        }
    }

    /// What to tell Dan about a whole run that died.
    ///
    /// What the failure IS comes from `RunFailureKind`, which is the only place
    /// that reads the text. This decides what to say about it, in the language of
    /// a whole run. `GenerationFailureText` says it in the language of one day,
    /// off the same kind, so the two can no longer disagree about what happened
    /// or how long to wait (#401).
    private static func humanise(stderr: String, work: PythonBridgeWork) -> String {
        switch RunFailureKind.of(stderr) {
        case .ffmpegMissing:
            return "Media generation failed: ffmpeg is not installed. Run `brew install ffmpeg` "
                 + "in Terminal, then try again."
        case .audioServiceUnreachable:
            return "Couldn't reach Jamendo for background audio. Check your JAMENDO_CLIENT_ID "
                 + "env var, or upload your own audio file, then try again."
        case .requestTooLarge:
            return "The program photos are too large for the AI service to process in one call. "
                 + "Try uploading fewer pages at a time, or downscale the images "
                 + "(Preview › Tools › Adjust Size), then try again."
        case .rateLimited:
            return waitSentence("The AI service is rate-limiting right now.", .rateLimited)
        case .overloaded:
            return waitSentence("The AI service is overloaded right now.", .overloaded)
        case .authFailed:
            return "\(work.subject) failed: the AI service rejected the API key. Check that "
                 + "ANTHROPIC_API_KEY is set correctly, then try again."
        case .aiServiceError:
            return waitSentence("\(work.subject) failed: the AI service returned an error.",
                                .aiServiceError)
        // Deliberately no wait and no retry: this fails identically every time
        // until the model id is changed, so offering a wait would send Dan round
        // a loop that cannot end (#542).
        case .modelUnavailable(let model):
            let named = model.map { "a model called \($0)" } ?? "a model"
            return "\(work.subject) failed: PostRoll asked the AI service for \(named), which it "
                 + "does not have. This is a PostRoll configuration problem rather than "
                 + "something to retry: the model ids live in postroll/ai/model_ids.py and "
                 + "one of them has been retired."
        // The same sentence the pre-launch refusal gives, so the guard and the
        // classifier cannot disagree about what happened (L144). Re-read here
        // rather than carried on the kind, because by now the folder may have
        // come back, and what it says then is still true: it was not there when
        // this run tried to enter it.
        case .projectRootMissing:
            guard let root = AppPaths.projectRoot else {
                return ProjectRootText.message(.notRecorded)
            }
            return ProjectRootText.message(AppPaths.projectRootProblem(root) ?? .missing(root))
        case .outputUnreadable:
            return "\(work.subject) failed: the output could not be read. This is usually a "
                 + "temporary issue. Try again."
        case .fileMissing:
            return "\(work.subject) failed: a required file was not found. Check that your photos "
                 + "are still in their original locations."
        // The per-day kinds cannot be reached from here, because `of` is called
        // without a day. Named rather than defaulted, so adding a kind is a
        // compile error here instead of silently becoming the fallback.
        case .beforeAfterInputsMissing, .reelPhotosMissing,
             .storyFallbackFailed, .unknown:
            return fallback(stderr: stderr, work: work)
        }
    }

    /// One wait per kind, taken from the kind rather than written per sentence.
    private static func waitSentence(_ cause: String, _ kind: RunFailureKind) -> String {
        guard let wait = kind.waitAdvice else { return "\(cause) Try again." }
        return "\(cause) Wait \(wait) and try again."
    }

    /// The last line of a traceback begins with the name of a type inside the
    /// program: `RuntimeError:`, `ValueError:`, `anthropic.APIError:`. That is
    /// the first thing a photographer is shown at the moment something has
    /// already gone wrong, and there is nothing they can do with it (#626).
    ///
    /// Only the leading class name, and only when something is left after it.
    /// A rule that matches by SHAPE has to be tested against what it must
    /// PRESERVE as well as what it must catch (L104): the description behind
    /// the colon is the only account of what happened, so dropping it would
    /// make the message say less than the raw traceback did.
    private static func withoutExceptionClass(_ line: String) -> String {
        guard let match = line.range(
            of: #"^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception):\s*"#,
            options: .regularExpression) else { return line }
        let rest = String(line[match.upperBound...])
        return rest.isEmpty ? line : rest
    }

    /// The last line of stderr rather than a raw traceback, and never the whole
    /// thing. Nothing is claimed about a failure we did not recognise.
    ///
    /// Closed through `Sentence` (#405). Two things were wrong here, and one of
    /// them fired every time: a truncated preview already ends in an ellipsis, so
    /// appending a stop produced "…." on any stderr line over 120 characters,
    /// which Python tracebacks routinely are. The other is the ordinary case,
    /// where a sentence-shaped message from our own Python already ends in a stop
    /// and a bare exception repr ends in nothing.
    private static func fallback(stderr: String, work: PythonBridgeWork) -> String {
        let trimmed = stderr.split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? stderr
        let named = withoutExceptionClass(trimmed)
        let preview = named.count > 120 ? String(named.prefix(120)) + "…" : named
        return "\(work.subject) failed: \(Sentence.closed(preview)) "
             + "Check \(AppPaths.logsDirDisplayPath) if this persists."
    }
}

/// Helpers for reading the shared rolling `postroll.log`. The log accumulates
/// output from every Python invocation across the app's lifetime (OCR,
/// generation, export, ...); when a subprocess fails with no direct stderr
/// (the common case: its real stderr is redirected straight into the log
/// file rather than the pipe Swift reads), the log is the only place to find
/// out what happened.
///
/// Reading an unscoped tail of that shared file is dangerous: a stray digit
/// sequence in an unrelated, older entry (e.g. a UUID containing "413") can
/// hijack `PythonBridgeError`'s substring-based classification and misreport
/// a completely different failure as something it isn't. `scopedTail` isolates
/// just the lines written for one invocation, identified by a marker unique
/// to that run.
enum PythonBridgeLog {
    /// Returns the log lines from the last occurrence of `marker` to the end
    /// of `logText`. Falls back to a bounded tail (never the whole file) if
    /// the marker isn't present, so a missed marker degrades to "less
    /// context" rather than reintroducing the whole-log conflation bug.
    static func scopedTail(_ logText: String, marker: String, fallbackLineCount: Int = 20) -> String {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.contains(marker) }) else {
            return lines.suffix(fallbackLineCount).joined(separator: "\n")
        }
        return lines[markerIndex...].joined(separator: "\n")
    }

    // MARK: - Per-run isolation (#90)
    //
    // `scopedTail` above narrows a shared file by marker, which is only as good
    // as the marker surviving. It did not: every run began by truncating the
    // shared log with `tail > tmp && mv tmp log`, and the `mv` swaps the inode
    // under any run already appending, so that run's output (marker included)
    // vanishes and `scopedTail` falls back to somebody else's tail.
    //
    // So each run now owns a private stderr file. Nothing another run does can
    // truncate it, and nothing this run reads can belong to another. The shared
    // log stays, for reading history by hand, but is only ever appended to
    // whole and rotated under a lock.

    /// Serialises rotation and folding across concurrent runs.
    private static let logLock = NSLock()

    /// The private stderr file for one invocation.
    static func runLogURL(in directory: URL, marker: String) -> URL {
        directory.appendingPathComponent("run-\(marker).log")
    }

    /// What this run actually wrote, for the error message.
    ///
    /// Its own file first. The shared log is consulted only when that file is
    /// empty, which happens when the shell died before the redirect existed (a
    /// bad interpreter, a missing cwd): degrading to less context beats
    /// degrading to an empty error.
    ///
    /// Which of the two it came from is returned rather than discarded (#650).
    /// The caller has to weigh this against what the launcher shell said, and
    /// the two sources do not deserve equal weight: the run's own file is
    /// certainly this run, while a tail of the shared log may belong to another
    /// one entirely, which is the whole reason per-run files exist (#90).
    static func runOutput(runLog: URL, sharedLog: URL,
                          marker: String) -> ProcessRunner.ProcessOutput {
        if let own = try? String(contentsOf: runLog, encoding: .utf8) {
            let spoken = withoutLauncherLines(own, marker: marker)
            if !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .own(spoken)
            }
        }
        guard let shared = try? String(contentsOf: sharedLog, encoding: .utf8) else { return .none }
        return .sharedTail(scopedTail(shared, marker: marker))
    }

    /// The run log without the lines this app wrote into it itself (#661).
    ///
    /// The launch script opens every run log with a header naming the time, the
    /// marker, the command and, since #661, the commit and BRANCH the checkout
    /// was on. None of that is the process speaking, and `.own` outranks
    /// everything the launcher said, so leaving it in has two consequences:
    /// a run that wrote nothing at all is diagnosed from our own header instead
    /// of from the launcher's message, and a branch named `fix-413-x` reads to
    /// the failure classifier as an HTTP 413 with clean boundaries either side,
    /// which is #650 arriving through a new door.
    ///
    /// Keyed on the marker, which is on every line the launcher writes and on
    /// nothing the process writes: it is generated per run and never given to
    /// Python.
    static func withoutLauncherLines(_ text: String, marker: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(marker) }
            .joined(separator: "\n")
    }

    /// Trim the shared log to its last `keepingLines` lines.
    ///
    /// In Swift under a lock rather than in the launch script, because the
    /// shell version raced every concurrent run.
    static func rotate(_ sharedLog: URL, keepingLines: Int = 500) {
        logLock.lock()
        defer { logLock.unlock() }
        guard let text = try? String(contentsOf: sharedLog, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > keepingLines else { return }
        let kept = lines.suffix(keepingLines).joined(separator: "\n")
        try? kept.write(to: sharedLog, atomically: true, encoding: .utf8)
    }

    /// Append a finished run's output to the shared log and delete its file.
    ///
    /// One locked append of the whole run, so two runs finishing together
    /// interleave as blocks rather than as lines, and neither is lost.
    static func foldIntoShared(runLog: URL, sharedLog: URL) {
        logLock.lock()
        defer { logLock.unlock() }
        defer { try? FileManager.default.removeItem(at: runLog) }

        guard let data = try? Data(contentsOf: runLog), !data.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: sharedLog.path) {
            try? data.write(to: sharedLog)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: sharedLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
