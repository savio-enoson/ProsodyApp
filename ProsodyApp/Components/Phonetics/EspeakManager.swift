//
//  EspeakManager.swift
//  C7-Pronunciation
//
//  Created by Savio Enoson on 13/11/25.
//

import Foundation
import libespeak_ng

// MARK: - Phoneme Data Structures

/// Represents a phoneme with its position in the original text
private nonisolated struct PhonemeWithPosition {
    let phoneme: String
    let textPosition: Int
    let isPrimaryStressed: Bool
}

/// Represents phonemes for a single word
nonisolated public struct WordPhonemes {
    public let word: String
    public let phonemes: [String]
    public let startPosition: Int
    public let endPosition: Int
    public var primaryStressIndex: Int? = nil
}

// MARK: - Global Callback

// Global C-function callback required by eSpeak
// It forwards events to our Swift Singleton
private nonisolated func phonemeCallback(samples: UnsafeMutablePointer<Int16>?, num_samples: Int32, events: UnsafeMutablePointer<espeak_EVENT>?) -> Int32 {
    var evt = events
    while let e = evt?.pointee, e.type != espeakEVENT_LIST_TERMINATED {
        if e.type == espeakEVENT_PHONEME {
            let phoneme = withUnsafeBytes(of: e.id.string) { rawPtr in
                String(cString: rawPtr.bindMemory(to: CChar.self).baseAddress!)
            }
            // Accumulate the phoneme character with its text position
            EspeakManager.shared.accumulate(phoneme: phoneme, textPosition: Int(e.text_position))
        } else if e.type == espeakEVENT_WORD {
            // Track word boundaries
            EspeakManager.shared.markWordBoundary(textPosition: Int(e.text_position), length: Int(e.length))
        }
        
        evt = evt?.advanced(by: 1)
    }
    return 0
}

// MARK: - Main Manager Class

nonisolated public final class EspeakManager: @unchecked Sendable {
    // Singleton Access
    public static let shared = EspeakManager()
    private let synthesisLock = NSLock()
    
    // Internal storage for the current synthesis session
    private var currentPhonemes: [PhonemeWithPosition] = []
    private var wordBoundaries: [(position: Int, length: Int)] = []
    private var isNextPrimaryStressed: Bool = false
    
    /// Loaded vocabulary for filtering phonemes.
    private var validPhonemes: Set<String> = []
    
    /// Track the currently active dialect to avoid redundant switches
    private var currentDialect: Dialect? = nil
    
    /// Available dialect voices (simplified to 2)
    public enum Dialect: String, CaseIterable {
        case us = "en-us"
        case generic = "en"
        
        var voiceName: String {
            return self.rawValue
        }
        
        /// Display name for UI/logging
        var displayName: String {
            switch self {
            case .us: return "American English"
            case .generic: return "Generic English"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Initializes the eSpeak-NG engine.
    /// This constructor is private to enforce the singleton pattern.
    private init() {
        // 1. Find the 'espeak-ng-data' directory in our App's bundle
        guard let bundlePath = Bundle.main.resourcePath else {
            fatalError("EspeakManager: Failed to find app bundle path.")
        }
        
        let fileManager = FileManager.default
        let dataDir = (bundlePath as NSString).appendingPathComponent("espeak-ng-data.bundle")
        
        if !fileManager.fileExists(atPath: dataDir) {
            fatalError("EspeakManager: 'espeak-ng-data.bundle' not found.")
        }
        
        // 4. Initialize Library
        // espeak_ng_InitializePath takes the path containing espeak-ng-data.
        // But our folder is named espeak-ng-data.bundle.
        // We can create a symlink or pass the parent directory if we rename the folder inside the bundle.
        // Actually, espeak_ng_InitializePath expects a directory containing a folder named "espeak-ng-data".
        // Let's create a temporary directory, symlink our bundle as "espeak-ng-data", and pass the temp dir.
        let tempDir = NSTemporaryDirectory()
        let symlinkPath = (tempDir as NSString).appendingPathComponent("espeak-ng-data")
        try? fileManager.removeItem(atPath: symlinkPath)
        try! fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: dataDir)
        
        tempDir.withCString { cStr in
            espeak_ng_InitializePath(cStr)
            let status = espeak_ng_Initialize(nil)
            if status != ENS_OK {
                fatalError("EspeakManager: Failed to initialize eSpeak-NG. Status: \(status)")
            }
        }
        
        // 5. Set Synchronous Mode (Retrieval Mode)
        espeak_ng_InitializeOutput(ENOUTPUT_MODE_SYNCHRONOUS, 0, nil)
        
        // 6. Configuration - start with generic English
        let voiceResult = espeak_ng_SetVoiceByName("en")
        if voiceResult == ENS_OK {
            currentDialect = .generic
        } else {
            print("EspeakManager: WARNING - Failed to set initial voice 'en'")
        }
        
        // Set pitch range to 0 to get a more monotonic (robotic) voice
        espeak_ng_SetParameter(espeakRANGE, 0, 0)
        
        // Enable Phoneme Events with IPA output
        // 1 = Enable Events
        // 2 = espeakPHONEMES_IPA (Output IPA Unicode chars)
        espeak_ng_SetPhonemeEvents(1, 2)
        
        // Set punctuation handling
        espeak_ng_SetParameter(espeakPUNCTUATION, Int32(espeakPUNCT_NONE.rawValue), 0)
        
        // Register our global C function as the callback
        espeak_SetSynthCallback(phonemeCallback)
        
        // Load vocabulary for filtering (optional)
        loadVocabulary()
        
        // Print available voices for debugging
        printAvailableVoices()
        
        print("EspeakManager: Initialized successfully with IPA output and dual-dialect support.")
    }
    
    /// Debug helper to print available voices
    private func printAvailableVoices() {
        print("EspeakManager: Checking available English voices...")
        
        // Test each dialect
        for dialect in Dialect.allCases {
            let result = espeak_ng_SetVoiceByName(dialect.voiceName)
            let status = result == ENS_OK ? "✓ Available" : "✗ NOT Available"
            print("   [\(dialect.rawValue)]: \(status)")
        }
        
        // Reset to generic
        espeak_ng_SetVoiceByName("en")
        currentDialect = .generic
    }
    
    // MARK: - Backward Compatible API (OLD SIGNATURE)
    
    /// **BACKWARD COMPATIBLE** - Original method signature that returns [[String]]
    /// This maintains compatibility with existing code that expects the old return type.
    /// Always returns generic English phonemes for consistency with old behavior.
    ///
    /// - Parameter text: The text to convert to phonemes
    /// - Returns: Array of phoneme arrays, one per word (e.g., [["h", "ə"], ["l", "oʊ"]])
    public func getPhonemes(for text: String) -> [[String]] {
        let wordPhonemes = getPhonemesDetailed(for: text, dialect: .generic)
        return wordPhonemes.map { $0.phonemes }
    }
    
    // MARK: - New Enhanced API
    
    /// Returns a single string of phonemes separated by spaces (e.g. "h ə l oʊ w ɜː l d")
    public func getPhonemesAsString(for text: String, dialect: Dialect = .generic) -> String {
        let phonemesByWord = getPhonemesDetailed(for: text, dialect: dialect)
        return phonemesByWord.map { $0.phonemes.joined() }.joined(separator: " ")
    }
    
    /// Generates phonemes for all supported dialects and returns a dictionary
    /// **Used internally by PronunciationScorer for multi-dialect support**
    internal func getPhonemesForAllDialects(for text: String) -> [Dialect: [[String]]] {
        var result: [Dialect: [[String]]] = [:]
        
        for dialect in Dialect.allCases {
            let wordPhonemes = getPhonemesDetailed(for: text, dialect: dialect)
            result[dialect] = wordPhonemes.map { $0.phonemes }
            
            // Debug: print what we got for each dialect
            let flatPhonemes = wordPhonemes.flatMap { $0.phonemes }
            print("EspeakManager: [\(dialect.rawValue)] synthesized: \(flatPhonemes.joined(separator: " "))")
        }
        
        return result
    }
    
    /// Generates context-aware phonemes for a given line of text with detailed word information.
    /// Synthesizes the full phrase to let eSpeak disambiguate heteronyms in context,
    /// then partitions phonemes by word boundary, with isolated word synthesis fallback
    /// for merged multi-word idiom contractions.
    ///
    /// - Parameters:
    ///   - text: The text to convert to phonemes
    ///   - dialect: The English dialect to use (defaults to generic English)
    /// - Returns: Array of WordPhonemes with detailed position information
    public func getPhonemesDetailed(for text: String, dialect: Dialect = .generic) -> [WordPhonemes] {
        synthesisLock.lock()
        defer { synthesisLock.unlock() }
        
        // 1. Set the voice for the desired dialect (with verification)
        let dialectSet = setDialect(dialect)
        if !dialectSet {
            print("EspeakManager: WARNING - Could not set dialect \(dialect.rawValue), using fallback")
        }
        
        // 2. Clean the text but preserve structure
        let cleanedText = cleanText(text)
        
        // 3. Extract words from the cleaned text
        let words = extractWords(from: cleanedText)
        guard !words.isEmpty else { return [] }
        
        // 4. Synthesize the FULL SENTENCE to provide eSpeak with complete grammatical context
        clear()
        _ = cleanedText.withCString { cText in
            espeak_ng_Synthesize(cText, strlen(cText) + 1, 0, POS_CHARACTER, 0, UInt32(espeakCHARS_UTF8), nil, nil)
        }
        espeak_ng_Synchronize()
        
        // 5. Partition phonemes by word boundary using 1-based textPosition
        var wordPhonemesList: [[PhonemeWithPosition]] = Array(repeating: [], count: words.count)
        
        for p in currentPhonemes {
            var assigned = false
            for i in stride(from: words.count - 1, through: 0, by: -1) {
                let wordStart1Based = words[i].position + 1
                if p.textPosition >= wordStart1Based {
                    wordPhonemesList[i].append(p)
                    assigned = true
                    break
                }
            }
            if !assigned && !words.isEmpty {
                wordPhonemesList[0].append(p)
            }
        }
        
        // 6. Map to WordPhonemes results, with fallback for merged phrases or missing words
        var result: [WordPhonemes] = []
        for (i, word) in words.enumerated() {
            let phonemesForWord = wordPhonemesList[i]
            let nextWordEmpty = (i + 1 < words.count) && wordPhonemesList[i + 1].isEmpty
            let needsFallback = phonemesForWord.isEmpty || nextWordEmpty
            
            if needsFallback {
                let synth = synthesizeWord(word.word)
                result.append(WordPhonemes(
                    word: word.word,
                    phonemes: synth.phonemes,
                    startPosition: word.position,
                    endPosition: word.position + word.word.count,
                    primaryStressIndex: synth.primaryStressIndex
                ))
            } else {
                let phonemes = phonemesForWord.map { $0.phoneme }
                let primaryStressIdx = phonemesForWord.firstIndex(where: { $0.isPrimaryStressed })
                result.append(WordPhonemes(
                    word: word.word,
                    phonemes: phonemes,
                    startPosition: word.position,
                    endPosition: word.position + word.word.count,
                    primaryStressIndex: primaryStressIdx
                ))
            }
        }
        
        // 7. Apply MINIMAL context-aware corrections
        // IMPORTANT: Only correct articles, NOT content words!
        // Let eSpeak's output stand for most words to preserve dialect differences
        result = applyMinimalContextCorrections(to: result)
        
        return result
    }
    
    /// Synthesizes a single word and returns its phonemes and primary stress index
    private func synthesizeWord(_ word: String) -> (phonemes: [String], primaryStressIndex: Int?) {
        // Clear previous state
        clear()
        
        // Synthesize the word
        _ = word.withCString { cText in
            espeak_ng_Synthesize(cText, strlen(cText) + 1, 0, POS_CHARACTER, 0, UInt32(espeakCHARS_UTF8), nil, nil)
        }
        
        // Force eSpeak to process all remaining buffered events
        espeak_ng_Synchronize()
        
        // Return the phonemes collected with primary stress index
        let phonemes = currentPhonemes.map { $0.phoneme }
        let primaryStress = currentPhonemes.firstIndex(where: { $0.isPrimaryStressed })
        return (phonemes, primaryStress)
    }
    
    /// Applies MINIMAL context-aware corrections to phonemes
    ///
    /// PHILOSOPHY: Only correct words where the citation (dictionary) form would sound
    /// WRONG or FOREIGN in connected speech - not just "careful" or "emphatic".
    ///
    /// CRITERIA FOR CORRECTION:
    /// 1. The citation form would sound unnatural/foreign in connected speech
    /// 2. Native speakers virtually never use the citation form in normal speech
    /// 3. Using the citation form changes perceived meaning (implies unintended emphasis)
    ///
    /// ARTICLES ONLY meet this criteria:
    /// - "a" /eɪ/ → /ə/: Saying "I am /eɪ/ boy" sounds like spelling the letter
    /// - "an" /æn/ → /ən/: Similar to "a"
    /// - "the" /ðiː/ → /ðə/: Using /ðiː/ before consonants implies contrast
    ///
    /// EVERYTHING ELSE is left alone because both forms are acceptable:
    /// - "for" /fɔːr/ vs /fər/: Both fine; full form = careful speech, not wrong
    /// - "to" /tuː/ vs /tə/: Both acceptable
    /// - "of" /ʌv/ vs /əv/: Both acceptable
    /// - "and" /ænd/ vs /ənd/: Both common
    /// - "can", "you", "are", etc.: All have acceptable full forms
    ///
    /// The PronunciationScorer's similarity checking handles these variants.
    private func applyMinimalContextCorrections(to wordPhonemes: [WordPhonemes]) -> [WordPhonemes] {
        var result = wordPhonemes
        
        for (index, wordPhoneme) in wordPhonemes.enumerated() {
            let word = wordPhoneme.word.lowercased()
            let isNotFirstWord = index > 0
            let isNotLastWord = index < wordPhonemes.count - 1
            let isInContext = isNotFirstWord || isNotLastWord
            
            var correctedPhonemes: [String]? = nil
            
            switch word {
                
            // ═══════════════════════════════════════════════════════════════
            // ARTICLE "a"
            // Citation: /eɪ/ (like the letter name)
            // Connected: /ə/ (schwa)
            //
            // WHY CORRECT: Saying "I want /eɪ/ cookie" sounds like you're
            // spelling out the letter or making a contrast ("I want A cookie,
            // not THE cookie"). Native speakers essentially never use /eɪ/
            // in normal connected speech.
            // ═══════════════════════════════════════════════════════════════
            case "a":
                if isInContext {
                    correctedPhonemes = ["ə"]
                }
                
            // ═══════════════════════════════════════════════════════════════
            // ARTICLE "an"
            // Citation: /æn/
            // Connected: /ən/
            //
            // WHY CORRECT: Same as "a" - the full vowel sounds emphatic/foreign
            // in connected speech. "I want /æn/ apple" implies contrast.
            // ═══════════════════════════════════════════════════════════════
            case "an":
                if isInContext {
                    correctedPhonemes = ["ə", "n"]
                }
                
            // ═══════════════════════════════════════════════════════════════
            // ARTICLE "the" - DO NOT CORRECT
            //
            // Both /ðiː/ and /ðə/ are acceptable in natural speech:
            // - "the /ðə/ book" ✓
            // - "the /ðiː/ book" ✓ (slightly emphatic but not wrong)
            // - "the /ðiː/ apple" ✓ (before vowels)
            // - "the /ðə/ apple" ✓ (casual, also fine)
            //
            // Unlike "a/an", using either form doesn't sound foreign or wrong.
            // Native speakers mix these freely. Let eSpeak's output stand and
            // the scorer will accept both via wordSpecificVariants.
            // ═══════════════════════════════════════════════════════════════
            // case "the": -- REMOVED, both forms acceptable
                
            // ═══════════════════════════════════════════════════════════════
            // EVERYTHING ELSE: NO CORRECTION
            // ═══════════════════════════════════════════════════════════════
            default:
                break
            }
            
            // Only update if we have a correction
            if let phonemes = correctedPhonemes {
                result[index] = WordPhonemes(
                    word: wordPhoneme.word,
                    phonemes: phonemes,
                    startPosition: wordPhoneme.startPosition,
                    endPosition: wordPhoneme.endPosition,
                    primaryStressIndex: wordPhoneme.primaryStressIndex
                )
            }
        }
        
        // ═══════════════════════════════════════════════════════════════
        // FINAL PASS: Split complex diphthongs for better ML alignment
        // ═══════════════════════════════════════════════════════════════
        // eSpeak sometimes outputs merged phonemes like "aɪə" that ML models
        // segment differently (e.g., as "ɑ j ɪ"). We split these here so
        // alignment works properly.
        result = result.map { wordPhoneme in
            let splitPhonemes = splitComplexDiphthongs(wordPhoneme.phonemes)
            return WordPhonemes(
                word: wordPhoneme.word,
                phonemes: splitPhonemes,
                startPosition: wordPhoneme.startPosition,
                endPosition: wordPhoneme.endPosition,
                primaryStressIndex: wordPhoneme.primaryStressIndex
            )
        }
        
        return result
    }
    
    /// Split complex diphthong sequences that ML models often segment differently
    /// e.g., "aɪə" → ["aɪ", "ə"] for better alignment with ML outputs like "ɑ j ɪ"
    private func splitComplexDiphthongs(_ phonemes: [String]) -> [String] {
        var result: [String] = []
        
        for phoneme in phonemes {
            // PRICE + schwa: "aɪə" (as in "client", "lion", "iron", "fire")
            // eSpeak: k l aɪə n t
            // ML often outputs: k l ɑ j ɪ n t
            // By splitting to: k l aɪ ə n t, alignment works better
            if phoneme == "aɪə" {
                result.append("aɪ")
                result.append("ə")
            }
            // Add more complex sequences here if needed in the future:
            // - "aʊə" (MOUTH + schwa, as in "hour", "power")
            // - "eɪə" (FACE + schwa, rare but possible)
            else {
                result.append(phoneme)
            }
        }
        
        return result
    }
    
    // MARK: - Private Helpers
    
    /// Sets the eSpeak voice to the specified dialect
    /// Returns success/failure and only changes if different from current
    @discardableResult
    private func setDialect(_ dialect: Dialect) -> Bool {
        // Skip if already set to this dialect
        if currentDialect == dialect {
            return true
        }
        
        let result = espeak_ng_SetVoiceByName(dialect.voiceName)
        
        if result == ENS_OK {
            currentDialect = dialect
            return true
        } else {
            print("EspeakManager: ERROR - Failed to set voice '\(dialect.voiceName)', error code: \(result)")
            
            // Fallback to generic if US fails
            if dialect == .us {
                print("EspeakManager: Trying fallback to generic 'en'...")
                let fallbackResult = espeak_ng_SetVoiceByName("en")
                if fallbackResult == ENS_OK {
                    currentDialect = .generic
                    print("EspeakManager: Fallback to 'en' succeeded")
                }
            }
            
            return false
        }
    }
    
    /// Cleans text while preserving word structure
    private func cleanText(_ text: String) -> String {
        // Define punctuation to remove, but KEEP apostrophes and hyphens
        // Hyphens are important for compound words like "in-person"
        let punctuationToStrip = CharacterSet.punctuationCharacters
            .subtracting(CharacterSet(charactersIn: "'-"))
        
        // Remove extra punctuation but keep spacing
        var cleaned = ""
        for char in text {
            if char.unicodeScalars.allSatisfy({ punctuationToStrip.contains($0) }) {
                // Skip punctuation (except apostrophes and hyphens)
                continue
            }
            cleaned.append(char)
        }
        
        return cleaned
    }
    
    /// Extracts words and their positions from text
    private func extractWords(from text: String) -> [(word: String, position: Int)] {
        var words: [(String, Int)] = []
        var currentWord = ""
        var wordStart = 0
        
        for (index, char) in text.enumerated() {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    words.append((currentWord, wordStart))
                    currentWord = ""
                }
            } else {
                if currentWord.isEmpty {
                    wordStart = index
                }
                currentWord.append(char)
            }
        }
        
        // Add the last word
        if !currentWord.isEmpty {
            words.append((currentWord, wordStart))
        }
        
        return words
    }
    
    // MARK: - Internal Callback Handlers
    
    /// (Called by C callback) Appends a phoneme to the internal list with its position
    internal func accumulate(phoneme: String, textPosition: Int) {
        // 1. Filter out known separators
        if phoneme.isEmpty || phoneme == " " || phoneme == "_" {
            return
        }
        
        // Track primary stress marker
        let isStressed = isNextPrimaryStressed || phoneme.contains("ˈ")
        isNextPrimaryStressed = false
        
        // 2. Clean stress markers and eSpeak-specific annotations
        var cleanedPhoneme = phoneme
            .replacingOccurrences(of: "ˈ", with: "")  // Primary stress
            .replacingOccurrences(of: "ˌ", with: "")  // Secondary stress
            .replacingOccurrences(of: "\u{200D}", with: "") // Zero-Width Joiner (ZWJ) used in rhotic diphthongs
        
        // 3. Remove eSpeak-specific annotation characters
        let espeakAnnotations: [String] = ["H", "ʰ", "ʲ", "ⁿ", "ˡ", "ʷ", "ˠ", "ˤ", "̚"]
        for annotation in espeakAnnotations {
            cleanedPhoneme = cleanedPhoneme.replacingOccurrences(of: annotation, with: "")
        }
        
        // 4. Filter out corrupted/invalid Unicode characters
        cleanedPhoneme = String(cleanedPhoneme.unicodeScalars.filter { scalar in
            return scalar.value != 0xFFFD &&
                   scalar.value != 0x0000 &&
                   scalar.value >= 0x0020
        })
        
        // 5. If the string was only a marker or is now empty, preserve stress flag for next phoneme
        if cleanedPhoneme.isEmpty {
            if isStressed {
                isNextPrimaryStressed = true
            }
            return
        }
        
        // 6. Append the cleaned phoneme with its position and stress flag
        currentPhonemes.append(PhonemeWithPosition(
            phoneme: cleanedPhoneme,
            textPosition: textPosition,
            isPrimaryStressed: isStressed
        ))
    }
    
    /// (Called by C callback) Marks a word boundary
    internal func markWordBoundary(textPosition: Int, length: Int) {
        wordBoundaries.append((position: textPosition, length: length))
    }
    
    /// Resets the internal state for a new synthesis task
    private func clear() {
        currentPhonemes = []
        wordBoundaries = []
        isNextPrimaryStressed = false
    }
    
    /// Loads and decodes the vocab.json file
    private func loadVocabulary() {
        guard let url = Bundle.main.url(forResource: "vocab", withExtension: "json") else {
            print("EspeakManager: WARNING - vocab.json not found. Phoneme filtering will be disabled.")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let vocab = try JSONDecoder().decode(Vocabulary.self, from: data)
            
            let specialTokens = Set([
                vocab.specialTokens.pad,
                vocab.specialTokens.unk,
                vocab.specialTokens.bos,
                vocab.specialTokens.eos
            ])
            
            self.validPhonemes = Set(vocab.tokenToId.keys.filter { !specialTokens.contains($0) })
            
            print("EspeakManager: Successfully loaded \(self.validPhonemes.count) valid phonemes.")
        } catch {
            print("EspeakManager: ERROR - Failed to load vocab.json: \(error)")
        }
    }
}

// MARK: - Vocabulary Model

private nonisolated struct Vocabulary: Decodable {
    let vocabSize: Int
    let tokenToId: [String: Int]
    let specialTokens: SpecialTokens
    
    enum CodingKeys: String, CodingKey {
        case vocabSize = "vocab_size"
        case tokenToId = "token_to_id"
        case specialTokens = "special_tokens"
    }
}

private nonisolated struct SpecialTokens: Decodable {
    let pad: String
    let unk: String
    let bos: String
    let eos: String
}
