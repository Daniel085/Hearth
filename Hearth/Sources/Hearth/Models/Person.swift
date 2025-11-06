//
//  Person.swift
//  Hearth
//
//  Model representing a person in the user's network
//

import Foundation

struct Person: Identifiable, Codable {
    let id: UUID
    var name: String
    var photoIdentifier: String? // Reference to photo library
    var lastContactDate: Date?
    var contactFrequency: ContactFrequency?
    var birthday: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        photoIdentifier: String? = nil,
        lastContactDate: Date? = nil,
        contactFrequency: ContactFrequency? = nil,
        birthday: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.photoIdentifier = photoIdentifier
        self.lastContactDate = lastContactDate
        self.contactFrequency = contactFrequency
        self.birthday = birthday
        self.notes = notes
    }
}

enum ContactFrequency: String, Codable {
    case daily
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly
}
