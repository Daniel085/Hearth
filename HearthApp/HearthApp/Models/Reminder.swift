//
//  Reminder.swift
//  Hearth
//
//  Model representing a contextual reminder
//

import Foundation

struct Reminder: Identifiable, Codable {
    let id: UUID
    var personID: UUID
    var type: ReminderType
    var message: String
    var createdDate: Date
    var priority: Priority
    var isDismissed: Bool

    init(
        id: UUID = UUID(),
        personID: UUID,
        type: ReminderType,
        message: String,
        createdDate: Date = Date(),
        priority: Priority = .medium,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.personID = personID
        self.type = type
        self.message = message
        self.createdDate = createdDate
        self.priority = priority
        self.isDismissed = isDismissed
    }
}

enum ReminderType: String, Codable {
    case birthday
    case timeBasedContact
    case locationBased
    case patternBased
}

enum Priority: String, Codable {
    case low
    case medium
    case high
}
