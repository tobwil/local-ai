import Contacts
import EventKit
import Foundation

/// Kalender, Erinnerungen, Kontakte (Apple-Frameworks) und Mail (Mail.app über JXA).
/// macOS fragt beim ersten Zugriff jeweils nach der Erlaubnis.
enum PIMTools {
    nonisolated(unsafe) static let store = EKEventStore()

    static func all() -> [AgentTool] {
        [
            AgentTool(name: "calendar_events",
                      description: "Listet Termine aus allen Kalendern, standardmäßig heute bis 7 Tage voraus; optional nach Text filtern.",
                      parameters: schema([("days_ahead", "integer", "Tage voraus (Standard 7)"), ("days_back", "integer", "Tage zurück (Standard 0)"),
                                          ("search", "string", "Nur Termine, deren Titel/Ort/Notiz das enthält")], required: []),
                      needsApproval: false, source: "Kalender") { args in
                try await requestAccess(.event)
                let cal = Calendar.current
                let start = cal.date(byAdding: .day, value: -(BuiltinTools.int(args["days_back"]) ?? 0), to: cal.startOfDay(for: Date()))!
                let end = cal.date(byAdding: .day, value: (BuiltinTools.int(args["days_ahead"]) ?? 7) + 1, to: cal.startOfDay(for: Date()))!
                let q = (args["search"] as? String)?.lowercased() ?? ""
                let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                    .filter { e in q.isEmpty || [e.title, e.location, e.notes].compactMap { $0?.lowercased() }.contains { $0.contains(q) } }
                    .sorted { $0.startDate < $1.startDate }
                guard !events.isEmpty else { return "Keine Termine im Zeitraum." }
                return events.prefix(200).map { e in
                    let when = e.isAllDay ? e.startDate.formatted(date: .abbreviated, time: .omitted) + " (ganztägig)"
                        : "\(e.startDate.formatted(date: .abbreviated, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
                    return "• \(when): \(e.title ?? "(ohne Titel)")" + (e.location.map { " @ \($0)" } ?? "") + " [\(e.calendar.title)]"
                }.joined(separator: "\n")
            },
            AgentTool(name: "calendar_create",
                      description: "Legt einen Termin an. Zeiten als ISO, z. B. 2026-10-27T14:00 (Ortszeit).",
                      parameters: schema([("title", "string", "Titel"), ("start", "string", "Beginn (ISO)"), ("end", "string", "Ende (ISO), sonst +60 min"),
                                          ("location", "string", "Ort"), ("notes", "string", "Notiz"),
                                          ("calendar", "string", "Kalendername, sonst Standardkalender")], required: ["title", "start"]),
                      needsApproval: true, source: "Kalender") { args in
                try await requestAccess(.event)
                guard let start = parseDate(try BuiltinTools.string(args, "start")) else { throw ToolError.invalid("Beginn nicht lesbar") }
                let event = EKEvent(eventStore: store)
                event.title = try BuiltinTools.string(args, "title")
                event.startDate = start
                event.endDate = (args["end"] as? String).flatMap(parseDate) ?? start.addingTimeInterval(3600)
                event.location = args["location"] as? String
                event.notes = args["notes"] as? String
                event.calendar = (args["calendar"] as? String).flatMap { name in
                    store.calendars(for: .event).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                } ?? store.defaultCalendarForNewEvents
                try store.save(event, span: .thisEvent)
                return "Termin angelegt: \(event.title ?? "") am \(start.formatted(date: .complete, time: .shortened)) [\(event.calendar.title)]"
            },
            AgentTool(name: "reminders_list",
                      description: "Listet offene Erinnerungen (optional aus einer bestimmten Liste).",
                      parameters: schema([("list", "string", "Name der Liste"), ("include_completed", "boolean", "Erledigte mitzeigen")], required: []),
                      needsApproval: false, source: "Erinnerungen") { args in
                try await requestAccess(.reminder)
                let lists = (args["list"] as? String).map { name in
                    store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveContains(name) }
                }
                let done = args["include_completed"] as? Bool ?? false
                let predicate = done ? store.predicateForReminders(in: lists)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
                let items: [EKReminder] = await withCheckedContinuation { c in
                    store.fetchReminders(matching: predicate) { c.resume(returning: $0 ?? []) }
                }
                guard !items.isEmpty else { return "Keine Erinnerungen." }
                return items.prefix(200).map { r in
                    let due = r.dueDateComponents?.date.map { " (fällig \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
                    return "\(r.isCompleted ? "✓" : "○") \(r.title ?? "")\(due) [\(r.calendar.title)]"
                }.joined(separator: "\n")
            },
            AgentTool(name: "reminders_create",
                      description: "Legt eine Erinnerung an, optional mit Fälligkeit (ISO, z. B. 2026-10-27T09:00).",
                      parameters: schema([("title", "string", "Titel"), ("due", "string", "Fällig am (ISO)"), ("notes", "string", "Notiz"),
                                          ("list", "string", "Liste, sonst Standardliste")], required: ["title"]),
                      needsApproval: true, source: "Erinnerungen") { args in
                try await requestAccess(.reminder)
                let r = EKReminder(eventStore: store)
                r.title = try BuiltinTools.string(args, "title")
                r.notes = args["notes"] as? String
                if let due = (args["due"] as? String).flatMap(parseDate) {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                r.calendar = (args["list"] as? String).flatMap { name in
                    store.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                } ?? store.defaultCalendarForNewReminders()
                try store.save(r, commit: true)
                return "Erinnerung angelegt: \(r.title ?? "") [\(r.calendar.title)]"
            },
            AgentTool(name: "contacts_search",
                      description: "Sucht Kontakte nach Name und liefert E-Mail-Adressen und Telefonnummern.",
                      parameters: schema([("query", "string", "Name oder Namensteil")], required: ["query"]),
                      needsApproval: false, source: "Kontakte") { args in
                let cs = CNContactStore()
                guard try await cs.requestAccess(for: .contacts) else { throw ToolError.invalid("Zugriff auf Kontakte nicht erlaubt") }
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                            CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
                let found = try cs.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: try BuiltinTools.string(args, "query")),
                                                   keysToFetch: keys)
                guard !found.isEmpty else { return "Keine Kontakte gefunden." }
                return found.prefix(30).map { c in
                    let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    let mails = c.emailAddresses.map { $0.value as String }.joined(separator: ", ")
                    let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                    return "• \(name.isEmpty ? c.organizationName : name)" + (mails.isEmpty ? "" : " · \(mails)") + (phones.isEmpty ? "" : " · \(phones)")
                }.joined(separator: "\n")
            },
            AgentTool(name: "mail_recent",
                      description: "Liest die neuesten E-Mails aus dem Posteingang von Mail.app (Absender, Betreff, Datum, Anfang des Textes).",
                      parameters: schema([("count", "integer", "Anzahl (Standard 10, max. 30)"), ("unread_only", "boolean", "Nur ungelesene")], required: []),
                      needsApproval: false, source: "Mail") { args in
                let n = min(max(BuiltinTools.int(args["count"]) ?? 10, 1), 30)
                let unread = args["unread_only"] as? Bool ?? false
                let script = """
                const Mail = Application('Mail');
                const msgs = Mail.inbox.messages;
                const total = msgs.length;
                const out = [];
                for (let i = 0; i < total && out.length < \(n); i++) {
                  const m = msgs[i];
                  if (\(unread) && m.readStatus()) continue;
                  let body = '';
                  try { body = m.content().replace(/\\s+/g, ' ').slice(0, 400); } catch (e) {}
                  out.push((m.readStatus() ? '  ' : '● ') + m.dateReceived().toLocaleString('de-DE') + ' · ' + m.sender() + '\\n  Betreff: ' + m.subject() + '\\n  ' + body);
                }
                out.join('\\n\\n') || 'Keine E-Mails.';
                """
                return try await jxa(script)
            },
            AgentTool(name: "mail_draft",
                      description: "Legt in Mail.app einen Entwurf an und öffnet ihn – der Nutzer prüft und sendet selbst.",
                      parameters: schema([("to", "string", "Empfänger, mehrere mit Komma"), ("subject", "string", "Betreff"),
                                          ("body", "string", "Text")], required: ["to", "subject", "body"]),
                      needsApproval: true, source: "Mail") { args in
                let to = try BuiltinTools.string(args, "to").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let script = """
                const Mail = Application('Mail');
                const msg = Mail.OutgoingMessage({subject: \(BrowserTools.jsString(try BuiltinTools.string(args, "subject"))),
                                                  content: \(BrowserTools.jsString(try BuiltinTools.string(args, "body"))), visible: true});
                Mail.outgoingMessages.push(msg);
                \(to.map { "msg.toRecipients.push(Mail.Recipient({address: \(BrowserTools.jsString($0))}));" }.joined(separator: "\n"))
                Mail.activate();
                'Entwurf geöffnet';
                """
                return try await jxa(script)
            },
        ]
    }

    private static func requestAccess(_ type: EKEntityType) async throws {
        let ok = type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        guard ok else {
            throw ToolError.invalid("Zugriff auf \(type == .event ? "Kalender" : "Erinnerungen") nicht erlaubt – Systemeinstellungen → Datenschutz & Sicherheit.")
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "dd.MM.yyyy HH:mm", "dd.MM.yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func jxa(_ script: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let (data, errData) = try await p.runAndRead(out, errors: err)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: errData, as: UTF8.self)
            if e.contains("-1743") { throw ToolError.invalid("macOS hat den Zugriff auf Mail verweigert – Datenschutz & Sicherheit → Automation.") }
            throw ToolError.invalid("Mail: \(e.suffix(300))")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
