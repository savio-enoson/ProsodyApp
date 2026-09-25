import Foundation

// MARK: - Phoneme Category & Position

nonisolated public enum PhonemeCategory: String, Sendable, CaseIterable {
    case vowel = "Vowel"
    case diphthong = "Diphthong"
    case stop = "Stop Consonant"
    case fricative = "Fricative"
    case affricate = "Affricate"
    case nasal = "Nasal"
    case approximant = "Approximant / Liquid"
}

nonisolated public enum WordPosition: String, Sendable, CaseIterable {
    case initial = "initial"
    case medial = "medial"
    case final = "final"
    case any = "any"
}

// MARK: - Minimal Pair Model

nonisolated public struct MinimalPair: Sendable, Hashable, Identifiable {
    public var id: String { "\(targetWord)-\(contrastWord)" }
    public let targetWord: String
    public let contrastWord: String
    public let targetPhoneme: String
    public let contrastPhoneme: String
    public let note: String

    public init(targetWord: String, contrastWord: String, targetPhoneme: String, contrastPhoneme: String, note: String = "") {
        self.targetWord = targetWord
        self.contrastWord = contrastWord
        self.targetPhoneme = targetPhoneme
        self.contrastPhoneme = contrastPhoneme
        self.note = note
    }
}

// MARK: - Phoneme Sound Info

nonisolated public struct PhonemeSoundInfo: Sendable {
    public let symbol: String                   // Canonical IPA (e.g. "θ")
    public let aliases: [String]                // Variant notations (e.g. ["th", "T", "soft th"])
    public let friendlyName: String             // e.g. "\"th\" (soft / unvoiced)"
    public let anchorWord: String               // e.g. "think"
    public let articulationTip: String          // Actionable mouth/tongue placement guidance
    public let category: PhonemeCategory
    public let initialWords: [String]           // Words starting with sound
    public let medialWords: [String]            // Words with sound in middle
    public let finalWords: [String]              // Words ending with sound
    public let minimalPairs: [MinimalPair]

    public var allPracticeWords: [String] {
        var set: [String] = []
        for w in initialWords + medialWords + finalWords {
            if !set.contains(w) { set.append(w) }
        }
        return set
    }

    public init(
        symbol: String,
        aliases: [String] = [],
        friendlyName: String,
        anchorWord: String,
        articulationTip: String,
        category: PhonemeCategory,
        initialWords: [String] = [],
        medialWords: [String] = [],
        finalWords: [String] = [],
        minimalPairs: [MinimalPair] = []
    ) {
        self.symbol = symbol
        self.aliases = aliases
        self.friendlyName = friendlyName
        self.anchorWord = anchorWord
        self.articulationTip = articulationTip
        self.category = category
        self.initialWords = initialWords
        self.medialWords = medialWords
        self.finalWords = finalWords
        self.minimalPairs = minimalPairs
    }
}

// MARK: - Phoneme Lexicon Singleton

nonisolated public final class PhonemeLexicon: Sendable {
    public static let shared = PhonemeLexicon()

    private let entries: [String: PhonemeSoundInfo]
    private let aliasMap: [String: String]

    private init() {
        let catalog = Self.buildCatalog()
        var entryMap: [String: PhonemeSoundInfo] = [:]
        var aliases: [String: String] = [:]

        for entry in catalog {
            entryMap[entry.symbol] = entry
            let cleanSym = Self.cleanToken(entry.symbol)
            aliases[cleanSym] = entry.symbol

            for alias in entry.aliases {
                let cleanAlias = Self.cleanToken(alias)
                aliases[cleanAlias] = entry.symbol
            }
        }

        self.entries = entryMap
        self.aliasMap = aliases
    }

    // MARK: - Query API

    /// Look up comprehensive sound info by IPA symbol, eSpeak phone, or respelling alias.
    public nonisolated func lookup(phoneme: String) -> PhonemeSoundInfo? {
        let cleaned = Self.cleanToken(phoneme)
        if let canonical = aliasMap[cleaned], let entry = entries[canonical] {
            return entry
        }
        if let direct = entries[phoneme] {
            return direct
        }
        return nil
    }

    /// Retrieve common everyday practice words for a given phoneme with optional position filtering.
    public nonisolated func findWords(forPhoneme phoneme: String, position: WordPosition? = .any, limit: Int = 5) -> [String] {
        guard let entry = lookup(phoneme: phoneme) else { return [] }
        let pos = position ?? .any

        let candidates: [String]
        switch pos {
        case .initial:
            candidates = entry.initialWords.isEmpty ? entry.allPracticeWords : entry.initialWords
        case .medial:
            candidates = entry.medialWords.isEmpty ? entry.allPracticeWords : entry.medialWords
        case .final:
            candidates = entry.finalWords.isEmpty ? entry.allPracticeWords : entry.finalWords
        case .any:
            candidates = entry.allPracticeWords
        }

        return Array(candidates.prefix(max(1, limit)))
    }

    /// Retrieve targeted minimal pairs contrasting a target phoneme against a common substitution.
    public nonisolated func findMinimalPairs(target: String, contrast: String? = nil) -> [MinimalPair] {
        guard let entry = lookup(phoneme: target) else { return [] }

        guard let contrast = contrast, !contrast.isEmpty else {
            return entry.minimalPairs
        }

        let cleanContrast = Self.cleanToken(contrast)
        let contrastCanonical = aliasMap[cleanContrast] ?? cleanContrast

        let filtered = entry.minimalPairs.filter {
            let pairContrastClean = Self.cleanToken($0.contrastPhoneme)
            return pairContrastClean == cleanContrast || $0.contrastPhoneme == contrastCanonical
        }

        return filtered.isEmpty ? entry.minimalPairs : filtered
    }

    // MARK: - Helpers

    public nonisolated static func cleanToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "ː", with: "")
    }

    // MARK: - Comprehensive Catalog (44 English Phonemes)

    private static func buildCatalog() -> [PhonemeSoundInfo] {
        return [
            // ==================== FRICATIVES ====================
            PhonemeSoundInfo(
                symbol: "θ",
                aliases: ["th", "t_h", "soft th", "unvoiced th", "theta"],
                friendlyName: "\"th\" (soft / unvoiced)",
                anchorWord: "think",
                articulationTip: "Rest the tip of your tongue gently between your front teeth. Blow air through softly without vibrating your vocal cords.",
                category: .fricative,
                initialWords: ["think", "three", "thank", "thin", "thought", "theater", "throw", "thick", "thirty", "thumb"],
                medialWords: ["author", "birthday", "healthy", "nothing", "bathtub", "panther", "athlete", "method"],
                finalWords: ["bath", "math", "mouth", "breath", "path", "tooth", "south", "earth", "growth", "faith"],
                minimalPairs: [
                    MinimalPair(targetWord: "think", contrastWord: "sink", targetPhoneme: "θ", contrastPhoneme: "s", note: "/θ/ vs /s/"),
                    MinimalPair(targetWord: "thick", contrastWord: "sick", targetPhoneme: "θ", contrastPhoneme: "s", note: "/θ/ vs /s/"),
                    MinimalPair(targetWord: "path", contrastWord: "pass", targetPhoneme: "θ", contrastPhoneme: "s", note: "/θ/ vs /s/"),
                    MinimalPair(targetWord: "three", contrastWord: "tree", targetPhoneme: "θ", contrastPhoneme: "t", note: "/θ/ vs /t/"),
                    MinimalPair(targetWord: "thin", contrastWord: "tin", targetPhoneme: "θ", contrastPhoneme: "t", note: "/θ/ vs /t/"),
                    MinimalPair(targetWord: "both", contrastWord: "boat", targetPhoneme: "θ", contrastPhoneme: "t", note: "/θ/ vs /t/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ð",
                aliases: ["dh", "voiced th", "hard th", "eth"],
                friendlyName: "\"th\" (voiced)",
                anchorWord: "this",
                articulationTip: "Place the tip of your tongue between your front teeth, but turn on your voice box so you feel a buzz in your throat.",
                category: .fricative,
                initialWords: ["this", "that", "these", "those", "they", "them", "there", "then", "though", "their"],
                medialWords: ["mother", "father", "brother", "weather", "feather", "together", "bother", "leather"],
                finalWords: ["breathe", "smooth", "clothe", "bathe", "soothe"],
                minimalPairs: [
                    MinimalPair(targetWord: "they", contrastWord: "day", targetPhoneme: "ð", contrastPhoneme: "d", note: "/ð/ vs /d/"),
                    MinimalPair(targetWord: "then", contrastWord: "den", targetPhoneme: "ð", contrastPhoneme: "d", note: "/ð/ vs /d/"),
                    MinimalPair(targetWord: "breathe", contrastWord: "breed", targetPhoneme: "ð", contrastPhoneme: "d", note: "/ð/ vs /d/"),
                    MinimalPair(targetWord: "there", contrastWord: "dare", targetPhoneme: "ð", contrastPhoneme: "d", note: "/ð/ vs /d/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ʃ",
                aliases: ["sh", "esh"],
                friendlyName: "\"sh\" sound",
                anchorWord: "ship",
                articulationTip: "Round your lips slightly, pull your tongue back from your front teeth, and blow air smoothly with no vocal cord vibration.",
                category: .fricative,
                initialWords: ["ship", "shop", "shoe", "shine", "share", "short", "sheet", "shower", "shadow", "shape"],
                medialWords: ["ocean", "action", "nation", "cushion", "fashion", "machine", "wishing", "washer"],
                finalWords: ["wish", "fish", "wash", "push", "rush", "fresh", "dish", "crash", "finish", "brush"],
                minimalPairs: [
                    MinimalPair(targetWord: "ship", contrastWord: "sip", targetPhoneme: "ʃ", contrastPhoneme: "s", note: "/ʃ/ vs /s/"),
                    MinimalPair(targetWord: "sheet", contrastWord: "seat", targetPhoneme: "ʃ", contrastPhoneme: "s", note: "/ʃ/ vs /s/"),
                    MinimalPair(targetWord: "shoe", contrastWord: "sue", targetPhoneme: "ʃ", contrastPhoneme: "s", note: "/ʃ/ vs /s/"),
                    MinimalPair(targetWord: "wash", contrastWord: "watch", targetPhoneme: "ʃ", contrastPhoneme: "tʃ", note: "/ʃ/ vs /tʃ/"),
                    MinimalPair(targetWord: "wish", contrastWord: "witch", targetPhoneme: "ʃ", contrastPhoneme: "tʃ", note: "/ʃ/ vs /tʃ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ʒ",
                aliases: ["zh", "ezh"],
                friendlyName: "\"zh\" (soft j / measure)",
                anchorWord: "measure",
                articulationTip: "Shape your lips and tongue as if saying \"sh\", but turn on your voice box to produce a humming buzz.",
                category: .fricative,
                initialWords: ["genre"],
                medialWords: ["measure", "treasure", "pleasure", "vision", "decision", "television", "leisure", "usual"],
                finalWords: ["beige", "massage", "garage", "mirage"],
                minimalPairs: [
                    MinimalPair(targetWord: "measure", contrastWord: "mesher", targetPhoneme: "ʒ", contrastPhoneme: "ʃ", note: "/ʒ/ vs /ʃ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "s",
                aliases: ["s"],
                friendlyName: "\"s\" sound",
                anchorWord: "sun",
                articulationTip: "Touch the sides of your tongue to your upper molars and force air through the center groove over your top front teeth.",
                category: .fricative,
                initialWords: ["sun", "see", "say", "sit", "some", "stop", "smile", "start", "sound", "sweet"],
                medialWords: ["lesson", "music", "pencil", "listen", "person", "inside", "sister", "baseball"],
                finalWords: ["yes", "bus", "pass", "miss", "this", "nice", "voice", "place", "class", "house"],
                minimalPairs: [
                    MinimalPair(targetWord: "sink", contrastWord: "think", targetPhoneme: "s", contrastPhoneme: "θ", note: "/s/ vs /θ/"),
                    MinimalPair(targetWord: "sip", contrastWord: "ship", targetPhoneme: "s", contrastPhoneme: "ʃ", note: "/s/ vs /ʃ/"),
                    MinimalPair(targetWord: "sue", contrastWord: "zoo", targetPhoneme: "s", contrastPhoneme: "z", note: "/s/ vs /z/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "z",
                aliases: ["z"],
                friendlyName: "\"z\" sound",
                anchorWord: "zoo",
                articulationTip: "Make the \"s\" shape with your tongue, but vibrate your vocal cords so you feel a strong buzzing sensation.",
                category: .fricative,
                initialWords: ["zoo", "zero", "zipper", "zone", "zebra"],
                medialWords: ["easy", "music", "busy", "desert", "frozen", "closet", "season", "cousin"],
                finalWords: ["is", "has", "was", "buzz", "rose", "eyes", "please", "always", "nose", "size"],
                minimalPairs: [
                    MinimalPair(targetWord: "zoo", contrastWord: "sue", targetPhoneme: "z", contrastPhoneme: "s", note: "/z/ vs /s/"),
                    MinimalPair(targetWord: "buzz", contrastWord: "bus", targetPhoneme: "z", contrastPhoneme: "s", note: "/z/ vs /s/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "f",
                aliases: ["f"],
                friendlyName: "\"f\" sound",
                anchorWord: "fish",
                articulationTip: "Rest your upper front teeth lightly against your lower lip and blow air out without voice.",
                category: .fricative,
                initialWords: ["fish", "food", "five", "face", "fast", "friend", "family", "find", "fall", "first"],
                medialWords: ["coffee", "after", "office", "muffin", "breakfast", "telephone", "profile"],
                finalWords: ["life", "off", "leaf", "half", "laugh", "roof", "safe", "enough", "tough"],
                minimalPairs: [
                    MinimalPair(targetWord: "fan", contrastWord: "van", targetPhoneme: "f", contrastPhoneme: "v", note: "/f/ vs /v/"),
                    MinimalPair(targetWord: "leaf", contrastWord: "leave", targetPhoneme: "f", contrastPhoneme: "v", note: "/f/ vs /v/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "v",
                aliases: ["v"],
                friendlyName: "\"v\" sound",
                anchorWord: "voice",
                articulationTip: "Rest your upper front teeth against your lower lip just like \"f\", but vibrate your vocal cords with a buzz.",
                category: .fricative,
                initialWords: ["voice", "very", "view", "visit", "village", "video", "van", "valley", "value"],
                medialWords: ["every", "river", "seven", "never", "heavy", "travel", "movie", "silver", "level"],
                finalWords: ["live", "have", "give", "save", "move", "love", "leave", "wave", "five", "drive"],
                minimalPairs: [
                    MinimalPair(targetWord: "van", contrastWord: "fan", targetPhoneme: "v", contrastPhoneme: "f", note: "/v/ vs /f/"),
                    MinimalPair(targetWord: "vest", contrastWord: "best", targetPhoneme: "v", contrastPhoneme: "b", note: "/v/ vs /b/"),
                    MinimalPair(targetWord: "vine", contrastWord: "wine", targetPhoneme: "v", contrastPhoneme: "w", note: "/v/ vs /w/"),
                    MinimalPair(targetWord: "vet", contrastWord: "wet", targetPhoneme: "v", contrastPhoneme: "w", note: "/v/ vs /w/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "h",
                aliases: ["h"],
                friendlyName: "\"h\" sound",
                anchorWord: "house",
                articulationTip: "Open your mouth relaxed and exhale a breath of air from your throat without restricting it.",
                category: .fricative,
                initialWords: ["house", "home", "hello", "hand", "happy", "heart", "head", "hope", "hear", "help"],
                medialWords: ["behind", "ahead", "anyhow", "perhaps", "behave"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "hat", contrastWord: "at", targetPhoneme: "h", contrastPhoneme: "æ", note: "/h/ dropped"),
                    MinimalPair(targetWord: "hear", contrastWord: "ear", targetPhoneme: "h", contrastPhoneme: "ɪ", note: "/h/ dropped")
                ]
            ),

            // ==================== AFFRICATES ====================
            PhonemeSoundInfo(
                symbol: "tʃ",
                aliases: ["ch", "tch"],
                friendlyName: "\"ch\" sound",
                anchorWord: "chair",
                articulationTip: "Start with your tongue touching the roof of your mouth like \"t\", then release quickly into a \"sh\" burst.",
                category: .affricate,
                initialWords: ["chair", "cheese", "child", "check", "choose", "church", "chance", "change", "cheap"],
                medialWords: ["teacher", "picture", "kitchen", "nature", "matches", "watching"],
                finalWords: ["beach", "match", "catch", "reach", "much", "such", "rich", "teach", "watch"],
                minimalPairs: [
                    MinimalPair(targetWord: "chair", contrastWord: "share", targetPhoneme: "tʃ", contrastPhoneme: "ʃ", note: "/tʃ/ vs /ʃ/"),
                    MinimalPair(targetWord: "catch", contrastWord: "cash", targetPhoneme: "tʃ", contrastPhoneme: "ʃ", note: "/tʃ/ vs /ʃ/"),
                    MinimalPair(targetWord: "chin", contrastWord: "shin", targetPhoneme: "tʃ", contrastPhoneme: "ʃ", note: "/tʃ/ vs /ʃ/"),
                    MinimalPair(targetWord: "choke", contrastWord: "joke", targetPhoneme: "tʃ", contrastPhoneme: "dʒ", note: "/tʃ/ vs /dʒ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "dʒ",
                aliases: ["jh", "j", "soft g"],
                friendlyName: "\"j / soft g\"",
                anchorWord: "jump",
                articulationTip: "Begin with your tongue firmly touching the roof of your mouth like \"d\", then explode into a voiced \"zh\" sound.",
                category: .affricate,
                initialWords: ["jump", "joy", "job", "juice", "jacket", "journey", "general", "giant", "jungle"],
                medialWords: ["magic", "engine", "project", "danger", "soldier", "enjoy", "agent"],
                finalWords: ["page", "age", "bridge", "edge", "large", "orange", "change", "huge"],
                minimalPairs: [
                    MinimalPair(targetWord: "joke", contrastWord: "choke", targetPhoneme: "dʒ", contrastPhoneme: "tʃ", note: "/dʒ/ vs /tʃ/"),
                    MinimalPair(targetWord: "badge", contrastWord: "batch", targetPhoneme: "dʒ", contrastPhoneme: "tʃ", note: "/dʒ/ vs /tʃ/"),
                    MinimalPair(targetWord: "jewel", contrastWord: "duel", targetPhoneme: "dʒ", contrastPhoneme: "d", note: "/dʒ/ vs /d/")
                ]
            ),

            // ==================== STOPS ====================
            PhonemeSoundInfo(
                symbol: "p",
                aliases: ["p"],
                friendlyName: "\"p\" sound",
                anchorWord: "pen",
                articulationTip: "Press your lips firmly together to build up air, then pop them open with a puff of unvoiced air.",
                category: .stop,
                initialWords: ["pen", "paper", "park", "people", "play", "point", "put", "place", "part"],
                medialWords: ["apple", "happy", "open", "simple", "paper", "super"],
                finalWords: ["stop", "cup", "help", "keep", "sleep", "top", "hope", "map", "group"],
                minimalPairs: [
                    MinimalPair(targetWord: "pat", contrastWord: "bat", targetPhoneme: "p", contrastPhoneme: "b", note: "/p/ vs /b/"),
                    MinimalPair(targetWord: "cap", contrastWord: "cab", targetPhoneme: "p", contrastPhoneme: "b", note: "/p/ vs /b/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "b",
                aliases: ["b"],
                friendlyName: "\"b\" sound",
                anchorWord: "book",
                articulationTip: "Press both lips together like \"p\", but vibrate your vocal cords right as you release the burst.",
                category: .stop,
                initialWords: ["book", "boy", "ball", "baby", "big", "best", "black", "blue", "bring"],
                medialWords: ["table", "rabbit", "rubber", "robot", "about", "number", "member"],
                finalWords: ["job", "club", "web", "grab", "cab", "rub", "tube", "robe"],
                minimalPairs: [
                    MinimalPair(targetWord: "bat", contrastWord: "pat", targetPhoneme: "b", contrastPhoneme: "p", note: "/b/ vs /p/"),
                    MinimalPair(targetWord: "best", contrastWord: "vest", targetPhoneme: "b", contrastPhoneme: "v", note: "/b/ vs /v/"),
                    MinimalPair(targetWord: "boat", contrastWord: "vote", targetPhoneme: "b", contrastPhoneme: "v", note: "/b/ vs /v/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "t",
                aliases: ["t"],
                friendlyName: "\"t\" sound",
                anchorWord: "time",
                articulationTip: "Tap the tip of your tongue firmly against the ridge behind your upper front teeth, releasing a crisp tap of air.",
                category: .stop,
                initialWords: ["time", "today", "table", "take", "tell", "two", "top", "try", "together"],
                medialWords: ["water", "butter", "city", "letter", "little", "better", "winter", "meeting"],
                finalWords: ["cat", "hat", "meet", "night", "part", "light", "sweet", "start", "great", "out"],
                minimalPairs: [
                    MinimalPair(targetWord: "time", contrastWord: "dime", targetPhoneme: "t", contrastPhoneme: "d", note: "/t/ vs /d/"),
                    MinimalPair(targetWord: "tin", contrastWord: "thin", targetPhoneme: "t", contrastPhoneme: "θ", note: "/t/ vs /θ/"),
                    MinimalPair(targetWord: "tree", contrastWord: "three", targetPhoneme: "t", contrastPhoneme: "θ", note: "/t/ vs /θ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "d",
                aliases: ["d"],
                friendlyName: "\"d\" sound",
                anchorWord: "door",
                articulationTip: "Press the tip of your tongue behind your top front teeth like \"t\", but vibrate your vocal cords as you release.",
                category: .stop,
                initialWords: ["door", "day", "dog", "down", "do", "dark", "deep", "drive", "dance"],
                medialWords: ["under", "body", "ladder", "window", "today", "garden", "order"],
                finalWords: ["red", "good", "bed", "hand", "friend", "hard", "food", "said", "world", "head"],
                minimalPairs: [
                    MinimalPair(targetWord: "day", contrastWord: "they", targetPhoneme: "d", contrastPhoneme: "ð", note: "/d/ vs /ð/"),
                    MinimalPair(targetWord: "den", contrastWord: "then", targetPhoneme: "d", contrastPhoneme: "ð", note: "/d/ vs /ð/"),
                    MinimalPair(targetWord: "dime", contrastWord: "time", targetPhoneme: "d", contrastPhoneme: "t", note: "/d/ vs /t/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "k",
                aliases: ["k", "c"],
                friendlyName: "\"k / hard c\"",
                anchorWord: "cat",
                articulationTip: "Raise the back of your tongue against your soft palate to block air, then release with an unvoiced burst.",
                category: .stop,
                initialWords: ["cat", "key", "come", "call", "keep", "cold", "clean", "color", "car"],
                medialWords: ["baker", "chicken", "pocket", "market", "second", "ticket", "cookie"],
                finalWords: ["book", "black", "back", "look", "make", "take", "week", "speak", "like"],
                minimalPairs: [
                    MinimalPair(targetWord: "coat", contrastWord: "goat", targetPhoneme: "k", contrastPhoneme: "ɡ", note: "/k/ vs /ɡ/"),
                    MinimalPair(targetWord: "back", contrastWord: "bag", targetPhoneme: "k", contrastPhoneme: "ɡ", note: "/k/ vs /ɡ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɡ",
                aliases: ["g", "hard g"],
                friendlyName: "\"hard g\"",
                anchorWord: "go",
                articulationTip: "Block air with the back of your tongue like \"k\", but engage your vocal cords with a guttural release.",
                category: .stop,
                initialWords: ["go", "get", "good", "give", "girl", "great", "green", "game", "gold"],
                medialWords: ["tiger", "sugar", "again", "begin", "finger", "bigger", "foggy"],
                finalWords: ["big", "dog", "bag", "leg", "egg", "flag", "hug", "pig", "frog"],
                minimalPairs: [
                    MinimalPair(targetWord: "goat", contrastWord: "coat", targetPhoneme: "ɡ", contrastPhoneme: "k", note: "/ɡ/ vs /k/"),
                    MinimalPair(targetWord: "bag", contrastWord: "back", targetPhoneme: "ɡ", contrastPhoneme: "k", note: "/ɡ/ vs /k/")
                ]
            ),

            // ==================== NASALS ====================
            PhonemeSoundInfo(
                symbol: "m",
                aliases: ["m"],
                friendlyName: "\"m\" sound",
                anchorWord: "mother",
                articulationTip: "Close your lips together and let your voice hum continuously out through your nose.",
                category: .nasal,
                initialWords: ["mother", "man", "make", "more", "my", "milk", "money", "music", "morning"],
                medialWords: ["summer", "lemon", "family", "camera", "simple", "climbing"],
                finalWords: ["time", "come", "home", "name", "room", "from", "team", "dream", "warm"],
                minimalPairs: [
                    MinimalPair(targetWord: "mouse", contrastWord: "house", targetPhoneme: "m", contrastPhoneme: "h", note: "/m/ vs /h/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "n",
                aliases: ["n"],
                friendlyName: "\"n\" sound",
                anchorWord: "night",
                articulationTip: "Press the tip of your tongue against your gum ridge behind top teeth, letting your voice hum out through your nose.",
                category: .nasal,
                initialWords: ["night", "name", "no", "new", "now", "never", "near", "nice", "number"],
                medialWords: ["winter", "dinner", "funny", "window", "under", "banana", "sunny"],
                finalWords: ["sun", "run", "in", "on", "can", "ten", "man", "open", "green", "rain"],
                minimalPairs: [
                    MinimalPair(targetWord: "sin", contrastWord: "sing", targetPhoneme: "n", contrastPhoneme: "ŋ", note: "/n/ vs /ŋ/"),
                    MinimalPair(targetWord: "thin", contrastWord: "thing", targetPhoneme: "n", contrastPhoneme: "ŋ", note: "/n/ vs /ŋ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ŋ",
                aliases: ["ng", "eng"],
                friendlyName: "\"ng\" sound",
                anchorWord: "sing",
                articulationTip: "Press the back of your tongue against your soft palate (as if saying \"g\") and direct your voice through your nose without releasing a \"g\" pop.",
                category: .nasal,
                initialWords: [],
                medialWords: ["singer", "finger", "hanger", "longest", "english", "kangaroo"],
                finalWords: ["sing", "ring", "song", "long", "king", "bring", "spring", "young", "wing"],
                minimalPairs: [
                    MinimalPair(targetWord: "sing", contrastWord: "sin", targetPhoneme: "ŋ", contrastPhoneme: "n", note: "/ŋ/ vs /n/"),
                    MinimalPair(targetWord: "thing", contrastWord: "thin", targetPhoneme: "ŋ", contrastPhoneme: "n", note: "/ŋ/ vs /n/"),
                    MinimalPair(targetWord: "ring", contrastWord: "rim", targetPhoneme: "ŋ", contrastPhoneme: "m", note: "/ŋ/ vs /m/")
                ]
            ),

            // ==================== APPROXIMANTS & LIQUIDS ====================
            PhonemeSoundInfo(
                symbol: "l",
                aliases: ["l"],
                friendlyName: "\"l\" sound",
                anchorWord: "light",
                articulationTip: "Place the tip of your tongue against the tooth ridge and let voiced air flow smoothly around the sides of your tongue.",
                category: .approximant,
                initialWords: ["light", "look", "love", "like", "long", "little", "learn", "life", "late"],
                medialWords: ["yellow", "color", "follow", "only", "early", "apple", "silver", "cloud"],
                finalWords: ["ball", "tell", "feel", "call", "school", "all", "full", "cool", "smile"],
                minimalPairs: [
                    MinimalPair(targetWord: "light", contrastWord: "right", targetPhoneme: "l", contrastPhoneme: "ɹ", note: "/l/ vs /r/"),
                    MinimalPair(targetWord: "glass", contrastWord: "grass", targetPhoneme: "l", contrastPhoneme: "ɹ", note: "/l/ vs /r/"),
                    MinimalPair(targetWord: "climb", contrastWord: "crime", targetPhoneme: "l", contrastPhoneme: "ɹ", note: "/l/ vs /r/"),
                    MinimalPair(targetWord: "lead", contrastWord: "read", targetPhoneme: "l", contrastPhoneme: "ɹ", note: "/l/ vs /r/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɹ",
                aliases: ["r", "er"],
                friendlyName: "\"r\" sound",
                anchorWord: "red",
                articulationTip: "Curl the tip of your tongue slightly backward without touching the roof of your mouth. Round your lips slightly and vibrate.",
                category: .approximant,
                initialWords: ["red", "run", "rain", "read", "road", "room", "river", "right", "real"],
                medialWords: ["tree", "green", "spring", "friend", "carry", "sorry", "around", "every"],
                finalWords: ["car", "door", "near", "water", "star", "fire", "four", "her", "mother"],
                minimalPairs: [
                    MinimalPair(targetWord: "right", contrastWord: "light", targetPhoneme: "ɹ", contrastPhoneme: "l", note: "/r/ vs /l/"),
                    MinimalPair(targetWord: "grass", contrastWord: "glass", targetPhoneme: "ɹ", contrastPhoneme: "l", note: "/r/ vs /l/"),
                    MinimalPair(targetWord: "read", contrastWord: "lead", targetPhoneme: "ɹ", contrastPhoneme: "l", note: "/r/ vs /l/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "w",
                aliases: ["w"],
                friendlyName: "\"w\" sound",
                anchorWord: "water",
                articulationTip: "Form a tight \"O\" circle with your lips, raise the back of your tongue, and glide smoothly into the following vowel.",
                category: .approximant,
                initialWords: ["water", "we", "will", "walk", "with", "word", "warm", "white", "window"],
                medialWords: ["away", "always", "between", "sweet", "twenty", "flower"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "wine", contrastWord: "vine", targetPhoneme: "w", contrastPhoneme: "v", note: "/w/ vs /v/"),
                    MinimalPair(targetWord: "west", contrastWord: "vest", targetPhoneme: "w", contrastPhoneme: "v", note: "/w/ vs /v/"),
                    MinimalPair(targetWord: "wet", contrastWord: "vet", targetPhoneme: "w", contrastPhoneme: "v", note: "/w/ vs /v/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "j",
                aliases: ["y"],
                friendlyName: "\"y\" sound",
                anchorWord: "yes",
                articulationTip: "Arch the front of your tongue close to your hard palate as in \"ee\", then quickly release into the next vowel.",
                category: .approximant,
                initialWords: ["yes", "you", "year", "yellow", "young", "yesterday", "yard"],
                medialWords: ["beyond", "million", "onion", "music", "view"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "year", contrastWord: "ear", targetPhoneme: "j", contrastPhoneme: "ɪ", note: "/j/ glide vs vowel")
                ]
            ),

            // ==================== SHORT VOWELS ====================
            PhonemeSoundInfo(
                symbol: "æ",
                aliases: ["ae", "short a"],
                friendlyName: "\"short a\"",
                anchorWord: "cat",
                articulationTip: "Drop your jaw open wide and flatten your tongue low in the mouth with the tongue tip behind your bottom teeth.",
                category: .vowel,
                initialWords: ["apple", "after", "act", "animal", "ask", "add"],
                medialWords: ["cat", "hat", "black", "back", "hand", "man", "bad", "happy", "fast", "class"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "bad", contrastWord: "bed", targetPhoneme: "æ", contrastPhoneme: "ɛ", note: "/æ/ vs /ɛ/"),
                    MinimalPair(targetWord: "man", contrastWord: "men", targetPhoneme: "æ", contrastPhoneme: "ɛ", note: "/æ/ vs /ɛ/"),
                    MinimalPair(targetWord: "pan", contrastWord: "pen", targetPhoneme: "æ", contrastPhoneme: "ɛ", note: "/æ/ vs /ɛ/"),
                    MinimalPair(targetWord: "cat", contrastWord: "cut", targetPhoneme: "æ", contrastPhoneme: "ʌ", note: "/æ/ vs /ʌ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɛ",
                aliases: ["e", "short e"],
                friendlyName: "\"short e\"",
                anchorWord: "bed",
                articulationTip: "Open your mouth halfway, relax your lips, and raise your tongue mid-height in the center of your mouth.",
                category: .vowel,
                initialWords: ["egg", "end", "every", "enter", "empty", "elephant"],
                medialWords: ["bed", "red", "head", "get", "tell", "best", "seven", "help", "never", "friend"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "bed", contrastWord: "bad", targetPhoneme: "ɛ", contrastPhoneme: "æ", note: "/ɛ/ vs /æ/"),
                    MinimalPair(targetWord: "pen", contrastWord: "pan", targetPhoneme: "ɛ", contrastPhoneme: "æ", note: "/ɛ/ vs /æ/"),
                    MinimalPair(targetWord: "men", contrastWord: "man", targetPhoneme: "ɛ", contrastPhoneme: "æ", note: "/ɛ/ vs /æ/"),
                    MinimalPair(targetWord: "desk", contrastWord: "disk", targetPhoneme: "ɛ", contrastPhoneme: "ɪ", note: "/ɛ/ vs /ɪ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɪ",
                aliases: ["ih", "short i"],
                friendlyName: "\"short i\"",
                anchorWord: "sit",
                articulationTip: "Keep your mouth slightly open with relaxed lips and tongue resting slightly high, without stretching wide.",
                category: .vowel,
                initialWords: ["in", "is", "it", "into", "if", "inside"],
                medialWords: ["sit", "fish", "big", "give", "milk", "dinner", "winter", "listen", "city"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "sit", contrastWord: "seat", targetPhoneme: "ɪ", contrastPhoneme: "i", note: "/ɪ/ vs /iː/"),
                    MinimalPair(targetWord: "ship", contrastWord: "sheep", targetPhoneme: "ɪ", contrastPhoneme: "i", note: "/ɪ/ vs /iː/"),
                    MinimalPair(targetWord: "fit", contrastWord: "feet", targetPhoneme: "ɪ", contrastPhoneme: "i", note: "/ɪ/ vs /iː/"),
                    MinimalPair(targetWord: "live", contrastWord: "leave", targetPhoneme: "ɪ", contrastPhoneme: "i", note: "/ɪ/ vs /iː/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "i",
                aliases: ["i:", "ee", "long e", "iy"],
                friendlyName: "\"long ee\"",
                anchorWord: "see",
                articulationTip: "Spread your lips wide like a tight smile, raising the front of your tongue high towards the roof of your mouth.",
                category: .vowel,
                initialWords: ["eat", "each", "easy", "east", "even", "eagle"],
                medialWords: ["seat", "sheep", "feel", "meet", "clean", "people", "green", "keep", "sleep"],
                finalWords: ["see", "tree", "me", "we", "he", "she", "free", "key"],
                minimalPairs: [
                    MinimalPair(targetWord: "seat", contrastWord: "sit", targetPhoneme: "i", contrastPhoneme: "ɪ", note: "/iː/ vs /ɪ/"),
                    MinimalPair(targetWord: "sheep", contrastWord: "ship", targetPhoneme: "i", contrastPhoneme: "ɪ", note: "/iː/ vs /ɪ/"),
                    MinimalPair(targetWord: "feet", contrastWord: "fit", targetPhoneme: "i", contrastPhoneme: "ɪ", note: "/iː/ vs /ɪ/"),
                    MinimalPair(targetWord: "leave", contrastWord: "live", targetPhoneme: "i", contrastPhoneme: "ɪ", note: "/iː/ vs /ɪ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɒ",
                aliases: ["o", "short o", "aa"],
                friendlyName: "\"short o\" (open ah)",
                anchorWord: "hot",
                articulationTip: "Open your jaw wide and round your lips very slightly, letting the sound resonate deep in your throat.",
                category: .vowel,
                initialWords: ["on", "off", "often", "orange", "octopus"],
                medialWords: ["hot", "dog", "box", "stop", "clock", "body", "pocket", "coffee", "hospital"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "hot", contrastWord: "hat", targetPhoneme: "ɒ", contrastPhoneme: "æ", note: "/ɒ/ vs /æ/"),
                    MinimalPair(targetWord: "cot", contrastWord: "caught", targetPhoneme: "ɒ", contrastPhoneme: "ɔ", note: "/ɒ/ vs /ɔː/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ʌ",
                aliases: ["ah", "short u", "wedge"],
                friendlyName: "\"short u\" (stressed uh)",
                anchorWord: "cup",
                articulationTip: "Relax your jaw and lips completely. Make a short, quick \"uh\" sound from the center of your mouth.",
                category: .vowel,
                initialWords: ["up", "under", "uncle", "ugly", "us", "umbrella"],
                medialWords: ["cup", "sun", "run", "bus", "love", "much", "summer", "funny", "brother", "money"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "cup", contrastWord: "cap", targetPhoneme: "ʌ", contrastPhoneme: "æ", note: "/ʌ/ vs /æ/"),
                    MinimalPair(targetWord: "cut", contrastWord: "cat", targetPhoneme: "ʌ", contrastPhoneme: "æ", note: "/ʌ/ vs /æ/"),
                    MinimalPair(targetWord: "luck", contrastWord: "lock", targetPhoneme: "ʌ", contrastPhoneme: "ɒ", note: "/ʌ/ vs /ɒ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ʊ",
                aliases: ["oo", "short oo", "uh"],
                friendlyName: "\"short oo\"",
                anchorWord: "book",
                articulationTip: "Round your lips loosely and raise the back of your tongue moderately without pushing your lips forward.",
                category: .vowel,
                initialWords: [],
                medialWords: ["book", "look", "good", "foot", "wood", "put", "push", "full", "sugar", "cookie"],
                finalWords: [],
                minimalPairs: [
                    MinimalPair(targetWord: "look", contrastWord: "Luke", targetPhoneme: "ʊ", contrastPhoneme: "u", note: "/ʊ/ vs /uː/"),
                    MinimalPair(targetWord: "pull", contrastWord: "pool", targetPhoneme: "ʊ", contrastPhoneme: "u", note: "/ʊ/ vs /uː/"),
                    MinimalPair(targetWord: "full", contrastWord: "fool", targetPhoneme: "ʊ", contrastPhoneme: "u", note: "/ʊ/ vs /uː/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "u",
                aliases: ["u:", "oo", "long oo", "uw"],
                friendlyName: "\"long oo\"",
                anchorWord: "moon",
                articulationTip: "Push your lips forward into a tight circular puckered shape and raise the back of your tongue high.",
                category: .vowel,
                initialWords: [],
                medialWords: ["moon", "food", "school", "room", "blue", "group", "choose", "fruit", "music"],
                finalWords: ["to", "do", "who", "two", "shoe", "through", "you"],
                minimalPairs: [
                    MinimalPair(targetWord: "pool", contrastWord: "pull", targetPhoneme: "u", contrastPhoneme: "ʊ", note: "/uː/ vs /ʊ/"),
                    MinimalPair(targetWord: "fool", contrastWord: "full", targetPhoneme: "u", contrastPhoneme: "ʊ", note: "/uː/ vs /ʊ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ə",
                aliases: ["schwa", "ax"],
                friendlyName: "\"schwa\" (unstressed uh)",
                anchorWord: "sofa",
                articulationTip: "The most effortless sound in English: relax your jaw, lips, and tongue completely. Produce a short, lazy breath.",
                category: .vowel,
                initialWords: ["about", "again", "around", "alive", "alone", "away"],
                medialWords: ["banana", "family", "camera", "pencil", "today", "police", "salad"],
                finalWords: ["sofa", "panda", "soda", "china", "extra"],
                minimalPairs: []
            ),
            PhonemeSoundInfo(
                symbol: "ɜ",
                aliases: ["er", "ur", "ir", "er0"],
                friendlyName: "\"er / ur\" vowel",
                anchorWord: "bird",
                articulationTip: "Hold the center of your tongue neutral and curl the sides against your molars with your lips slightly relaxed.",
                category: .vowel,
                initialWords: ["early", "earth", "earn", "urgent"],
                medialWords: ["bird", "girl", "first", "world", "work", "learn", "turn", "nurse", "purple"],
                finalWords: ["her", "sir", "fur"],
                minimalPairs: []
            ),

            // ==================== DIPHTHONGS ====================
            PhonemeSoundInfo(
                symbol: "eɪ",
                aliases: ["ey", "long a", "ay"],
                friendlyName: "\"long a\" (ay)",
                anchorWord: "say",
                articulationTip: "Open with \"e\" (mid-open), then smoothly glide upward into a smiling \"ee\" finish.",
                category: .diphthong,
                initialWords: ["aim", "eight", "age", "april", "able"],
                medialWords: ["make", "take", "name", "game", "rain", "wait", "baby", "paper", "face"],
                finalWords: ["day", "say", "play", "stay", "way", "may", "today", "away"],
                minimalPairs: [
                    MinimalPair(targetWord: "pain", contrastWord: "pen", targetPhoneme: "eɪ", contrastPhoneme: "ɛ", note: "/eɪ/ vs /ɛ/"),
                    MinimalPair(targetWord: "wait", contrastWord: "wet", targetPhoneme: "eɪ", contrastPhoneme: "ɛ", note: "/eɪ/ vs /ɛ/"),
                    MinimalPair(targetWord: "late", contrastWord: "let", targetPhoneme: "eɪ", contrastPhoneme: "ɛ", note: "/eɪ/ vs /ɛ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "aɪ",
                aliases: ["ay", "long i", "eye"],
                friendlyName: "\"long i\" (eye)",
                anchorWord: "time",
                articulationTip: "Start with your mouth open wide for \"ah\", then glide smoothly into a tight smiling \"ee\".",
                category: .diphthong,
                initialWords: ["ice", "island", "idea", "iron", "eyes"],
                medialWords: ["time", "white", "night", "like", "find", "right", "light", "smile", "drive"],
                finalWords: ["my", "by", "why", "fly", "sky", "try", "buy", "die"],
                minimalPairs: [
                    MinimalPair(targetWord: "ride", contrastWord: "red", targetPhoneme: "aɪ", contrastPhoneme: "ɛ", note: "/aɪ/ vs /ɛ/"),
                    MinimalPair(targetWord: "bite", contrastWord: "bet", targetPhoneme: "aɪ", contrastPhoneme: "ɛ", note: "/aɪ/ vs /ɛ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "oʊ",
                aliases: ["ow", "long o", "oh", "əʊ"],
                friendlyName: "\"long o\" (oh)",
                anchorWord: "go",
                articulationTip: "Start with open lips and glide forward into a small, rounded \"oo\" circle.",
                category: .diphthong,
                initialWords: ["open", "over", "old", "ocean", "only"],
                medialWords: ["home", "boat", "road", "cold", "phone", "nose", "clothes", "close"],
                finalWords: ["go", "no", "so", "show", "slow", "know", "hello"],
                minimalPairs: [
                    MinimalPair(targetWord: "boat", contrastWord: "bought", targetPhoneme: "oʊ", contrastPhoneme: "ɔ", note: "/oʊ/ vs /ɔː/"),
                    MinimalPair(targetWord: "coat", contrastWord: "caught", targetPhoneme: "oʊ", contrastPhoneme: "ɔ", note: "/oʊ/ vs /ɔː/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "aʊ",
                aliases: ["aw", "ou", "ow"],
                friendlyName: "\"ow / ou\" (cow)",
                anchorWord: "house",
                articulationTip: "Open your jaw wide with \"ah\", then glide smoothly into puckered \"oo\" lips.",
                category: .diphthong,
                initialWords: ["out", "our", "owl", "outside"],
                medialWords: ["house", "mouth", "round", "sound", "brown", "cloud", "town", "mountain"],
                finalWords: ["now", "how", "cow", "allow"],
                minimalPairs: [
                    MinimalPair(targetWord: "town", contrastWord: "tone", targetPhoneme: "aʊ", contrastPhoneme: "oʊ", note: "/aʊ/ vs /oʊ/"),
                    MinimalPair(targetWord: "loud", contrastWord: "load", targetPhoneme: "aʊ", contrastPhoneme: "oʊ", note: "/aʊ/ vs /oʊ/")
                ]
            ),
            PhonemeSoundInfo(
                symbol: "ɔɪ",
                aliases: ["oy", "oi"],
                friendlyName: "\"oy\" sound",
                anchorWord: "boy",
                articulationTip: "Round your lips for \"aw\", then glide upward into an unrounded smiling \"ee\".",
                category: .diphthong,
                initialWords: ["oil", "oyster"],
                medialWords: ["voice", "noise", "point", "coin", "join", "choice", "toilet"],
                finalWords: ["boy", "toy", "joy", "enjoy"],
                minimalPairs: []
            ),
            PhonemeSoundInfo(
                symbol: "ɔ",
                aliases: ["aw", "long aw", "ɔ:"],
                friendlyName: "\"aw / or\" sound",
                anchorWord: "call",
                articulationTip: "Drop your jaw open and round your lips into an oval shape with your tongue pulled back.",
                category: .vowel,
                initialWords: ["all", "also", "always", "autumn", "awful"],
                medialWords: ["call", "ball", "water", "talk", "walk", "door", "morning", "warm", "short"],
                finalWords: ["saw", "law", "raw", "draw"],
                minimalPairs: [
                    MinimalPair(targetWord: "caught", contrastWord: "cot", targetPhoneme: "ɔ", contrastPhoneme: "ɒ", note: "/ɔː/ vs /ɒ/"),
                    MinimalPair(targetWord: "bought", contrastWord: "boat", targetPhoneme: "ɔ", contrastPhoneme: "oʊ", note: "/ɔː/ vs /oʊ/")
                ]
            )
        ]
    }
}
