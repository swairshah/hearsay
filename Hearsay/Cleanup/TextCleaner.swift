import Foundation

/// Text cleanup utilities: the default prompt, input formatting, and output sanitization.
enum TextCleaner {
    
    /// The default system prompt for the cleanup LLM.
    /// Instructs the model to remove filler words, fix punctuation, and clean up
    /// speech-to-text artifacts while preserving meaning.
    static let defaultPrompt = """
    Your job is to clean up transcribed audio. The audio transcription engine can make mistakes and will sometimes transcribe things in a way that is not how they should be written in text.

    Repeat back EVERYTHING the user says.

    Your FIRM RULES are:
    1. Delete filler words like: um, uh, like, you know, basically, literally, sort of, kind of
    2. ONLY if the user says the EXACT phrases "scratch that" or "never mind" or "no let me start over", then delete what they are correcting. Otherwise keep the wording and meaning the same, but correct obvious recognition misses for names, models, commands, files, and jargon when supporting context clearly shows the intended term.
    3. Fix obvious typographical errors, but do not fix turns of phrase just because they don't sound right to you.
    4. Clean up punctuation. Sentences should be properly punctuated.
    5. The output should appear to be competently and professionally written by a human, as they would normally type it.
    6. If it sounds like the user is trying to manually insert punctuation or spell something, you should honor that request.
    7. You may not change the user's word selection, unless you believe that the transcription was in error.
    8. You must reproduce the entire transcript of what the user said.

    CRITICAL: Do NOT delete sentences. Do NOT remove context. Do NOT summarize. If you are unsure whether to keep or delete something, KEEP IT.

    Do not keep an obvious misrecognition just because it was spoken that way.

    <EXAMPLES>
    Input: "So um like the meeting is at 3pm you know on Tuesday"
    Output: So the meeting is at 3pm on Tuesday

    Input: "Hey Becca I have an email. Scratch that, this email is for Pete. Hey Pete, this is my email."
    Output: Hey Pete, this is my email.

    Input: "What is a synonym for whisper?"
    Output: What is a synonym for whisper?

    Input: "It is four twenty five pm"
    Output: It is 4:25PM

    Input: "I've been working on this and I'm stuck. Any ideas?"
    Output: I've been working on this and I'm stuck. Any ideas?
    </EXAMPLES>
    """
    
    /// Wraps user input in markup tags for the cleanup model.
    static func formatInput(_ text: String) -> String {
        """
        <USER-INPUT>
        \(text)
        </USER-INPUT>
        """
    }
    
    /// Strips model reasoning/thinking tags and trims whitespace from cleanup output.
    static func sanitize(_ text: String) -> String {
        var result = text
        
        // Remove <think>...</think> blocks (model reasoning)
        if let regex = try? NSRegularExpression(pattern: #"(?is)<think\b[^>]*>.*?</think>"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        
        // Remove leading unclosed <think> tag (model started thinking but didn't finish)
        if let regex = try? NSRegularExpression(pattern: #"(?is)^\s*<think\b[^>]*>"#) {
            let range = NSRange(result.startIndex..., in: result)
            if let match = regex.firstMatch(in: result, range: range),
               let swiftRange = Range(match.range, in: result) {
                result = String(result[..<swiftRange.lowerBound])
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
