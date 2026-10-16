import SwiftUI
import AVFoundation

/// Control bar for initiating, stopping, and finalizing practice speaking sessions.
struct PracticeRecordingBar: View {
    @ObservedObject var viewModel: ContentViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: Catalyst.Spacing.space3) {
            HStack(spacing: Catalyst.Spacing.space4) {
                CatalystButton(
                    viewModel.audioManager.isRecording ? "Stop Listening" : "Start Listening",
                    role: viewModel.audioManager.isRecording ? .danger : .primary
                ) {
                    viewModel.onToggleListening()
                }

                if viewModel.sessionManager.isSessionActive {
                    CatalystButton(
                        viewModel.isFinishingSession ? "Finalizing…" : "Finish Session",
                        role: .primary
                    ) {
                        viewModel.onFinishSession()
                    }
                    .disabled(viewModel.isFinishingSession || viewModel.isTestStreaming)
                } else if viewModel.sessionManager.currentSession != nil {
                    CatalystButton("AI Coach Review", role: .primary) {
                        viewModel.showingCoaching = true
                    }
                }

                CatalystButton("Settings", role: .default) {
                    viewModel.showingSettings = true
                }
            }
            .disabled(viewModel.isModelLoading || viewModel.isTestStreaming)

            if viewModel.audioManager.isRecording {
                HStack(spacing: Catalyst.Spacing.space2) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Listening • Mic RMS: \(String(format: "%.4f", viewModel.audioManager.currentRMS))")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
