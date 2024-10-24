//
//  FilterTagView.swift
//  Mochi Diffusion
//
//  Created by Hossein on 10/12/24.
//

import SwiftUI

struct FilterTagView: View {
    @Binding var filter: Filter
    var isSelected: Bool
    @State private var isEditing: Bool = false
    @State private var isOptionsPopoverShown: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isEditing {
                editView
            } else {
                tagView
            }
        }
        .cornerRadius(4)
        .frame(height: 16)
        .popover(
            isPresented: $isOptionsPopoverShown,
            content: {
                popOverView
            })
    }

    private var tagView: some View {
        HStack(spacing: 1) {
            Button {
                isOptionsPopoverShown.toggle()
            } label: {
                HStack(spacing: 2) {
                    if filter.element != .prompt {
                        Text(filter.element.rawValue)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.down")
                }
                .font(.caption2)
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
                .background(isSelected ? Color.gray : Color.gray.opacity(0.5))
            }
            .buttonStyle(.plain)

            Text("\(filter.condition == .isEqual ? "" : "≠ ")\"\(filter.text)\"")
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
                .background(isSelected ? Color.gray : Color.gray.opacity(0.3))
        }
        .onTapGesture(
            count: 2,
            perform: {
                isEditing = true
            })
    }

    private var editView: some View {
        TextField(
            "", text: $filter.text,
            onCommit: {
                isEditing = false
            }
        )
        .focused($isFocused)
        .textFieldStyle(PlainTextFieldStyle())
        .fixedSize()
        .onAppear {
            isFocused = true
        }
    }

    private var popOverView: some View {
        List {
            ForEach(FilterElement.allCases, id: \.self) { element in
                filterOptionItem(element.rawValue, isSelected: filter.element == element)
                    .onTapGesture {
                        filter.element = element
                    }
            }

            Divider()

            ForEach(FilterType.allCases, id: \.self) { type in
                filterOptionItem(type.rawValue, isSelected: filter.type == type)
                    .onTapGesture {
                        filter.type = type
                    }
            }

            Divider()

            ForEach(FilterCondition.allCases, id: \.self) { condition in
                filterOptionItem(condition.rawValue, isSelected: filter.condition == condition)
                    .onTapGesture {
                        filter.condition = condition
                    }
            }
        }
    }

    private func filterOptionItem(_ text: String, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: isSelected ? "checkmark" : "")
                .frame(width: 12)

            Text(text)
        }
        .listRowSeparator(.hidden)
    }
}
