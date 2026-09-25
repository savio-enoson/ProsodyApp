import SwiftUI
import AppKit

// MARK: - ArtPromptPageView

/// A dedicated practice page presenting public domain artwork prompts for descriptive
/// and emotionally reflective English speaking practice.
struct ArtPromptPageView: View {
    @ObservedObject var artService: ArtPromptService

    @Environment(\.colorScheme) private var scheme
    @Environment(\.catalystAccent) private var accent

    var body: some View {
        CatalystPanel {
            VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
                // MARK: - Top Header & Attribution
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                        HStack(spacing: Catalyst.Spacing.space2) {
                            Label("Art & Reflection Prompt", systemImage: "paintpalette.fill")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(accent.text(scheme))

                            CatalystBadge(artService.currentArtwork.sourceName, variant: .info)

                            if artService.isAnalyzingVisuals {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 10, height: 10)
                                    Text("Analyzing with Apple Intelligence…")
                                        .font(Catalyst.Typography.caption2)
                                        .foregroundColor(Catalyst.Text.secondary(scheme))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Catalyst.Surface.overlay(scheme))
                                .cornerRadius(Catalyst.Radius.sm)
                            } else if artService.currentArtwork.isAIGenerated {
                                CatalystBadge("AI Guided", variant: .success)
                            }
                        }

                        Text(artService.currentArtwork.title)
                            .font(Catalyst.Typography.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(Catalyst.Text.primary(scheme))

                        HStack(spacing: Catalyst.Spacing.space2) {
                            Text(artService.currentArtwork.artist)
                                .font(Catalyst.Typography.callout)
                                .foregroundColor(Catalyst.Text.secondary(scheme))

                            if !artService.currentArtwork.date.isEmpty {
                                Text("•")
                                    .foregroundColor(Catalyst.Text.tertiary(scheme))
                                Text(artService.currentArtwork.date)
                                    .font(Catalyst.Typography.callout)
                                    .foregroundColor(Catalyst.Text.secondary(scheme))
                            }

                            if let dept = artService.currentArtwork.department, !dept.isEmpty {
                                Text("•")
                                    .foregroundColor(Catalyst.Text.tertiary(scheme))
                                Text(dept)
                                    .font(Catalyst.Typography.caption1)
                                    .foregroundColor(Catalyst.Text.tertiary(scheme))
                            }
                        }
                    }

                    Spacer()

                    // Action Controls
                    HStack(spacing: Catalyst.Spacing.space2) {
                        CatalystButton("Next", role: .default) {
                            artService.nextCuratedArtwork()
                        }
                        .disabled(artService.isLoading || artService.isAnalyzingVisuals)

                        CatalystButton(artService.isLoading ? "Discovering…" : "Discover Online Art", role: .default) {
                            Task { await artService.fetchRandomOnlineArtwork() }
                        }
                        .disabled(artService.isLoading || artService.isAnalyzingVisuals)

                        if let webURL = artService.currentArtwork.webURL {
                            Link(destination: webURL) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(Catalyst.Typography.callout)
                                    .foregroundColor(Catalyst.Text.secondary(scheme))
                            }
                            .buttonStyle(.plain)
                            .help("View archive record in museum collection")
                        }
                    }
                }

                // MARK: - Artwork Image Container
                if let effectiveURL = artService.currentArtwork.effectiveImageURL {
                    ZStack {
                        Rectangle()
                            .fill(Catalyst.Surface.overlay(scheme))
                            .frame(height: 300)

                        if effectiveURL.isFileURL, let nsImage = NSImage(contentsOf: effectiveURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 300)
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        } else {
                            AsyncImage(url: effectiveURL) { phase in
                                switch phase {
                                case .empty:
                                    VStack(spacing: Catalyst.Spacing.space2) {
                                        ProgressView()
                                            .scaleEffect(0.9)
                                        Text("Loading. . .")
                                            .font(Catalyst.Typography.caption1)
                                            .foregroundColor(Catalyst.Text.secondary(scheme))
                                    }
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 300)
                                        .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                                case .failure:
                                    VStack(spacing: Catalyst.Spacing.space2) {
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 28))
                                            .foregroundColor(Catalyst.warning.text(scheme))
                                        Text("Artwork preview unavailable")
                                            .font(Catalyst.Typography.caption1)
                                            .foregroundColor(Catalyst.Text.secondary(scheme))
                                    }
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .overlay(
                        Rectangle()
                            .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
                    )
                    .cornerRadius(Catalyst.Radius.default)
                }

                // MARK: - Error Banner (if API fetch failed)
                if let errorMsg = artService.errorMessage {
                    CatalystAlertBanner(.warning, message: errorMsg, closable: true) {
                        artService.errorMessage = nil
                    }
                }

                // MARK: - Speaking Prompts & Guided Steps
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                    Text("Describe this artwork in 45–90 seconds. Speak naturally:")
                        .font(Catalyst.Typography.body)
                        .fontWeight(.medium)
                        .foregroundColor(Catalyst.Text.primary(scheme))

                    // MARK: - Visual Scene Analysis (from Multimodal Foundation Model)
                    if let scene = artService.currentArtwork.visualSceneDescription, !scene.isEmpty {
                        HStack(alignment: .top, spacing: Catalyst.Spacing.space2) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                                .foregroundColor(accent.text(scheme))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                                Text("Visual Scene Highlights")
                                    .font(Catalyst.Typography.caption1)
                                    .fontWeight(.semibold)
                                    .foregroundColor(accent.text(scheme))

                                Text(scene)
                                    .font(Catalyst.Typography.callout)
                                    .foregroundColor(Catalyst.Text.secondary(scheme))
                            }
                        }
                        .padding(Catalyst.Spacing.space2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.subtle(scheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                                .stroke(accent.text(scheme).opacity(0.2), lineWidth: 1)
                        )
                        .cornerRadius(Catalyst.Radius.default)
                    }

                    // MARK: - 3-Stage Guided Questions
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
                        ForEach(Array(artService.currentArtwork.guidedPrompts.enumerated()), id: \.offset) { index, prompt in
                            HStack(alignment: .top, spacing: Catalyst.Spacing.space2) {
                                Text("\(index + 1).")
                                    .font(Catalyst.Typography.caption1)
                                    .fontWeight(.bold)
                                    .foregroundColor(accent.text(scheme))
                                    .frame(width: 16, alignment: .leading)

                                Text(prompt)
                                    .font(Catalyst.Typography.callout)
                                    .foregroundColor(Catalyst.Text.secondary(scheme))
                            }
                        }
                    }

                    // MARK: - Emotional & Descriptive Vocabulary Bank
                    if !artService.currentArtwork.suggestedFeelings.isEmpty {
                        VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                            Text("Inspiration vocabulary (emotions & atmosphere):")
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(Catalyst.Text.tertiary(scheme))

                            HStack(spacing: Catalyst.Spacing.space2) {
                                ForEach(artService.currentArtwork.suggestedFeelings, id: \.self) { feeling in
                                    CatalystBadge(feeling, variant: .slate)
                                }
                            }
                        }
                        .padding(.top, Catalyst.Spacing.space1)
                    }
                }
                .padding(Catalyst.Spacing.space3)
                .background(Catalyst.Surface.surface(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(Catalyst.Border.secondary(scheme), lineWidth: 1)
                )
                .cornerRadius(Catalyst.Radius.default)
            }
        }
    }
}
