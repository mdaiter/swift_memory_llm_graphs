import Foundation

struct CalendarEvent: Equatable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String?
}

protocol CalendarClient {
    func upcomingEvents(until: Date) async throws -> [CalendarEvent]
}

final class MockCalendarClient: CalendarClient {
    var events: [CalendarEvent]

    init(events: [CalendarEvent]) {
        self.events = events
    }

    func upcomingEvents(until: Date) async throws -> [CalendarEvent] {
        return events.filter { $0.startsAt <= until }
    }
}
