import SwiftUI

/// Renders the editable transcript with dual-ASR discrepancy underlines and interactive swap popovers.
struct PracticeTranscriptDiffView: View {
    @ObservedObject var viewModel: ContentViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        CatalystPanel {
            let history = viewModel.committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let live = viewModel.activeLiveTranscript
            let isListeningActive = viewModel.audioManager.isSpeaking ||
                                   viewModel.audioManager.isRecording ||
                                   viewModel.sttManager.inference.isProcessing ||
                                   viewModel.isScoring

            VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                // Header toolbar
                HStack {
                    Label("Transcript", systemImage: "quote.bubble.fill")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)

                    let diffCount = viewModel.transcriptWords.filter(\.hasDifference).count
                    let uncertainCount = viewModel.transcriptWords.filter(\.isUncertain).count
                    if !isListeningActive {
                        if uncertainCount > 0 {
                            CatalystBadge("\(uncertainCount) to review", variant: .warning)
                        } else if diffCount > 0 {
                            CatalystBadge("\(diffCount) Neural alt\(diffCount == 1 ? "" : "s")", variant: .warning)
                        }
                    }

                    Spacer()

                    if !isListeningActive && !history.isEmpty {
                        CatalystButton(viewModel.isDirectEditing ? "Done" : "Edit Text", role: viewModel.isDirectEditing ? .primary : .default) {
                            if viewModel.isDirectEditing {
                                viewModel.commitDirectEdit()
                            } else {
                                viewModel.editableTranscriptText = viewModel.committedTranscript
                                viewModel.isDirectEditing = true
                            }
                        }
                    }
                }

                if isListeningActive {
                    // Streaming live speech mode
                    if !history.isEmpty || !live.isEmpty {
                        Group {
                            if !history.isEmpty && !live.isEmpty {
                                Text("\(Text(history).foregroundColor(.primary)) \(Text(live).foregroundColor(.secondary))")
                            } else if !history.isEmpty {
                                Text(history)
                                    .foregroundColor(.primary)
                            } else {
                                Text(live)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .font(Catalyst.Typography.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if viewModel.sttManager.inference.isProcessing || viewModel.isScoring {
                        HStack(spacing: Catalyst.Spacing.space2) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text(viewModel.sttManager.inference.isProcessing ? "Analyzing speech…" : "Evaluating pronunciation…")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, Catalyst.Spacing.space1)
                    } else if viewModel.audioManager.isSpeaking && live.isEmpty && history.isEmpty {
                        Text("Listening…")
                            .font(Catalyst.Typography.body)
                            .foregroundColor(.secondary)
                            .opacity(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Interactive review mode
                    if viewModel.isDirectEditing {
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                            TextEditor(text: $viewModel.editableTranscriptText)
                                .font(Catalyst.Typography.body)
                                .frame(minHeight: 80)
                                .padding(Catalyst.Spacing.space2)
                                .overlay(RoundedRectangle(cornerRadius: Catalyst.Radius.default).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                .onChange(of: viewModel.editableTranscriptText) { _, newText in
                                    viewModel.onEditableTextChanged(to: newText)
                                }

                            Text("Direct edit mode — changes auto-evaluate 5 seconds after typing stops.")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }
                    } else if !viewModel.transcriptWords.isEmpty {
                        FlowLayout(spacing: 5) {
                            ForEach(viewModel.transcriptWords) { word in
                                TranscriptWordItemView(word: word) { replacement in
                                    viewModel.swapWord(id: word.id, with: replacement)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !history.isEmpty {
                        Text(history)
                            .font(Catalyst.Typography.body)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Waiting for speech…")
                            .font(Catalyst.Typography.body)
                            .foregroundColor(.secondary)
                            .opacity(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Re-evaluation Countdown / Progress Indicator
                    if viewModel.isReevaluating {
                        HStack(spacing: Catalyst.Spacing.space2) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text("Re-evaluating pronunciation…")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.primary)
                        }
                        .padding(.top, Catalyst.Spacing.space1)
                    } else if viewModel.reevaluationCountdown > 0 {
                        HStack(spacing: Catalyst.Spacing.space2) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("Re-evaluating in \(viewModel.reevaluationCountdown)s…")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, Catalyst.Spacing.space1)
                    }
                }
            }
        }
    }
}

// MARK: - Transcript Word Item View

struct TranscriptWordItemView: View {
    let word: TranscriptWord
    let onSwap: (String) -> Void
    @State private var showingPopover: Bool = false
    @State private var customText: String = ""

    init(word: TranscriptWord, onSwap: @escaping (String) -> Void) {
        self.word = word
        self.onSwap = onSwap
    }

    var body: some View {
        let isFlagged = word.isUncertain || word.hasDifference
        if isFlagged {
            Button {
                customText = ""
                showingPopover = true
            } label: {
                HStack(spacing: 2) {
                    Text(word.text)
                        .font(Catalyst.Typography.body)
                        .foregroundColor(.primary)
                        .underline(true, color: word.isUncertain ? .yellow : .orange)
                    if word.isUncertain {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .offset(y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPopover) {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                    HStack(spacing: Catalyst.Spacing.space1) {
                        Image(systemName: word.isUncertain ? "questionmark.circle.fill" : "sparkles")
                            .foregroundColor(word.isUncertain ? .yellow : .orange)
                        Text(word.isUncertain ? "Uncertain transcription (\(Int(word.confidence * 100))%)" : "Alternative suggestion")
                            .font(Catalyst.Typography.caption1)
                            .foregroundColor(.secondary)
                    }

                    if !word.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                            Text("Suggestions:")
                                .font(Catalyst.Typography.caption2)
                                .foregroundColor(.secondary)
                            ForEach(Array(word.candidates.prefix(3)), id: \.self) { cand in
                                CatalystButton("Use “\(cand)”", role: .primary) {
                                    onSwap(cand)
                                    showingPopover = false
                                }
                            }
                        }
                    } else if let alt = word.alternative, !alt.isEmpty {
                        CatalystButton("Use “\(alt)”", role: .primary) {
                            onSwap(alt)
                            showingPopover = false
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                        Text("Or type correction:")
                            .font(Catalyst.Typography.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: Catalyst.Spacing.space2) {
                            TextField("Enter word…", text: $customText)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 120)
                            CatalystButton("Apply", role: .default) {
                                let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onSwap(trimmed)
                                    showingPopover = false
                                }
                            }
                            .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(Catalyst.Spacing.space3)
                .frame(minWidth: 220)
            }
        } else {
            Text(word.text)
                .font(Catalyst.Typography.body)
                .foregroundColor(.primary)
        }
    }
}
