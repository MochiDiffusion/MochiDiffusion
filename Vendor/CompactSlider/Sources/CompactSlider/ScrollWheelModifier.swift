// The MIT License (MIT)
//
// Copyright (c) 2024 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

#if canImport(AppKit)
    import AppKit
    import Combine

    struct ScrollWheelModifier: ViewModifier {
        let action: (_ delta: CGPoint) -> Void
        private var cancellable = Set<AnyCancellable>()

        init(action: @escaping (_ delta: CGPoint) -> Void) {
            self.action = action
            subscribeForScrollWheelEvents()
        }

        func body(content: Content) -> some View {
            content
        }

        mutating func subscribeForScrollWheelEvents() {
            NSApp.publisher(for: \.currentEvent)
                .filter { $0?.type == .scrollWheel }
                .compactMap {
                    if let event = $0 {
                        return CGPoint(x: event.deltaX, y: event.deltaY)
                    }

                    return nil
                }
                .removeDuplicates()
                .sink { [action] in action($0) }
                .store(in: &cancellable)
        }
    }

    extension View {
        @ViewBuilder
        func onScrollWheel(isEnabled: Bool = true, action: @escaping (_ delta: CGPoint) -> Void)
            -> some View
        {
            if isEnabled {
                modifier(ScrollWheelModifier(action: action))
            } else {
                self
            }
        }
    }
#else
    extension View {
        func onScrollWheel(isEnabled: Bool = false, action: @escaping (_ delta: CGPoint) -> Void)
            -> some View
        {
            self
        }
    }
#endif
