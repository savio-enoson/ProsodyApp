import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = STTSettings.shared
    @ObservedObject var nemotronService = NemotronSTTService.shared
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var interests = InterestsStore.shared
    @ObservedObject var tts = TTSManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newTopic: String = ""
    @State private var showingResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: Catalyst.Spacing.space6) {

            // MARK: Header
            HStack {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                    Text("Settings")
                        .font(Catalyst.Typography.title1)
                    Text("Configure speech recognition and coaching personalisation.")
                        .font(Catalyst.Typography.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                CatalystButton("Close", role: .default) { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space6) {

                    // MARK: STT Engine Selection
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                        Text("Speech Recognition Engine")
                            .font(Catalyst.Typography.headline)

                        ForEach(STTEngineType.allCases) { engine in
                            Button(action: {
                                settings.engineType = engine
                                if engine == .nemotron {
                                    Task {
                                        await nemotronService.initializeIfNeeded()
                                    }
                                }
                            }) {
                                HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
                                    Image(systemName: settings.engineType == engine ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(settings.engineType == engine ? .accentColor : .secondary)
                                        .font(.system(size: 16))
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                        HStack {
                                            Text(engine.displayName)
                                                .font(Catalyst.Typography.body)
                                                .fontWeight(settings.engineType == engine ? .semibold : .regular)
                                                .foregroundColor(.primary)
                                            if engine == .nemotron {
                                                CatalystBadge("Core AI Streaming", variant: .success)
                                            } else {
                                                CatalystBadge("Strict Mirror", variant: .slate)
                                            }
                                        }
                                        Text(engine.description)
                                            .font(Catalyst.Typography.caption1)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                }
                                .padding(Catalyst.Spacing.space4)
                                .background(
                                    RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                        .stroke(settings.engineType == engine ? Color.accentColor : Color.secondary.opacity(0.2),
                                                lineWidth: settings.engineType == engine ? 2 : 1)
                                        .background(settings.engineType == engine
                                                    ? Color.accentColor.opacity(0.04)
                                                    : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // MARK: Nemotron Core AI Configuration
                    if settings.engineType == .nemotron {
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                            Text("Nemotron 3.5 Core AI Engine")
                                .font(Catalyst.Typography.headline)

                            Text("Direct Core AI FastConformer-RNNT on Apple Silicon GPU with 320ms streaming latency, native punctuation, and word timestamps.")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)

                            HStack(spacing: Catalyst.Spacing.space2) {
                                Text("Status:")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                                switch nemotronService.state {
                                case .uninitialized:
                                    CatalystBadge("Not Loaded", variant: .slate)
                                    Spacer()
                                    CatalystButton("Pre-load Model", role: .default) {
                                        Task { await nemotronService.initializeIfNeeded() }
                                    }
                                case .loading(let message):
                                    CatalystBadge("Loading...", variant: .warning)
                                    Text(message).font(Catalyst.Typography.caption1).foregroundColor(.secondary)
                                case .ready:
                                    CatalystBadge("Ready (Apple Core AI GPU)", variant: .success)
                                case .failed(let err):
                                    CatalystBadge("Error", variant: .danger)
                                    Text(err).font(Catalyst.Typography.caption1).foregroundColor(.red).lineLimit(1)
                                }
                            }
                            .padding(.top, Catalyst.Spacing.space1)
                        }
                        .padding(Catalyst.Spacing.space4)
                        .background(
                            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                .fill(Color.secondary.opacity(0.05))
                        )
                    }

                    // MARK: Pronunciation Scoring Engine
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                        Text("Pronunciation & Uncertainty Heads")
                            .font(Catalyst.Typography.headline)

                        // 23-Feature GBDT Neural Scorer
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                HStack {
                                    Text("Neural Word Intelligibility Scorer (CoreML)")
                                        .font(Catalyst.Typography.body)
                                        .fontWeight(.medium)
                                    if LearnedScoringEngine.shared.isReady {
                                        CatalystBadge("23-Feature GBDT", variant: .success)
                                    } else {
                                        CatalystBadge("Model Unavailable", variant: .warning)
                                    }
                                }
                                Text("Gradient-boosted decision trees trained on SpeechOcean762 using 23 acoustic, alignment, phonetic decoding, and stability signals.")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            CatalystBadge("Active", variant: .success)
                        }

                        Divider().padding(.vertical, Catalyst.Spacing.space1)

                        // 16-Feature CEM Uncertainty Classifier
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                HStack {
                                    Text("STT Uncertainty Classifier (CoreML)")
                                        .font(Catalyst.Typography.body)
                                        .fontWeight(.medium)
                                    if LearnedConfidenceEngine.shared.isReady {
                                        CatalystBadge("16-Feature CEM", variant: .success)
                                    } else {
                                        CatalystBadge("Acoustic Alignment Fallback", variant: .warning)
                                    }
                                }
                                Text("Gradient-boosted classifier identifying uncertain speech-to-text transcriptions (yellow chips) using 16 acoustic, entropy, ensemble, and beam consensus signals.")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            CatalystBadge(LearnedConfidenceEngine.shared.isReady ? "Active" : "Standby", variant: LearnedConfidenceEngine.shared.isReady ? .success : .warning)
                        }

                        Divider().padding(.vertical, Catalyst.Spacing.space1)

                        Toggle(isOn: $settings.isChildLearnerMode) {
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                HStack {
                                    Text("Child / Young Learner Acoustic Mode")
                                        .font(Catalyst.Typography.body)
                                        .fontWeight(.medium)
                                    CatalystBadge("Pediatric Adaptation", variant: .primary)
                                }
                                Text("Applies pediatric vocal tract normalization and demographic conditioning (ages 6–15) for pronunciation assessment.")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        Divider().padding(.vertical, Catalyst.Spacing.space1)

                        // MARK: Scoring Sensitivity & Threshold Sliders
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                            HStack {
                                Text("Scoring Sensitivity & Thresholds")
                                    .font(Catalyst.Typography.body)
                                    .fontWeight(.medium)
                                Spacer()
                                CatalystButton("Reset Defaults", role: .default) {
                                    settings.resetThresholds()
                                }
                            }

                            // Passing Threshold Slider (Good vs. Needs Work)
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                HStack {
                                    Text("Passing Threshold (Good vs. Needs Work)")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    CatalystBadge("\(settings.passingThreshold)%", variant: settings.passingThreshold == 65 ? .success : .primary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.passingThreshold) },
                                        set: { settings.passingThreshold = Int($0) }
                                    ),
                                    in: 50...85,
                                    step: 1
                                )
                                Text("Words scoring at or above \(settings.passingThreshold)% are marked Good (green). 65% is recommended to eliminate false alarms on minor phonetic variations.")
                                    .font(Catalyst.Typography.caption2)
                                    .foregroundColor(.secondary)
                            }

                            // Remediation Drill Trigger Threshold Slider
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                HStack {
                                    Text("AI Drill Trigger Threshold")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    CatalystBadge("\(settings.drillThreshold)%", variant: settings.drillThreshold == 60 ? .warning : .slate)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.drillThreshold) },
                                        set: { settings.drillThreshold = Int($0) }
                                    ),
                                    in: 40...75,
                                    step: 1
                                )
                                Text("Words scoring below \(settings.drillThreshold)% trigger the AI Coach to create interactive drill cards and synthesize Golden Speaker audio.")
                                    .font(Catalyst.Typography.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(Catalyst.Spacing.space4)
                    .background(
                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    // MARK: Target Accent & Voice Profile
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                        Text("Target Dialect & Voice Profile")
                            .font(Catalyst.Typography.headline)

                        // Dialect Selection
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            Text("Target Accent Dialect:")
                                .font(Catalyst.Typography.body)
                                .fontWeight(.medium)

                            Picker("Target Accent", selection: $settings.targetDialect) {
                                ForEach(TargetAccentDialect.allCases) { dialect in
                                    Text(dialect.displayName).tag(dialect)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(settings.targetDialect == .generalAmerican
                                ? "Practices General American English phonemes and matches US base templates (Heart, Adam, Michael, Bella)."
                                : "Practices British English (Received Pronunciation) and matches UK base templates (Emma, George).")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }

                        Divider().padding(.vertical, Catalyst.Spacing.space1)

                        // Learned Voice Profile Status
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            HStack {
                                Text("Acoustic Mirror Voice Profile:")
                                    .font(Catalyst.Typography.body)
                                    .fontWeight(.medium)
                                Spacer()
                                if tts.activeProfile != nil {
                                    CatalystBadge("Learned Profile Active", variant: .success)
                                } else {
                                    CatalystBadge("Profiling In Background", variant: .slate)
                                }
                            }

                            if let profile = tts.activeProfile {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Continuously learned from \(profile.sampleCount) practice speech turns.")
                                            .font(Catalyst.Typography.caption1)
                                            .foregroundColor(.primary)
                                        Text("Detected Register: \(profile.registerDescription) (\(Int(round(profile.estimatedF0))) Hz) • Timbre: 128-dim acoustic embedding")
                                            .font(Catalyst.Typography.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    CatalystButton("Reset Voice Profile", role: .danger) {
                                        tts.clearLearnerProfile()
                                    }
                                }
                                .padding(Catalyst.Spacing.space3)
                                .background(Color.secondary.opacity(0.05))
                                .cornerRadius(Catalyst.Radius.sm)
                            } else {
                                Text("Prosody automatically profiles your vocal timbre in the background while you speak practice phrases. No calibration recording required.")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(Catalyst.Spacing.space4)
                    .background(
                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    Divider()

                    // MARK: Base Language Model (AI Coach & Prompts)
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                Text("Base Language Model")
                                    .font(Catalyst.Typography.headline)
                                Text("Select the foundation model that powers speaking prompt generation and post-session coaching.")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            // Ollama Detection Status Indicator
                            HStack(spacing: Catalyst.Spacing.space2) {
                                if ollamaService.isChecking {
                                    CatalystBadge("Detecting Ollama…", variant: .warning)
                                } else if ollamaService.isConnected {
                                    CatalystBadge("Ollama: \(ollamaService.availableModels.count) Models Detected", variant: .success)
                                } else {
                                    CatalystBadge("Ollama Offline", variant: .slate)
                                }

                                Button {
                                    Task { await ollamaService.checkConnection() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Detect installed Ollama models")
                            }
                        }

                        // 1. Apple Intelligence Option (System Built-in)
                        Button(action: {
                            settings.selectedBaseModelID = "apple-intelligence"
                        }) {
                            let isSelected = settings.selectedBaseModelID == "apple-intelligence"
                            HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(isSelected ? .accentColor : .secondary)
                                    .font(.system(size: 16))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                    HStack {
                                        Text("Apple Intelligence")
                                            .font(Catalyst.Typography.body)
                                            .fontWeight(isSelected ? .semibold : .regular)
                                            .foregroundColor(.primary)
                                        CatalystBadge("System Built-in", variant: .primary)
                                    }
                                    Text("Native system foundation models with fast on-device inference, zero background memory setup, and tool calling.")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(Catalyst.Spacing.space4)
                            .background(
                                RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                                            lineWidth: isSelected ? 2 : 1)
                                    .background(isSelected ? Color.accentColor.opacity(0.04) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)

                        // 2. Detected Ollama Models (Dynamically listed)
                        if !ollamaService.availableModels.isEmpty {
                            ForEach(ollamaService.availableModels) { model in
                                Button(action: {
                                    settings.selectedBaseModelID = model.name
                                }) {
                                    let isSelected = settings.selectedBaseModelID == model.name
                                    HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
                                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(isSelected ? .accentColor : .secondary)
                                            .font(.system(size: 16))
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                            HStack {
                                                Text(model.name)
                                                    .font(Catalyst.Typography.body)
                                                    .fontWeight(isSelected ? .semibold : .regular)
                                                    .foregroundColor(.primary)
                                                CatalystBadge(model.sizeFormatted, variant: isSelected ? .success : .slate)
                                                CatalystBadge("Ollama", variant: .slate)
                                            }
                                            Text("Local open-weight model running via Ollama. Provides deep phonetic articulatory instruction and chain-of-thought coaching.")
                                                .font(Catalyst.Typography.caption1)
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                    }
                                    .padding(Catalyst.Spacing.space4)
                                    .background(
                                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                                                    lineWidth: isSelected ? 2 : 1)
                                            .background(isSelected ? Color.accentColor.opacity(0.04) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        } else if ollamaService.isConnected {
                            // Connected but no models installed
                            HStack(spacing: Catalyst.Spacing.space3) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                    Text("Ollama is active, but no models were detected.")
                                        .font(Catalyst.Typography.body)
                                        .fontWeight(.medium)
                                    Text("Pull a model in your terminal (e.g. `ollama pull gemma4:e4b-mlx`), then click Refresh.")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(Catalyst.Spacing.space4)
                            .background(
                                RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                    .fill(Color.orange.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                                    )
                            )
                        } else {
                            // Ollama Offline banner
                            HStack(spacing: Catalyst.Spacing.space3) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                    Text("Ollama daemon not detected on \(settings.ollamaEndpoint)")
                                        .font(Catalyst.Typography.body)
                                        .fontWeight(.medium)
                                    Text("Start Ollama in your terminal (`ollama serve`) to enable local open-weight models like Gemma 4.")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                CatalystButton("Detect", role: .default) {
                                    Task { await ollamaService.checkConnection() }
                                }
                            }
                            .padding(Catalyst.Spacing.space4)
                            .background(
                                RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                    .fill(Color.secondary.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                    )
                            )

                            // If user previously chose an Ollama model that is currently unreachable
                            if settings.llmProvider == .ollama {
                                HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
                                    Image(systemName: "largecircle.fill.circle")
                                        .foregroundColor(.accentColor)
                                        .font(.system(size: 16))
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                        HStack {
                                            Text(settings.ollamaModel)
                                                .font(Catalyst.Typography.body)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.primary)
                                            CatalystBadge("Offline", variant: .warning)
                                        }
                                        Text("Configured model is currently offline. Start Ollama to use this model.")
                                            .font(Catalyst.Typography.caption1)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(Catalyst.Spacing.space4)
                                .background(
                                    RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                                        .background(Color.orange.opacity(0.04))
                                )
                            }
                        }

                        // Advanced Ollama Endpoint config
                        DisclosureGroup("Advanced Ollama Endpoint") {
                            HStack(spacing: Catalyst.Spacing.space3) {
                                TextField("http://localhost:11434", text: $settings.ollamaEndpoint)
                                    .textFieldStyle(.plain)
                                    .font(Catalyst.Typography.caption1)
                                    .padding(Catalyst.Spacing.space2)
                                    .background(
                                        RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                            .fill(Color.secondary.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                            )
                                    )
                                    .onSubmit {
                                        Task { await ollamaService.checkConnection() }
                                    }

                                CatalystButton("Check", role: .default) {
                                    Task { await ollamaService.checkConnection() }
                                }
                            }
                            .padding(.top, Catalyst.Spacing.space2)
                        }
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // MARK: Interests / Personalisation
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                            Text("Speaking Topics & Interests")
                                .font(Catalyst.Typography.headline)
                            Text("The AI coach uses these topics to generate personalised speaking prompts.")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }

                        // Topic chips
                        SettingsFlowLayout(spacing: Catalyst.Spacing.space2) {
                            ForEach(interests.interests, id: \.self) { topic in
                                topicChip(topic)
                            }
                        }

                        // Add new topic
                        HStack(spacing: Catalyst.Spacing.space3) {
                            TextField("Add a topic…", text: $newTopic)
                                .textFieldStyle(.plain)
                                .font(Catalyst.Typography.body)
                                .padding(Catalyst.Spacing.space3)
                                .background(
                                    RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                        .fill(Color.secondary.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                )
                                .onSubmit { addTopic() }

                            CatalystButton("Add", role: .default) { addTopic() }
                                .disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        HStack {
                            Spacer()
                            CatalystButton("Reset to Defaults", role: .default) {
                                showingResetConfirm = true
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(Catalyst.Spacing.space6)
        .frame(minWidth: 520, minHeight: 520)
        .confirmationDialog(
            "Reset interests to defaults?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { interests.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your current topics with the default list.")
        }
        .task {
            await ollamaService.checkConnection()
        }
    }

    // MARK: - Topic Chip

    @ViewBuilder
    private func topicChip(_ topic: String) -> some View {
        HStack(spacing: Catalyst.Spacing.space1) {
            Text(topic)
                .font(Catalyst.Typography.caption1)
                .foregroundColor(.primary)
            Button {
                interests.remove(topic)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Catalyst.Spacing.space3)
        .padding(.vertical, Catalyst.Spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func addTopic() {
        let trimmed = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        interests.add(trimmed)
        newTopic = ""
    }
}

// MARK: - FlowLayout

/// A simple wrapping horizontal flow layout for the topic chips.
struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
