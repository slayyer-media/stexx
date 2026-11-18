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
                        LabeledContent("From") {
                            Stepper("\(Int(ageRange.lowerBound))", value: lowerAge, in: 18...Double(Int(ageRange.upperBound)))
                        }
                        LabeledContent("To") {
                            Stepper("\(Int(ageRange.upperBound))", value: upperAge, in: ageRange.lowerBound...99)
                        }
                    }
                }

                Section {
                    Toggle("Maximum distance", isOn: $limitsDistance)
                    if limitsDistance {
                        VStack(alignment: .leading) {
                            Text(StexxFormat.distance(maxDistanceKm * 1000))
                                .font(.headline)
                            Slider(value: $maxDistanceKm, in: 1...100, step: 1)
                        }
                    }
                }

                Section("Position") {
                    FlowLayout {
                        ForEach(Position.allCases) { position in
                            GlassChip(Text(position.title), isSelected: draft.positions.contains(position)) {
                                draft.positions.formSymmetricDifference([position])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Looking for") {
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
                }

                Section {
                    TextField("Add a tag, e.g. Physics", text: $tagText)
                        .textInputAutocapitalization(.words)
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
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Tags")
                }
            }
            .stexxBackground(intensity: 0.6)
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
