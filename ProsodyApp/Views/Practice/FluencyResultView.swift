import SwiftUI

struct FluencyResultView: View {
    let result: FluencyResult
    
    var body: some View {
        CatalystPanel {
            VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                HStack {
                    Text("Fluency")
                        .font(Catalyst.Typography.headline)
                    Spacer()
                    Text("\(result.overallScore)%")
                        .font(Catalyst.Typography.title2)
                        .foregroundColor(scoreColor)
                }
                
                Divider()
                
                // Metric summary row
                HStack(spacing: Catalyst.Spacing.space4) {
                    MetricBadge(label: "Rate", value: String(format: "%.1f wps", result.speechRate))
                    MetricBadge(label: "Phonation", value: String(format: "%.0f%%", result.phonationTimeRatio * 100))
                    MetricBadge(label: "Flow", value: String(format: "%.1f w/run", result.meanLengthOfRun))
                    MetricBadge(label: "Pauses", value: "\(result.pauseCount)")
                }

                // Disfluency indicator chips (if present)
                if result.fillerCount > 0 || result.repetitionCount > 0 || result.intraPhrasePauseRatio > 0.30 {
                    HStack(spacing: Catalyst.Spacing.space2) {
                        if result.fillerCount > 0 {
                            DisfluencyChip(
                                icon: "bubble.left.and.exclamationmark.bubble.right",
                                text: "\(result.fillerCount) filler\(result.fillerCount == 1 ? "" : "s")",
                                color: .orange
                            )
                        }
                        if result.repetitionCount > 0 {
                            DisfluencyChip(
                                icon: "repeat",
                                text: "\(result.repetitionCount) repetition\(result.repetitionCount == 1 ? "" : "s")",
                                color: .orange
                            )
                        }
                        if result.intraPhrasePauseRatio > 0.30 {
                            DisfluencyChip(
                                icon: "pause.circle",
                                text: String(format: "%.0f%% mid-phrase", result.intraPhrasePauseRatio * 100),
                                color: .yellow
                            )
                        }
                        Spacer()
                    }
                }
                
                // Feedback items
                ForEach(result.feedback) { item in
                    HStack(alignment: .top, spacing: Catalyst.Spacing.space2) {
                        Circle()
                            .fill(item.status.color)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading) {
                            Text("\(item.metric): \(item.value)")
                                .font(Catalyst.Typography.callout)
                                .bold()
                            Text(item.message)
                                .font(Catalyst.Typography.caption1)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var scoreColor: Color {
        result.overallScore > 70 ? .green :
        result.overallScore > 40 ? .orange : .red
    }
}

private struct MetricBadge: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Catalyst.Typography.callout)
                .bold()
            Text(label)
                .font(Catalyst.Typography.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DisfluencyChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(Catalyst.Typography.caption2)
                .bold()
        }
        .padding(.horizontal, Catalyst.Spacing.space2)
        .padding(.vertical, 3)
        .background(color.opacity(colorScheme == .dark ? 0.2 : 0.12))
        .foregroundColor(color)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(3)
    }
}

