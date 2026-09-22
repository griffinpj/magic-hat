//
//  SearchDismisser.swift
//  magic-hat
//
//  `dismissSearch` only exists in the environment *inside* a searchable
//  modifier's content, so a view there relays it. Bump `trigger` and the
//  field collapses. With `endWhenKeyboardHidesAndEmpty`, swiping or
//  scrolling the keyboard away with nothing typed also ends the search
//  session — otherwise the field's X stays lit with no keyboard to close,
//  which reads as a button that stopped working.
//

import SwiftUI
import UIKit

struct SearchDismisser: View {
    var trigger: Int = 0
    /// True while the field's text is empty; read when the keyboard hides.
    var isEmpty: Bool = true
    var endWhenKeyboardHidesAndEmpty = true

    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Color.clear
            .onChange(of: trigger) { _, _ in dismissSearch() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                if endWhenKeyboardHidesAndEmpty, isSearching, isEmpty { dismissSearch() }
            }
    }
}
