//
//  NotificationService.swift
//  RoutineOrganizer
//
//  Local notifications for timed items. Requests permission, schedules a
//  reminder at the item's start time (or the chosen lead time before it), and
//  keeps things in sync as items are added, edited, completed, or deleted.
//  One-off items use a one-shot trigger; daily/weekly routines use repeating
//  calendar triggers. Times-per-week and undated items get no notification.
//

import Foundation
import UserNotifications

enum NotificationService {
    private static var center: UNUserNotificationCenter { .current() }
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }

    // MARK: - Authorization

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// What iOS currently thinks, for the one screen that has to say it out
    /// loud. Everything else here treats "not allowed" as "schedule nothing and
    /// move on" — which is right for a background sweep and wrong for settings,
    /// where silence looks identical to a working app that simply never nudges.
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private static func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Cancels any existing notifications for the item and schedules fresh ones.
    static func reschedule(for item: ScheduleItem) async {
        // Awaited rather than fire-and-forget: the sweep below must finish
        // before the new requests go in, or it deletes what we just added.
        await removePending(withPrefix: baseID(item))

        guard item.kind != .todo, let start = item.startTime else { return }
        guard await ensureAuthorized() else { return }

        let leadMinutes = item.reminderLeadMinutes ?? 0
        let content = makeContent(for: item, start: start, leadMinutes: leadMinutes)

        if let rule = item.recurrence {
            // A repeating trigger runs forever, so a routine that's been trimmed
            // or had days lifted out of it can't use one — it would keep firing
            // for occurrences that no longer exist. Those get one request per
            // remaining occurrence instead.
            if item.recurrenceEndDate != nil || !item.skippedDates.isEmpty {
                scheduleRemainingOccurrences(of: item, start: start, leadMinutes: leadMinutes, content: content)
                return
            }
            switch rule.frequency {
            case .daily:
                add(id: baseID(item), content: content,
                    components: timeComponents(start, minusMinutes: leadMinutes), repeats: true)
            case .weekly:
                for weekday in rule.weekdays {
                    var comps = timeComponents(start, minusMinutes: leadMinutes)
                    comps.weekday = weekday
                    add(id: "\(baseID(item))-wd\(weekday)", content: content, components: comps, repeats: true)
                }
            case .timesPerWeek:
                break // no fixed time to fire on
            }
        } else {
            guard let fireDate = calendar.date(byAdding: .minute, value: -leadMinutes, to: start),
                  fireDate > Date() else { return }
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            add(id: baseID(item), content: content, components: comps, repeats: false)
        }
    }

    static func cancel(for item: ScheduleItem) {
        var ids = [baseID(item)]
        if let rule = item.recurrence, rule.frequency == .weekly {
            ids += rule.weekdays.map { "\(baseID(item))-wd\($0)" }
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        // A trimmed routine holds one request per remaining occurrence, so its
        // ids can't be enumerated from the rule alone — sweep by prefix. Only a
        // String crosses into the task; the model object stays put.
        let prefix = baseID(item)
        Task { await removePending(withPrefix: prefix) }
    }

    /// Removes every pending request belonging to one item, whatever shape its
    /// schedule took.
    private static func removePending(withPrefix prefix: String) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// One-shot requests for each occurrence still ahead of a bounded routine.
    /// Capped because the system only holds 64 pending requests per app — the
    /// nearest ones are the ones worth having.
    private static func scheduleRemainingOccurrences(
        of item: ScheduleItem,
        start: Date,
        leadMinutes: Int,
        content: UNNotificationContent
    ) {
        let engine = ScheduleEngine(calendar: calendar)
        let now = Date()
        let horizon = item.recurrenceEndDate ?? calendar.date(byAdding: .day, value: 90, to: now) ?? now
        guard horizon >= calendar.startOfDay(for: now) else { return }

        let days = engine.occurrences(of: item, in: DateInterval(start: calendar.startOfDay(for: now), end: horizon))
        let timeOfDay = calendar.dateComponents([.hour, .minute], from: start)

        for day in days.prefix(24) {
            guard let slot = calendar.date(bySettingHour: timeOfDay.hour ?? 0, minute: timeOfDay.minute ?? 0, second: 0, of: day),
                  let fireDate = calendar.date(byAdding: .minute, value: -leadMinutes, to: slot),
                  fireDate > now else { continue }
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            add(id: "\(baseID(item))-d\(Int(day.timeIntervalSinceReferenceDate))", content: content, components: comps, repeats: false)
        }
    }

    // MARK: - Helpers

    private static func baseID(_ item: ScheduleItem) -> String { "item-\(item.id.uuidString)" }

    /// Title is the item, body is the timing — the way iOS's own reminders read,
    /// so a glance at the lock screen says what is happening before it says
    /// when. The countdown wording comes from `ReminderLead` rather than being
    /// built here, so the picker and the notification can't drift apart.
    ///
    /// Internal rather than private so the tests can assert the copy: this is
    /// text nobody sees until a notification actually fires, which is the worst
    /// possible place to keep an unverified string.
    static func makeContent(for item: ScheduleItem, start: Date, leadMinutes: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.title
        let timeText = start.formatted(date: .omitted, time: .shortened)
        content.body = "\(ReminderLead.countdownPhrase(leadMinutes)) · \(timeText)"
        content.sound = .default
        return content
    }

    /// The hour/minute of `date` shifted `minutes` earlier — used for repeating
    /// triggers where only the time-of-day matters.
    private static func timeComponents(_ date: Date, minusMinutes minutes: Int) -> DateComponents {
        let shifted = calendar.date(byAdding: .minute, value: -minutes, to: date) ?? date
        return calendar.dateComponents([.hour, .minute], from: shifted)
    }

    private static func add(id: String, content: UNNotificationContent, components: DateComponents, repeats: Bool) {
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }
}
