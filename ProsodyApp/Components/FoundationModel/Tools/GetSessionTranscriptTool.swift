import Foundation
import FoundationModels

/// Returns the full verbatim transcript of the practice session.
/// The Acoustic Mirror preserves all learner errors — no autocorrection.
struct GetSessionTranscriptTool: Tool {
    let name = "getSessionTranscript"
    let description = "Returns the full verbatim transcript of everything the learner said during the session. This is the raw Acoustic Mirror output — it preserves grammatical errors and pronunciation-driven misspellings exactly as transcribed, without autocorrection."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let transcript = record.fullTranscript
        if transcript.isEmpty { return "No transcript available." }
        return transcript
    }
}
