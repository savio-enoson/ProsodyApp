import SwiftUI

struct ScoringResultView: View {
    let result: ScoringResult
    @State private var selectedWord: WordFeedbackItem?
    @State private var selectedPairId: UUID?
    @State private var selectedPhoneId: UUID?
    
    var body: some View {
        VStack(alignment: .leading, spacing: Catalyst.Spacing.space4) {
            Text("Pronunciation Score: \(result.overallScore)%")
                .font(Catalyst.Typography.headline)
                .padding(.bottom, Catalyst.Spacing.space2)
            
            // Word chips
            CatalystPanel {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Catalyst.Spacing.space2) {
                        ForEach(result.feedbackItems) { item in
                            Text(item.word)
                                .font(Catalyst.Typography.body)
                                .padding(.horizontal, Catalyst.Spacing.space2)
                                .padding(.vertical, Catalyst.Spacing.space1)
                                .background(item.status.color.opacity(0.2))
                                .foregroundColor(item.status.color)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(selectedWord?.id == item.id ? item.status.color : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    withAnimation(Catalyst.Animation.fast) {
                                        if selectedWord?.id == item.id {
                                            selectedWord = nil
                                            selectedPairId = nil
                                            selectedPhoneId = nil
                                        } else {
                                            selectedWord = item
                                            // Pre-select first error phoneme, if any
                                            if let firstErr = item.alignedPhonemes.first(where: { $0.status != .good }) {
                                                selectedPairId = firstErr.id
                                            } else {
                                                selectedPairId = item.alignedPhonemes.first?.id
                                            }
                                            selectedPhoneId = item.phonemes.first(where: { $0.status != .good })?.id ?? item.phonemes.first?.id
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Detailed Phoneme Breakdown
            if let selected = selectedWord {
                CatalystPanel {
                    VStack(alignment: .leading, spacing: Catalyst.Spacing.space3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Phonemes for '\(selected.word)'")
                                .font(Catalyst.Typography.callout)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(selected.overallScore)%")
                                .font(Catalyst.Typography.subheadline)
                                .foregroundColor(selected.status.color)
                            Button {
                                withAnimation(Catalyst.Animation.fast) {
                                    selectedWord = nil
                                    selectedPairId = nil
                                    selectedPhoneId = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, Catalyst.Spacing.space2)
                        }
                        
                        if !selected.expectedIpa.isEmpty || !selected.heardIpa.isEmpty {
                            HStack(spacing: Catalyst.Spacing.space3) {
                                if !selected.expectedIpa.isEmpty {
                                    Text("Expected: \(selected.expectedIpa)")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(.secondary)
                                }
                                if !selected.heardIpa.isEmpty {
                                    Text("Heard: \(selected.heardIpa)")
                                        .font(Catalyst.Typography.caption1)
                                        .foregroundColor(selected.status.color)
                                }
                            }
                        }
                        
                        // Phoneme sequence strip (selectable chips)
                        if !selected.alignedPhonemes.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Catalyst.Spacing.space2) {
                                    ForEach(selected.alignedPhonemes) { pair in
                                        let isSelected = (selectedPairId == pair.id)
                                        VStack(spacing: 3) {
                                            // Expected Phoneme
                                            Text(pair.expected != nil ? "/\(pair.expected!)/" : "—")
                                                .font(Catalyst.Typography.caption1)
                                                .foregroundColor(.secondary)
                                            
                                            // Heard Phoneme
                                            Text(pair.heard != nil ? "[\(pair.heard!)]" : "—")
                                                .font(Catalyst.Typography.headline)
                                                .foregroundColor(pair.status.color)
                                            
                                            // Metric or Diagnostic Badge
                                            if pair.expected != nil {
                                                Text("\(pair.score)%")
                                                    .font(Catalyst.Typography.caption2)
                                                    .foregroundColor(pair.status.color)
                                            } else if case .insertion = pair.errorType {
                                                Text("Added")
                                                    .font(Catalyst.Typography.caption2)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                        .padding(.horizontal, Catalyst.Spacing.space2)
                                        .padding(.vertical, Catalyst.Spacing.space1)
                                        .background(pair.status.color.opacity(isSelected ? 0.25 : 0.12))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(isSelected ? pair.status.color : pair.status.color.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            withAnimation(Catalyst.Animation.fast) {
                                                selectedPairId = pair.id
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            
                            // Human-Readable Guide Card for Selected Aligned Pair
                            if let activePair = selected.alignedPhonemes.first(where: { $0.id == selectedPairId }) ?? selected.alignedPhonemes.first {
                                soundGuideCard(for: activePair, in: selected.word)
                            }
                        } else {
                            // Fallback for unaligned phonemes list
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Catalyst.Spacing.space2) {
                                    ForEach(selected.phonemes) { phone in
                                        let isSelected = (selectedPhoneId == phone.id)
                                        VStack {
                                            Text(phone.symbol)
                                                .font(Catalyst.Typography.headline)
                                            Text("\(phone.score)%")
                                                .font(Catalyst.Typography.caption1)
                                        }
                                        .padding(Catalyst.Spacing.space2)
                                        .background(phone.status.color.opacity(isSelected ? 0.3 : 0.15))
                                        .foregroundColor(phone.status.color)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(isSelected ? phone.status.color : Color.clear, lineWidth: 2)
                                        )
                                        .onTapGesture {
                                            withAnimation(Catalyst.Animation.fast) {
                                                selectedPhoneId = phone.id
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            
                            if let activePhone = selected.phonemes.first(where: { $0.id == selectedPhoneId }) ?? selected.phonemes.first {
                                unalignedSoundGuideCard(for: activePhone, in: selected.word)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sound Guide Card (Aligned Pair)

    @ViewBuilder
    private func soundGuideCard(for pair: AlignedPhonemePair, in word: String) -> some View {
        let targetSound = pair.expected ?? pair.heard ?? ""
        let soundInfo = PhonemeLexicon.shared.lookup(phoneme: targetSound)
        let friendly = soundInfo?.friendlyName ?? PhonemeDisplayHelper.friendlyName(for: targetSound)
        let anchor = soundInfo?.anchorWord ?? ""
        let tip = soundInfo?.articulationTip ?? PhonemeDisplayHelper.articulationTip(for: targetSound)
        let errorDesc = PhonemeDisplayHelper.errorDescription(for: pair, in: word)
        let practiceWords = soundInfo?.allPracticeWords.prefix(5) ?? []
        let minimalPairs = soundInfo?.minimalPairs.prefix(2) ?? []

        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
            Divider().padding(.vertical, Catalyst.Spacing.space1)

            // Header: Friendly Sound Label + Anchor Word
            HStack(spacing: Catalyst.Spacing.space2) {
                Text(friendly)
                    .font(Catalyst.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                if !anchor.isEmpty {
                    Text("— as in \"\(anchor)\"")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                }

                Spacer()

                CatalystBadge(
                    pair.status == .good ? "Accurate" : pair.status == .needsWork ? "Needs Work" : "Review",
                    variant: pair.status == .good ? .success : pair.status == .needsWork ? .warning : .danger
                )
            }

            // Plain-English Explanation
            Text(errorDesc)
                .font(Catalyst.Typography.body)
                .foregroundColor(.primary)

            // Articulatory Mouth/Tongue Tip
            HStack(alignment: .top, spacing: Catalyst.Spacing.space2) {
                Image(systemName: "mouth")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                Text(tip)
                    .font(Catalyst.Typography.caption1)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, Catalyst.Spacing.space1)

            // Practice Words Chips
            if !practiceWords.isEmpty {
                VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
                    Text("Practice words with this sound:")
                        .font(Catalyst.Typography.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: Catalyst.Spacing.space1) {
                        ForEach(Array(practiceWords), id: \.self) { pWord in
                            Text(pWord)
                                .font(Catalyst.Typography.caption1)
                                .padding(.horizontal, Catalyst.Spacing.space2)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(Catalyst.Radius.sm)
                        }
                    }
                }
            }

            // Minimal-Pair Contrast Drills (if available)
            if !minimalPairs.isEmpty && pair.status != .good {
                HStack(spacing: Catalyst.Spacing.space2) {
                    Text("Minimal pair drill:")
                        .font(Catalyst.Typography.caption2)
                        .foregroundColor(.secondary)

                    ForEach(Array(minimalPairs)) { mp in
                        Text("\(mp.targetWord) vs. \(mp.contrastWord)")
                            .font(Catalyst.Typography.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, Catalyst.Spacing.space2)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(Color.accentColor)
                            .cornerRadius(Catalyst.Radius.sm)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Catalyst.Spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                .fill(Color.secondary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Sound Guide Card (Unaligned Fallback)

    @ViewBuilder
    private func unalignedSoundGuideCard(for phone: PhonemeFeedback, in word: String) -> some View {
        let soundInfo = PhonemeLexicon.shared.lookup(phoneme: phone.symbol)
        let friendly = soundInfo?.friendlyName ?? PhonemeDisplayHelper.friendlyName(for: phone.symbol)
        let anchor = soundInfo?.anchorWord ?? ""
        let tip = soundInfo?.articulationTip ?? PhonemeDisplayHelper.articulationTip(for: phone.symbol)
        let errorDesc = PhonemeDisplayHelper.errorDescription(for: phone, in: word)
        let practiceWords = soundInfo?.allPracticeWords.prefix(5) ?? []

        VStack(alignment: .leading, spacing: Catalyst.Spacing.space2) {
            Divider().padding(.vertical, Catalyst.Spacing.space1)

            HStack(spacing: Catalyst.Spacing.space2) {
                Text(friendly)
                    .font(Catalyst.Typography.callout)
                    .fontWeight(.semibold)

                if !anchor.isEmpty {
                    Text("— as in \"\(anchor)\"")
                        .font(Catalyst.Typography.caption1)
                        .foregroundColor(.secondary)
                }
                Spacer()
                CatalystBadge(
                    phone.status == .good ? "Accurate" : phone.status == .needsWork ? "Needs Work" : "Review",
                    variant: phone.status == .good ? .success : phone.status == .needsWork ? .warning : .danger
                )
            }

            Text(errorDesc)
                .font(Catalyst.Typography.body)

            HStack(alignment: .top, spacing: Catalyst.Spacing.space2) {
                Image(systemName: "mouth")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                Text(tip)
                    .font(Catalyst.Typography.caption1)
                    .foregroundColor(.secondary)
            }

            if !practiceWords.isEmpty {
                HStack(spacing: Catalyst.Spacing.space1) {
                    ForEach(Array(practiceWords), id: \.self) { pWord in
                        Text(pWord)
                            .font(Catalyst.Typography.caption1)
                            .padding(.horizontal, Catalyst.Spacing.space2)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(Catalyst.Radius.sm)
                    }
                }
            }
        }
        .padding(Catalyst.Spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                .fill(Color.secondary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }
}
