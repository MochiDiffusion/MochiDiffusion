//
//  FilterTextFieldView.swift
//  Mochi Diffusion
//
//  Created by Hossein on 10/11/24.
//

import SwiftUI

struct FilterTextFieldView: View {
    @Binding var filters: [Filter]
    @State private var inputText: String = ""
    @State private var selectedFilter: Filter? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {

            Image(
                systemName: filters.isEmpty
                    ? "line.horizontal.3.decrease.circle" : "line.horizontal.3.decrease.circle.fill"
            )
            .foregroundColor(filters.isEmpty ? .gray : .accentColor)

            ForEach($filters) { $filter in
                FilterTagView(filter: $filter, isSelected: selectedFilter == filter)
                    .onTapGesture {
                        selectedFilter = filter
                    }
            }

            TextField(filters.isEmpty ? "Filter" : "", text: $inputText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    addFilter()
                }
                .onKeyPress(KeyEquivalent("\u{7F}")) {
                    guard inputText.isEmpty else { return .ignored }
                    guard let selectedFilter else {
                        selectedFilter = filters.last
                        return .handled
                    }
                    removeFilter(selectedFilter)
                    self.selectedFilter = nil
                    return .handled
                }

            if !filters.isEmpty {
                Button {
                    filters.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }

        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))
    }

    private func addFilter() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            let newTag = Filter(text: trimmedText)
            filters.append(newTag)
            inputText = ""
        }
    }

    private func removeFilter(_ filter: Filter) {
        if let index = filters.firstIndex(of: filter) {
            filters.remove(at: index)
        }
    }
}

#Preview {
    @State var filters = [Filter]()
    return FilterTextFieldView(filters: $filters)
}
