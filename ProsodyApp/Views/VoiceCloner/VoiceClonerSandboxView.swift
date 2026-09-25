import SwiftUI
import AVFoundation

struct VoiceClonerSandboxView: View {
    @ObservedObject var tts: TTSManager = TTSManager.shared

    // MARK: - Script Constants
    private let defaultScript = "I wake up early every morning and make a fresh pot of coffee. I like to sit by the window, check my messages, and listen to the birds outside before starting my busy day."

    // MARK: - State
    @State private var targetText: String = "I wake up early every morning and make a fresh pot of coffee. I like to sit by the window, check my messages, and listen to the birds outside before starting my busy day."
    @State private var selectedBaseVoice: String = "auto"
    @State private var speed: Float = 1.0
    @State private var tau: Float = 0.35

    // Presets for practice
    private struct PresetText: Hashable {
        let label: String
        let text: String
    }

    private let presets: [PresetText] = [
        PresetText(label: "Full Script", text: "I wake up early every morning and make a fresh pot of coffee. I like to sit by the window, check my messages, and listen to the birds outside before starting my busy day."),
        PresetText(label: "Word: photosynthesis", text: "Photosynthesis is the process by which green plants use sunlight to synthesize nutrients."),
        PresetText(label: "Minimal Pair: think / sink", text: "I think the heavy metal ship will sink to the bottom of the deep ocean."),
        PresetText(label: "Minimal Pair: sheep / ship", text: "The sheep watched the large ship sail across the harbor."),
        PresetText(label: "Contrasts: comfortable", text: "Please make yourself comfortable while I finish preparing dinner.")
    ]

    private struct VoiceOption: Identifiable {
        let id: String
        let name: String
        let accent: String
    }

    private let voiceOptions: [VoiceOption] = [
        VoiceOption(id: "auto", name: "Automatic (Smart Match)", accent: "Auto"),
        VoiceOption(id: "af_heart", name: "American Heart (F)", accent: "US"),
        VoiceOption(id: "am_adam", name: "American Adam (M)", accent: "US"),
        VoiceOption(id: "bf_emma", name: "British Emma (F)", accent: "UK"),
        VoiceOption(id: "bm_george", name: "British George (M)", accent: "UK"),
        VoiceOption(id: "af_bella", name: "American Bella (F)", accent: "US"),
        VoiceOption(id: "am_michael", name: "American Michael (M)", accent: "US")
    ]

    private var matchedVoiceSummary: String {
        guard let profile = tts.activeProfile else { return "Auto (af_heart / bf_emma)" }
        let match = VoiceClonerNativeEngine.shared.resolveOptimalBaseVoice(
            for: profile.timbreEmbedding,
            estimatedF0: profile.estimatedF0,
            dialect: STTSettings.shared.targetDialect,
            isChild: STTSettings.shared.isChildLearnerMode
        )
        return "\(match.displayName) [\(match.voiceId)]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Catalyst.Spacing.space5) {

            // MARK: - Header & Server Status
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                    HStack(spacing: Catalyst.Spacing.space2) {
                        Text("Voice Cloner Sandbox")
                            .font(Catalyst.Typography.title2)
                        CatalystBadge("Native In-Process", variant: .success)
                    }
                    Text("Voice cloning testbed: clones your vocal timbre while enforcing canonical native pronunciation.")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Engine Status Indicator
                HStack(spacing: Catalyst.Spacing.space2) {
                    Circle()
                        .fill(tts.isEngineReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(tts.isEngineReady ? "Engine Ready (On-Device)" : "Loading Models...")
                        .font(Catalyst.Typography.caption2)
                        .foregroundColor(.secondary)
                    CatalystButton("Refresh", role: .default) {
                        tts.updateEngineStatus()
                    }
                }
            }

            if !tts.isEngineReady {
                CatalystAlertBanner(
                    .info,
                    message: tts.engineStatusDetail,
                    title: "Speech Engine Status"
                )
            }

            if let err = tts.errorMessage {
                CatalystAlertBanner(.danger, message: err, title: "Notice")
            }

            // MARK: - 1. Voice Profile & Reference Audio Section
            CatalystPanel {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                    HStack {
                        Label("Step 1: Learner Voice Profile", systemImage: "waveform.badge.mic")
                            .font(Catalyst.Typography.headline)
                        Spacer()
                        if tts.activeProfile != nil {
                            CatalystBadge("Profile Active", variant: .success)
                        } else if tts.referenceAudioURL != nil {
                            CatalystBadge("Sample Ready", variant: .success)
                        } else {
                            CatalystBadge("No Profile Yet", variant: .slate)
                        }
                    }

                    // Silent Profiling Status Card
                    if let profile = tts.activeProfile {
                        HStack(alignment: .center, spacing: Catalyst.Spacing.space3) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Catalyst.Spacing.space2) {
                                    Text("Continuous Silent Profile Active")
                                        .font(Catalyst.Typography.callout)
                                        .fontWeight(.semibold)
                                    Text("• \(profile.sampleCount) practice turns")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.secondary)
                                }
                                Text("Register: \(profile.registerDescription) (\(Int(round(profile.estimatedF0))) Hz) • Optimal Match: \(matchedVoiceSummary)")
                                    .font(Catalyst.Typography.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            CatalystButton("Reset Profile", role: .danger) {
                                tts.clearLearnerProfile()
                            }
                        }
                        .padding(Catalyst.Spacing.space3)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(Catalyst.Radius.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        )
                    } else {
                        Text("Prosody automatically learns your vocal timbre in the background as you speak during practice sessions. Alternatively, you can record a calibration sample below.")
                            .font(Catalyst.Typography.caption1)
                            .foregroundColor(.secondary)
                    }

                    Divider().padding(.vertical, 2)

                    Text("Manual Voice Sample (Optional Calibration):")
                        .font(Catalyst.Typography.caption2)
                        .foregroundColor(.secondary)

                    // Target Script Box
                    Text("\"\(defaultScript)\"")
                        .font(Catalyst.Typography.body)
                        .italic()
                        .padding(Catalyst.Spacing.space3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(Catalyst.Radius.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )

                    // Record & Playback Controls
                    HStack(spacing: Catalyst.Spacing.space4) {
                        CatalystButton(
                            tts.isRecording ? "Stop Recording" : (tts.referenceAudioURL == nil ? "Start Recording Sample" : "Re-record Sample"),
                            role: tts.isRecording ? .danger : .primary
                        ) {
                            if tts.isRecording {
                                tts.stopRecording()
                            } else {
                                tts.startRecording()
                            }
                        }

                        if tts.isRecording {
                            HStack(spacing: Catalyst.Spacing.space2) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text(String(format: "%.1fs", tts.recordingDuration))
                                    .font(Catalyst.Typography.callout)
                                    .foregroundColor(.red)

                                // Mini audio level bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.secondary.opacity(0.2))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.red)
                                            .frame(width: geo.size.width * CGFloat(tts.recordingMeterLevel))
                                    }
                                }
                                .frame(width: 60, height: 8)
                            }
                        } else if tts.referenceAudioURL != nil {
                            CatalystButton(
                                tts.isPlayingReference ? "Stop Preview" : "Play My Voice",
                                role: .default
                            ) {
                                if tts.isPlayingReference {
                                    tts.stopReference()
                                } else {
                                    tts.playReference()
                                }
                            }
                        }
                    }
                }
            }

            // MARK: - 2. Synthesis Target Textarea
            CatalystPanel {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                    HStack {
                        Label("Step 2: Text to Clone & Correct", systemImage: "text.quote")
                            .font(Catalyst.Typography.headline)
                        Spacer()
                        CatalystButton("Reset to Script", role: .default) {
                            targetText = defaultScript
                        }
                    }

                    Text("Specify what you want your cloned voice to say:")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)

                    TextEditor(text: $targetText)
                        .font(Catalyst.Typography.body)
                        .frame(minHeight: 70)
                        .padding(Catalyst.Spacing.space2)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(Catalyst.Radius.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: Catalyst.Radius.sm)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    // Presets
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Catalyst.Spacing.space2) {
                            Text("Presets:")
                                .font(Catalyst.Typography.caption2)
                                .foregroundColor(.secondary)

                            ForEach(presets, id: \.self) { preset in
                                Button(action: {
                                    targetText = preset.text
                                }) {
                                    Text(preset.label)
                                        .font(Catalyst.Typography.caption2)
                                        .padding(.horizontal, Catalyst.Spacing.space2)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            // MARK: - 3. Parameters, Dials & Toggles
            CatalystPanel {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                    Label("Step 3: Generation Parameters", systemImage: "slider.horizontal.3")
                        .font(Catalyst.Typography.headline)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Catalyst.Spacing.space4) {

                        // Parameter A: Base Speaker / Accent
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            HStack {
                                Text("Native Base Voice:")
                                    .font(Catalyst.Typography.callout)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(selectedBaseVoice)
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }

                            Picker("", selection: $selectedBaseVoice) {
                                ForEach(voiceOptions) { opt in
                                    Text("\(opt.name) [\(opt.accent)]").tag(opt.id)
                                }
                            }
                            .pickerStyle(.menu)

                            if selectedBaseVoice == "auto" {
                                Text("Auto mode matches optimal template (\(matchedVoiceSummary)) using your pitch register and target dialect.")
                                    .font(Catalyst.Typography.caption2)
                                    .foregroundColor(.accentColor)
                            } else {
                                Text("Kokoro-82M supplies canonical pronunciation and intonation.")
                                    .font(Catalyst.Typography.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Parameter B: Speaking Speed
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            HStack {
                                Text("Speaking Speed:")
                                    .font(Catalyst.Typography.callout)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(String(format: "%.2fx", speed))
                                    .font(Catalyst.Typography.caption1)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.accentColor)
                            }

                            Slider(value: $speed, in: 0.6...1.5, step: 0.05)

                            Text("Slower speeds allow learners to hear subtle phonetic transitions.")
                                .font(Catalyst.Typography.caption2)
                                .foregroundColor(.secondary)
                        }

                        // Parameter C: Tau (Tone Color Shift / Intensity)
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            HStack {
                                Text("Tone Color Intensity (Tau):")
                                    .font(Catalyst.Typography.callout)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(String(format: "%.2f", tau))
                                    .font(Catalyst.Typography.caption1)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.accentColor)
                            }

                            Slider(value: $tau, in: 0.05...1.0, step: 0.05)

                            Text("Higher = closer to your timbre; lower = preserves native phonetic stability.")
                                .font(Catalyst.Typography.caption2)
                                .foregroundColor(.secondary)
                        }

                        // Parameter D: Inference Engine
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            HStack {
                                Text("Inference Engine:")
                                    .font(Catalyst.Typography.callout)
                                    .fontWeight(.medium)
                                Spacer()
                                CatalystBadge("Apple Neural Engine", variant: .success)
                            }

                            Text("Runs 100% in-process via Apple CoreML with Neural Engine / GPU acceleration and zero external dependencies.")
                                .font(Catalyst.Typography.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // MARK: - 4. Generation Action & Telemetry Output
            CatalystPanel {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                    HStack {
                        let canGenerate = !tts.isGenerating &&
                            (tts.referenceAudioURL != nil || tts.activeProfile != nil) &&
                            !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                        CatalystButton(
                            tts.isGenerating ? "Synthesizing Cloned Voice…" : "Generate Cloned Voice",
                            role: .primary
                        ) {
                            Task {
                                await tts.generateGoldenSpeaker(
                                    text: targetText,
                                    baseVoice: selectedBaseVoice,
                                    speed: speed,
                                    tau: tau
                                )
                            }
                        }
                        .disabled(!canGenerate)

                        if tts.isGenerating {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.leading, Catalyst.Spacing.space2)
                            Text(tts.generationProgressMessage)
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Telemetry Results Card
                    if let infTime = tts.lastInferenceDuration,
                       let audDur = tts.lastAudioDuration,
                       let rtf = tts.lastRTF {

                        Divider().padding(.vertical, Catalyst.Spacing.space2)

                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                            HStack {
                                Label("Generation Benchmark & Output", systemImage: "sparkles")
                                    .font(Catalyst.Typography.headline)
                                Spacer()
                                // RTF Badge
                                CatalystBadge(
                                    String(format: "RTF: %.2fx", rtf),
                                    variant: rtf <= 1.0 ? .success : (rtf <= 2.0 ? .warning : .danger)
                                )
                            }

                            HStack(spacing: Catalyst.Spacing.space4) {
                                // Cloned Playback Button
                                CatalystButton(
                                    tts.isPlayingCloned ? "Stop Playing" : "Play Cloned Audio",
                                    role: .primary
                                ) {
                                    if tts.isPlayingCloned {
                                        tts.stopCloned()
                                    } else {
                                        tts.playCloned()
                                    }
                                }

                                if tts.referenceAudioURL != nil {
                                    CatalystButton(
                                        tts.isPlayingReference ? "Stop Original" : "Play Original Sample",
                                        role: .default
                                    ) {
                                        if tts.isPlayingReference {
                                            tts.stopReference()
                                        } else {
                                            tts.playReference()
                                        }
                                    }
                                }
                            }

                            // Telemetry metrics row
                            HStack(spacing: Catalyst.Spacing.space4) {
                                metricItem(label: "Inference Time", value: String(format: "%.2fs", infTime))
                                metricItem(label: "Audio Duration", value: String(format: "%.2fs", audDur))
                                metricItem(label: "Real-Time Factor", value: String(format: "%.2fx", rtf))
                                metricItem(label: "Device", value: tts.lastDeviceUsed ?? "Apple Silicon")
                            }
                            .padding(Catalyst.Spacing.space3)
                            .background(Color.secondary.opacity(0.04))
                            .cornerRadius(Catalyst.Radius.sm)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metricItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Catalyst.Typography.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(Catalyst.Typography.callout)
                .fontWeight(.semibold)
        }
    }
}
