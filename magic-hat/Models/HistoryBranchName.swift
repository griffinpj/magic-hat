//
//  HistoryBranchName.swift
//  magic-hat
//
//  A name the user gave a branch of the history ("Before the trade"),
//  kept on the action at the branch's tip when it was named. A line's
//  name is the one set nearest its tip (HistoryLog), so the name stays
//  with the work it was given to: actions added on top keep it, and it
//  follows the branch when a later fork makes it the one not taken. A
//  small table, user-managed, so it lives with the user's data rather
//  than in UserDefaults.
//

import Foundation
import SwiftData

@Model
nonisolated final class HistoryBranchName {
    @Attribute(.unique) var actionID: UUID
    var name: String

    init(actionID: UUID, name: String) {
        self.actionID = actionID
        self.name = name
    }
}
