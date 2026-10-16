import SwiftUI
import AVFoundation

/// Main practice container view coordinating speaking prompts, audio capture,
/// real-time transcript diffs, pronunciation scoring, and fluency results.
struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @ObservedObject private var settings = STTSettings.shared

    init() {}

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: Catalyst.Spacing.space6) {

                    // MARK: Header
                    VStack(spacing: Catalyst.Spacing.space2) {
                        Text("Prosody Acoustic Mirror")
                            .font(Catalyst.Typography.largeTitle)

                        HStack(spacing: Catalyst.Spacing.space2) {
                            Text("Engine:")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                            CatalystBadge(
                                settings.engineType.displayName,
                                variant: settings.engineType == .nemotron ? .success : .slate
                            )
                        }
                    }
                    .padding(.top, Catalyst.Spacing.space6)

                    // MARK: Mode Selector
                    CatalystTabs(
                        items: PracticePromptMode.allCases.map(\.label),
                        selected: Binding(
                            get: { viewModel.selectedPromptMode.rawValue },
                            set: { viewModel.selectedPromptMode = PracticePromptMode(rawValue: $0) ?? .conversation }
                        )
                    )
                    .frame(maxWidth: 580)

                    // MARK: Mode Content
                    if viewModel.selectedPromptMode == .voiceCloner {
                        VoiceClonerSandboxView()
                    } else {
                        switch viewModel.selectedPromptMode {
                        case .conversation:
                            promptPanel
                        case .artReflection:
                            ArtPromptPageView(artService: viewModel.artPromptService)
                        case .voiceCloner:
                            EmptyView()
                        }

                        // MARK: Recording & Control Bar
                        PracticeRecordingBar(viewModel: viewModel)

                        // MARK: Transcript & Diff Review
                        PracticeTranscriptDiffView(viewModel: viewModel)

                        // MARK: Evaluation Progress & Status
                        if viewModel.isTestStreaming {
                            HStack(spacing: Catalyst.Spacing.space2) {
                                ProgressView().scaleEffect(0.7)
                                Text(viewModel.testStreamingStatus)
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                                CatalystBadge("savio.wav", variant: .primary)
                            }
                        } else if viewModel.isFinishingSession {
                            HStack(spacing: Catalyst.Spacing.space2) {
                                ProgressView().scaleEffect(0.7)
                                Text("Finalizing session…")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                        } else if viewModel.isScoring {
                            HStack(spacing: Catalyst.Spacing.space2) {
                                ProgressView().scaleEffect(0.7)
                                Text(settings.engineType == .nemotron ? "Evaluating with Nemotron Core AI & Acoustic Mirror..." : "Evaluating pronunciation...")
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // MARK: Scoring Results
                        if let result = viewModel.scoringResult {
                            ScoringResultView(result: result)
                        }

                        // MARK: Fluency Results
                        if let fluency = viewModel.fluencyResult {
                            FluencyResultView(result: fluency)
                        }
                    }
                }
                .padding(Catalyst.Spacing.space6)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Model Loading Overlay
            if viewModel.isModelLoading {
                Color(NSColor.windowBackgroundColor).opacity(0.8).ignoresSafeArea()
                VStack {
                    ProgressView().scaleEffect(1.5).padding(.bottom, Catalyst.Spacing.space4)
                    Text("Loading Models...")
                        .font(Catalyst.Typography.callout)
                }
            } else if case .failed(let err) = viewModel.sttManager.inference.modelState {
                Color(NSColor.windowBackgroundColor).opacity(0.8).ignoresSafeArea()
                VStack {
                    Text("CoreML Model Error").font(Catalyst.Typography.headline).foregroundColor(.red)
                    Text(err).font(Catalyst.Typography.body)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $viewModel.showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $viewModel.showingCoaching) {
            if let record = viewModel.sessionManager.currentSession {
                CoachingChatView(coach: viewModel.coachingSessionService, record: record)
            }
        }
        .alert(isPresented: $viewModel.showingPermissionAlert) {
            Alert(
                title: Text("Microphone Access Required"),
                message: Text("Prosody needs microphone access to transcribe your speech. Please enable it in System Settings > Privacy & Security > Microphone."),
                primaryButton: .default(Text("Open Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            viewModel.prewarm()
        }
    }

    // MARK: - Prompt Panel

    @ViewBuilder
    private var promptPanel: some View {
        CatalystPanel {
            VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                HStack {
                    Label("Speaking Prompt", systemImage: "text.bubble.fill")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                    Spacer()

                    if viewModel.sessionManager.currentSession != nil && !viewModel.isTestStreaming {
                        CatalystButton("AI Coach Review", role: .primary) {
                            viewModel.showingCoaching = true
                        }
                    }

                    CatalystButton("New Prompt", role: .default) {
                        Task { await viewModel.promptService.generate() }
                    }
                    .disabled(viewModel.promptService.isGenerating || viewModel.isTestStreaming)

                    CatalystButton(
                        viewModel.isTestStreaming ? "Streaming…" : "Test Sample",
                        role: viewModel.isTestStreaming ? .danger : .default
                    ) {
                        if viewModel.isTestStreaming {
                            viewModel.cancelTestSample()
                        } else {
                            viewModel.runTestSample()
                        }
                    }
                    .disabled(viewModel.audioManager.isRecording || viewModel.isModelLoading)
                }

                if viewModel.promptService.isGenerating && viewModel.promptService.currentPrompt.isEmpty {
                    HStack(spacing: Catalyst.Spacing.space2) {
                        ProgressView().scaleEffect(0.7)
                        Text("Generating prompt…")
                            .font(Catalyst.Typography.body)
                            .foregroundColor(.secondary)
                    }
                } else if !viewModel.promptService.currentPrompt.isEmpty {
                    Text(viewModel.promptService.currentPrompt)
                        .font(Catalyst.Typography.body)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(SystemPrompts.defaultSpeakingPrompt())
                        .font(Catalyst.Typography.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
