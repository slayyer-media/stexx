import SwiftUI

/// Stexx+ advanced filters. The server enforces the entitlement too; this
/// sheet is only reachable with Stexx+.
struct FilterSheet: View {
    @Binding var query: NearbyQuery
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NearbyQuery()
    @State private var limitsAge = false
    @State private var ageRange: ClosedRange<Double> = 18...99
    @State private var limitsDistance = false
    @State private var maxDistanceKm: Double = 25
    @State private var tagText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Age range", isOn: $limitsAge)
                    if limitsAge {
                        Text(verbatim: "\(Int(ageRange.lowerBound))–\(Int(ageRange.upperBound))")
                            .stexxTitleStyle(.title)
                            .monospacedDigit()
                            .accessibilityLabel(Text("Ages \(Int(ageRange.lowerBound)) to \(Int(ageRange.upperBound))"))
                        LabeledContent("From") {
                            Stepper("\(Int(ageRange.lowerBound))", value: lowerAge, in: 18...Double(Int(ageRange.upperBound)))
                                .accessibilityLabel("Minimum age")
                                .accessibilityValue(Text("\(Int(ageRange.lowerBound))"))
                        }
                        LabeledContent("To") {
                            Stepper("\(Int(ageRange.upperBound))", value: upperAge, in: ageRange.lowerBound...99)
                                .accessibilityLabel("Maximum age")
                                .accessibilityValue(Text("\(Int(ageRange.upperBound))"))
                        }
                    }
                } header: {
                    SectionLabel("Age")
                }
                .listRowBackground(Theme.ink1)

                Section {
                    Toggle("Maximum distance", isOn: $limitsDistance)
                    if limitsDistance {
                        VStack(alignment: .leading) {
                            Text(StexxFormat.distance(maxDistanceKm * 1000))
                                .stexxTitleStyle(.title)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            Slider(value: $maxDistanceKm, in: 1...100, step: 1)
                                .accessibilityLabel("Maximum distance")
                                .accessibilityValue(Text(StexxFormat.distance(maxDistanceKm * 1000)))
                        }
                    }
                } header: {
                    SectionLabel("Distance")
                }
                .listRowBackground(Theme.ink1)

                Section {
                    FlowLayout {
                        ForEach(Position.allCases) { position in
                            GlassChip(Text(position.title), isSelected: draft.positions.contains(position)) {
                                draft.positions.formSymmetricDifference([position])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionLabel("Position")
                }
                .listRowBackground(Theme.ink1)

                Section {
                    FlowLayout {
                        ForEach(LookingFor.allCases) { item in
                            GlassChip(
                                Text(item.title),
                                systemImage: item.systemImage,
                                isSelected: draft.lookingFor.contains(item)
                            ) {
                                draft.lookingFor.formSymmetricDifference([item])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionLabel("Looking for")
                }
                .listRowBackground(Theme.ink1)

                Section {
                    TextField("Add a tag, e.g. Physics", text: $tagText)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Add a tag")
                        .accessibilityHint("Type a tag and press Return. Up to 10.")
                        .onSubmit(addTag)
                    if !draft.tags.isEmpty {
                        FlowLayout {
                            ForEach(draft.tags, id: \.self) { tag in
                                Button {
                                    draft.tags.removeAll { $0 == tag }
                                } label: {
                                    TagChip(text: tag, systemImage: "xmark")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Remove tag \(tag)"))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    SectionLabel("Tags")
                }
                .listRowBackground(Theme.ink1)
            }
            .listRowSeparatorTint(Theme.line)
            .stexxBackground(intensity: 0.4)
            .tint(Theme.ice)
            .sensoryFeedback(.selection, trigger: draft.positions)
            .sensoryFeedback(.selection, trigger: draft.lookingFor)
            .sensoryFeedback(.selection, trigger: limitsAge)
            .sensoryFeedback(.selection, trigger: limitsDistance)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset", role: .destructive) {
                        query = NearbyQuery()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        apply()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: load)
    }

    private var lowerAge: Binding<Double> {
        Binding(
            get: { ageRange.lowerBound },
            set: { ageRange = $0...max($0, ageRange.upperBound) }
        )
    }

    private var upperAge: Binding<Double> {
        Binding(
            get: { ageRange.upperBound },
            set: { ageRange = min(ageRange.lowerBound, $0)...$0 }
        )
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !draft.tags.contains(tag), draft.tags.count < 10 else { return }
        draft.tags.append(tag)
        tagText = ""
    }

    private func load() {
        draft = query
        if let min = query.minAge, let max = query.maxAge {
            limitsAge = true
            ageRange = Double(min)...Double(max)
        }
        if let meters = query.maxDistanceMeters {
            limitsDistance = true
            maxDistanceKm = meters / 1000
        }
    }

    private func apply() {
        var result = draft
        result.minAge = limitsAge ? Int(ageRange.lowerBound) : nil
        result.maxAge = limitsAge ? Int(ageRange.upperBound) : nil
        result.maxDistanceMeters = limitsDistance ? maxDistanceKm * 1000 : nil
        query = result
    }
}

#Preview {
    @Previewable @State var query = NearbyQuery()
    Color.clear
        .sheet(isPresented: .constant(true)) {
            FilterSheet(query: $query)
        }
        .previewEnvironment(plus: true)
}
