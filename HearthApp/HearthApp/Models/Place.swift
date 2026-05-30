//
//  Place.swift
//  Hearth
//
//  Model representing a meaningful place
//

import Foundation
import CoreLocation

struct Place: Identifiable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var visitCount: Int
    var lastVisitDate: Date?
    var associatedPeople: [UUID] // References to Person IDs

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        visitCount: Int = 0,
        lastVisitDate: Date? = nil,
        associatedPeople: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.visitCount = visitCount
        self.lastVisitDate = lastVisitDate
        self.associatedPeople = associatedPeople
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
