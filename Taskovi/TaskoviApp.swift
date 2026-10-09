import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers
import ServiceManagement

// Menu bar icon, drawn in code so it stays sharp on every screen:
// a rounded frame with a round check in the middle (22 x 18 pt).
func makeMenuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Rounded frame
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 18.5, height: 12.5),
                                 xRadius: 2.75, yRadius: 2.75)
        frame.lineWidth = 1.5
        frame.stroke()

        // Filled circle
        NSBezierPath(ovalIn: NSRect(x: 6.75, y: 4.75, width: 8.5, height: 8.5)).fill()

        // Checkmark cut out of the circle
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 9, y: 9.1))
        check.line(to: NSPoint(x: 10.5, y: 10.6))
        check.line(to: NSPoint(x: 13.1, y: 7.65))
        check.lineWidth = 1.2
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        check.stroke()
        return true
    }
    image.isTemplate = true   // macOS colors it for light/dark menu bar
    return image
}

// Menu bar icon while a timer is running: the same frame with a clock inside.
// step 0–11 = position of the clock hand (30° per step), used for the animation.
func makeMenuBarTimerIcon(step: Int = 0) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 18.5, height: 12.5),
                                 xRadius: 2.75, yRadius: 2.75)
        frame.lineWidth = 1.5
        frame.stroke()

        NSBezierPath(ovalIn: NSRect(x: 6.75, y: 4.75, width: 8.5, height: 8.5)).fill()

        // Clock hand cut out of the circle
        let angle = Double(step) * .pi / 6
        let hand = NSBezierPath()
        hand.move(to: NSPoint(x: 11, y: 9))
        hand.line(to: NSPoint(x: 11 + 2.7 * sin(angle), y: 9 - 2.7 * cos(angle)))
        hand.lineWidth = 1.2
        hand.lineCapStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        hand.stroke()
        NSBezierPath(ovalIn: NSRect(x: 10.1, y: 8.1, width: 1.8, height: 1.8)).fill()
        return true
    }
    image.isTemplate = true
    return image
}

// Monday of the week that contains this date
func startOfWeek(_ date: Date) -> Date {
    var cal = Calendar.current
    cal.firstWeekday = 2   // Monday
    return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
}

func startOfMonth(_ date: Date) -> Date {
    Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
}

// MARK: - Data

enum TaskStatus: String, Codable, CaseIterable {
    case todo, inProgress, done

    var title: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .todo: return .gray
        case .inProgress: return .orange
        case .done: return .green
        }
    }
}

// The parts of a task, in order:
// Body → Fix body 1, 2… → (approved) → Hooks → Fix hooks 1, 2… → (approved) → Done
enum StageKind: String, Codable {
    case body, bodyFix, hooks, hooksFix

    var isBodyPart: Bool { self == .body || self == .bodyFix }
}

enum StageState: String, Codable {
    case working    // being worked on
    case sent       // sent for review, waiting for an answer
    case revision   // review came back with a revision (a fix part follows)
    case approved   // review approved it
}

struct TaskStage: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: StageKind
    var number: Int = 0          // which fix: 1, 2, …  (0 for Body and Hooks)
    var state: StageState = .working
    var sentAt: Date? = nil

    var title: String {
        switch kind {
        case .body: return "Body"
        case .bodyFix: return "Fix body \(number)"
        case .hooks: return "Hooks"
        case .hooksFix: return "Fix hooks \(number)"
        }
    }
}

struct TaskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var client: String
    var day: Date
    var status: TaskStatus = .todo
    var reminder: Date? = nil
    var timeSpent: TimeInterval? = nil   // saved work time (seconds)
    var startedAt: Date? = nil           // set while the timer is running
    var sessions: [WorkSession]? = nil   // every start–stop period, for Reports
    var stages: [TaskStage]? = nil       // Body, fixes, Hooks… (the last one is the current part)

    var isRunning: Bool { startedAt != nil }

    var currentStage: TaskStage? { stages?.last }

    // Sent for review and waiting for an answer: finished for now, not counted as open
    var isAwaitingReview: Bool { status != .done && currentStage?.state == .sent }

    // Still to be worked on (counted in the menu bar, can be overdue)
    var isOpen: Bool { status != .done && !isAwaitingReview }

    // Tasks saved before parts existed start with a Body part
    mutating func ensureStages() {
        guard stages?.isEmpty ?? true else { return }
        stages = [TaskStage(kind: .body, state: status == .done ? .approved : .working)]
    }

    // The part that starts when a review comes back with a revision
    func revisionStage() -> TaskStage? {
        guard let last = currentStage else { return nil }
        let kind: StageKind = last.kind.isBodyPart ? .bodyFix : .hooksFix
        let number = (stages ?? []).filter { $0.kind == kind }.count + 1
        return TaskStage(kind: kind, number: number)
    }

    // The part that starts when a review is approved (none after the hooks: the task is done)
    func approvalStage() -> TaskStage? {
        guard let last = currentStage, last.kind.isBodyPart else { return nil }
        return TaskStage(kind: .hooks)
    }

    // Where the task is now: "Body", "Fix body 1 sent", "Done"…
    var progressTitle: String {
        if status == .done { return "Done" }
        guard let stage = currentStage else { return status.title }
        return stage.state == .sent ? "\(stage.title) sent" : stage.title
    }

    var progressIcon: String {
        if status == .done { return "checkmark.circle.fill" }
        if isAwaitingReview { return "paperplane.circle.fill" }
        return isRunning || elapsed() > 0 ? "circle.lefthalf.filled" : "circle"
    }

    var progressColor: Color {
        if status == .done { return .green }
        if isAwaitingReview { return .blue }
        return isRunning || elapsed() > 0 ? .orange : .gray
    }

    // The part a work session belongs to (time from before parts existed counts as the first part)
    private func stageID(of session: WorkSession) -> UUID? {
        session.stageID ?? stages?.first?.id
    }

    func stageTitle(of session: WorkSession) -> String {
        let id = stageID(of: session)
        return stages?.first { $0.id == id }?.title ?? ""
    }

    // Total time worked on one part
    func time(of stage: TaskStage, now: Date = Date()) -> TimeInterval {
        let list = sessions ?? []
        var total = list.filter { stageID(of: $0) == stage.id }.reduce(0) { $0 + $1.duration }
        if let start = startedAt, stage.id == currentStage?.id { total += now.timeIntervalSince(start) }
        if stage.id == stages?.first?.id {
            let untracked = (timeSpent ?? 0) - list.reduce(0) { $0 + $1.duration }
            if untracked > 1 { total += untracked }
        }
        return total
    }

    // Time worked on each part on one calendar day, in order: [(part, seconds)]
    func stageTimes(on day: Date, now: Date = Date()) -> [(stage: TaskStage, seconds: TimeInterval)] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        func overlap(_ s: Date, _ e: Date) -> TimeInterval {
            max(0, min(e, dayEnd).timeIntervalSince(max(s, dayStart)))
        }
        let list = sessions ?? []
        var perStage: [UUID: TimeInterval] = [:]
        for session in list {
            if let id = stageID(of: session) { perStage[id, default: 0] += overlap(session.start, session.end) }
        }
        if let start = startedAt, let id = currentStage?.id { perStage[id, default: 0] += overlap(start, now) }
        let untracked = (timeSpent ?? 0) - list.reduce(0) { $0 + $1.duration }
        if untracked > 1 && cal.isDate(self.day, inSameDayAs: dayStart), let id = stages?.first?.id {
            perStage[id, default: 0] += untracked
        }
        return (stages ?? []).compactMap { stage -> (stage: TaskStage, seconds: TimeInterval)? in
            let t = perStage[stage.id] ?? 0
            guard t >= 1 else { return nil }
            return (stage: stage, seconds: t)
        }
    }
    var totalSeconds: TimeInterval { elapsed() }   // used for sorting in Reports

    // Total time worked, including the currently running part
    func elapsed(at now: Date = Date()) -> TimeInterval {
        (timeSpent ?? 0) + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    // Time worked on this task, per calendar day: [day: seconds]
    func timePerDay(now: Date = Date()) -> [Date: TimeInterval] {
        let cal = Calendar.current
        var result: [Date: TimeInterval] = [:]
        func add(_ start: Date, _ end: Date) {
            var s = start
            while s < end {
                let dayStart = cal.startOfDay(for: s)
                let next = cal.date(byAdding: .day, value: 1, to: dayStart) ?? end
                let e = min(end, next)
                result[dayStart, default: 0] += e.timeIntervalSince(s)
                s = e
            }
        }
        let list = sessions ?? []
        for session in list { add(session.start, session.end) }
        if let start = startedAt { add(start, now) }
        let untracked = (timeSpent ?? 0) - list.reduce(0) { $0 + $1.duration }
        if untracked > 1 { result[cal.startOfDay(for: day), default: 0] += untracked }
        return result
    }

    // Time worked on this task on one calendar day only
    func time(on day: Date, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        func overlap(_ s: Date, _ e: Date) -> TimeInterval {
            max(0, min(e, dayEnd).timeIntervalSince(max(s, dayStart)))
        }
        let list = sessions ?? []
        var total = list.reduce(0) { $0 + overlap($1.start, $1.end) }
        if let start = startedAt { total += overlap(start, now) }
        // Time tracked before session history existed counts on the task's own day
        let untracked = (timeSpent ?? 0) - list.reduce(0) { $0 + $1.duration }
        if untracked > 1 && cal.isDate(self.day, inSameDayAs: dayStart) { total += untracked }
        return total
    }
}

struct WorkSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var stageID: UUID? = nil   // the part of the task this time was spent on
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

// "1h 23m", "12m", "<1m"
func formatDuration(_ t: TimeInterval) -> String {
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
}

// "0:12:34" for a running timer
func formatClock(_ t: TimeInterval) -> String {
    let total = Int(t)
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

struct Client: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var templates: [String] = []   // tasks you regularly do for this client
}

final class TaskStore: ObservableObject {
    @Published var tasks: [TaskItem] = [] {
        didSet { save(tasks, key: tasksKey) }
    }
    @Published var clients: [Client] = [] {
        didSet { save(clients, key: clientsKey) }
    }

    private let tasksKey = "tasks.v1"
    private let clientsKey = "clients.v1"

    // The one store used by the whole app
    @MainActor static let shared = TaskStore()

    init() {
        load()

        // Pause the running timer when the Mac sleeps, shuts down, or the app quits
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge3(
            workspace.publisher(for: NSWorkspace.willSleepNotification),
            workspace.publisher(for: NSWorkspace.willPowerOffNotification),
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        )
        .sink { [weak self] _ in self?.pauseAll() }
        .store(in: &cancellables)

        // Keep "today" current after midnight, waking from sleep, or a clock change,
        // so the open-task count in the menu bar moves to the new day on its own
        Publishers.Merge3(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            workspace.publisher(for: NSWorkspace.didWakeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshToday() }
        .store(in: &cancellables)
    }

    @Published private(set) var today = Calendar.current.startOfDay(for: Date())

    private func refreshToday() {
        let now = Calendar.current.startOfDay(for: Date())
        if now != today { today = now }
    }

    // Reads the saved data again (used after another copy of the app quits and saves)
    func reload() {
        load()
    }

    private func load() {
        let defaults = UserDefaults.standard
        let stamp = Int(Date().timeIntervalSince1970)

        if let data = defaults.data(forKey: tasksKey) {
            if let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) {
                // Each task exists only once
                var seen = Set<UUID>()
                tasks = decoded
                    .filter { seen.insert($0.id).inserted }
                    .map { task in
                        var t = task
                        t.ensureStages()
                        return t
                    }
            } else {
                // Never lose data: keep an untouched copy if it can't be read
                defaults.set(data, forKey: "\(tasksKey).unreadable-\(stamp)")
            }
        }

        var loadedClients = false
        if let data = defaults.data(forKey: clientsKey) {
            if let decoded = try? JSONDecoder().decode([Client].self, from: data) {
                clients = decoded
                loadedClients = true
            } else {
                defaults.set(data, forKey: "\(clientsKey).unreadable-\(stamp)")
            }
        }
        if !loadedClients {
            // Client names already used in tasks become the client list
            let names = Set(tasks.map(\.client).filter { !$0.isEmpty })
            clients = names.sorted().map { Client(name: $0) }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    func pauseAll() {
        for i in tasks.indices where tasks[i].isRunning {
            stopTimer(at: i)
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: Tasks

    func tasks(for day: Date) -> [TaskItem] {
        tasks
            .filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
            .sorted {
                ($0.isOpen ? 0 : 1, $0.client.lowercased(), $0.title.lowercased()) <
                ($1.isOpen ? 0 : 1, $1.client.lowercased(), $1.title.lowercased())
            }
    }

    func overdue(before day: Date) -> [TaskItem] {
        tasks.filter { $0.day < day && $0.isOpen }
    }

    // Number of open tasks for today (plus overdue ones), shown in the menu bar.
    // Tasks sent for review don't count until a revision or approval comes back.
    var openTodayCount: Int {
        let todayOpen = tasks(for: today).filter(\.isOpen).count
        return todayOpen + overdue(before: today).count
    }

    func add(title: String, client: String, day: Date, reminder: Date?) {
        var task = TaskItem(title: title, client: client, day: day, reminder: reminder)
        task.ensureStages()
        tasks.append(task)
        schedule(task)
    }

    private func index(of task: TaskItem) -> Int? {
        tasks.firstIndex { $0.id == task.id }
    }

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    // To Do until time is tracked, then In Progress (Done is set only when the task is finished)
    private func updateStatus(at i: Int) {
        guard tasks[i].status != .done else { return }
        tasks[i].status = tasks[i].isRunning || tasks[i].elapsed() > 0 ? .inProgress : .todo
    }

    // MARK: Parts (Body → fixes → Hooks → fixes → Done)

    // Tasks sent for review and still waiting for an answer, oldest first
    func awaitingReview(excluding shown: Set<UUID>) -> [TaskItem] {
        tasks
            .filter { $0.isAwaitingReview && !shown.contains($0.id) }
            .sorted { ($0.currentStage?.sentAt ?? $0.day) < ($1.currentStage?.sentAt ?? $1.day) }
    }

    // Finish the current part and send it for review. It counts as finished for today.
    func sendForReview(_ task: TaskItem) {
        guard let i = index(of: task), tasks[i].isOpen,
              var stages = tasks[i].stages, !stages.isEmpty else { return }
        stopTimer(at: i)
        stages[stages.count - 1].state = .sent
        stages[stages.count - 1].sentAt = Date()
        tasks[i].stages = stages
        setDay(at: i, to: todayStart)
        updateStatus(at: i)
        schedule(tasks[i])
    }

    // The review came back with a revision: the next fix starts today, with its own timer running
    func markRevision(_ task: TaskItem) {
        guard let i = index(of: task), tasks[i].isAwaitingReview,
              var stages = tasks[i].stages, let next = tasks[i].revisionStage() else { return }
        stages[stages.count - 1].state = .revision
        stages.append(next)
        tasks[i].stages = stages
        setDay(at: i, to: todayStart)
        startTimer(at: i)
        updateStatus(at: i)
        schedule(tasks[i])
    }

    // The review approved it: after the body, Hooks start today (timer running);
    // after the hooks, the task is done
    func markApproved(_ task: TaskItem) {
        guard let i = index(of: task), tasks[i].isAwaitingReview,
              var stages = tasks[i].stages else { return }
        let next = tasks[i].approvalStage()
        stages[stages.count - 1].state = .approved
        if let next {
            stages.append(next)
            tasks[i].stages = stages
            setDay(at: i, to: todayStart)
            startTimer(at: i)
        } else {
            tasks[i].stages = stages
            tasks[i].status = .done
        }
        updateStatus(at: i)
        schedule(tasks[i])
    }

    // Finish the whole task at once, whatever part it is in
    func markDone(_ task: TaskItem) {
        guard let i = index(of: task), tasks[i].status != .done else { return }
        stopTimer(at: i)
        if var stages = tasks[i].stages, !stages.isEmpty {
            stages[stages.count - 1].state = .approved
            tasks[i].stages = stages
        }
        tasks[i].status = .done
        schedule(tasks[i])
    }

    // A part started by mistake can be removed while it has less than this much time
    private static let undoLimit: TimeInterval = 5 * 60

    // Name of the step that can be undone, or nil
    func undoStepTitle(_ task: TaskItem) -> String? {
        guard let stages = task.stages, let last = stages.last else { return nil }
        if task.status == .done { return "Reopen Task" }
        if last.state == .sent { return "Undo Send" }
        if stages.count > 1 && task.time(of: last) < Self.undoLimit {
            return stages[stages.count - 2].state == .revision ? "Undo Revision" : "Undo Approval"
        }
        return nil
    }

    // Undo a misclick: reopen a done task, take back a send, or remove a part that was just started
    func undoStep(_ task: TaskItem) {
        guard let i = index(of: task), undoStepTitle(tasks[i]) != nil,
              var stages = tasks[i].stages else { return }
        if tasks[i].status == .done {
            tasks[i].status = .inProgress
            stages[stages.count - 1].state = .sent
        } else if stages[stages.count - 1].state == .sent {
            stages[stages.count - 1].state = .working
            stages[stages.count - 1].sentAt = nil
        } else {
            // Remove the part and the few minutes tracked on it; the previous part waits for review again
            stopTimer(at: i)
            let removed = stages.removeLast()
            let sessions = tasks[i].sessions ?? []
            let removedTime = sessions.filter { $0.stageID == removed.id }.reduce(0) { $0 + $1.duration }
            tasks[i].sessions = sessions.filter { $0.stageID != removed.id }
            tasks[i].timeSpent = max(0, (tasks[i].timeSpent ?? 0) - removedTime)
            stages[stages.count - 1].state = .sent
        }
        tasks[i].stages = stages
        updateStatus(at: i)
        schedule(tasks[i])
    }

    // MARK: Backup

    struct Backup: Codable {
        var version: Int
        var exportedAt: Date
        var tasks: [TaskItem]
        var clients: [Client]
    }

    func exportBackup() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Taskovi Backup \(day).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let backup = Backup(version: 1, exportedAt: Date(), tasks: tasks, clients: clients)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(backup).write(to: url, options: .atomic)
            showAlert("Backup saved",
                      "\(tasks.count) tasks and \(clients.count) clients were saved to \(url.lastPathComponent).")
        } catch {
            showAlert("Couldn't save the backup", error.localizedDescription)
        }
    }

    func importBackup() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(Backup.self, from: data)

            let alert = NSAlert()
            alert.messageText = "Replace all current data?"
            alert.informativeText = "Your current \(tasks.count) tasks and \(clients.count) clients will be replaced with \(backup.tasks.count) tasks and \(backup.clients.count) clients from this backup."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // A timer that was running when the backup was made stopped at export time;
            // otherwise everything between export and import would count as work.
            var imported = backup.tasks
            for i in imported.indices {
                imported[i].ensureStages()
                guard let start = imported[i].startedAt else { continue }
                let end = max(start, backup.exportedAt)
                imported[i].timeSpent = (imported[i].timeSpent ?? 0) + end.timeIntervalSince(start)
                imported[i].sessions = (imported[i].sessions ?? [])
                    + [WorkSession(start: start, end: end, stageID: imported[i].currentStage?.id)]
                imported[i].startedAt = nil
            }

            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            lastMove = nil
            tasks = imported
            clients = backup.clients
            for task in tasks { schedule(task) }
        } catch {
            showAlert("Couldn't read this backup file", error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Timer

    // Play / pause button
    // (only for a part being worked on, not while it waits for review)
    func toggleTimer(_ task: TaskItem) {
        guard let i = index(of: task) else { return }
        if tasks[i].isRunning {
            stopTimer(at: i)
        } else if tasks[i].isOpen {
            startTimer(at: i)
            updateStatus(at: i)
        }
    }

    // Only one timer runs at a time, so any other running timer is paused first
    private func startTimer(at i: Int) {
        for j in tasks.indices where j != i && tasks[j].isRunning {
            stopTimer(at: j)
        }
        if tasks[i].startedAt == nil {
            tasks[i].startedAt = Date()
        }
    }

    private func stopTimer(at i: Int) {
        guard let start = tasks[i].startedAt else { return }
        let end = Date()
        tasks[i].timeSpent = (tasks[i].timeSpent ?? 0) + end.timeIntervalSince(start)
        tasks[i].sessions = (tasks[i].sessions ?? [])
            + [WorkSession(start: start, end: end, stageID: tasks[i].currentStage?.id)]
        tasks[i].startedAt = nil
    }

    // Total time spent on all tasks for one client
    func totalTime(for clientName: String) -> TimeInterval {
        tasks.filter { $0.client == clientName }.reduce(0) { $0 + $1.elapsed() }
    }

    // Time worked per calendar day, split by client: [day: [client: seconds]]
    // Work that crosses midnight is split between the two days.
    func timeByDay(now: Date = Date()) -> [Date: [String: TimeInterval]] {
        let cal = Calendar.current
        var result: [Date: [String: TimeInterval]] = [:]

        func add(_ start: Date, _ end: Date, _ client: String) {
            var s = start
            while s < end {
                let dayStart = cal.startOfDay(for: s)
                let next = cal.date(byAdding: .day, value: 1, to: dayStart) ?? end
                let e = min(end, next)
                result[dayStart, default: [:]][client, default: 0] += e.timeIntervalSince(s)
                s = e
            }
        }

        for task in tasks {
            let sessions = task.sessions ?? []
            for session in sessions {
                add(session.start, session.end, task.client)
            }
            if let start = task.startedAt {
                add(start, now, task.client)
            }
            // Time tracked before session history existed goes on the task's own day
            let untracked = (task.timeSpent ?? 0) - sessions.reduce(0) { $0 + $1.duration }
            if untracked > 1 {
                result[cal.startOfDay(for: task.day), default: [:]][task.client, default: 0] += untracked
            }
        }
        return result
    }

    // Tasks you worked on this day that are now planned on another day (shown as history)
    func workedElsewhere(on day: Date, excluding shown: Set<UUID>) -> [TaskItem] {
        let cal = Calendar.current
        return tasks
            .filter { !shown.contains($0.id) && !cal.isDate($0.day, inSameDayAs: day) && $0.time(on: day) >= 1 }
            .sorted { ($0.client.lowercased(), $0.title.lowercased()) < ($1.client.lowercased(), $1.title.lowercased()) }
    }

    // How many tasks planned in a month are To Do / In Progress / Done
    func statusCounts(inMonthOf date: Date, client: String? = nil) -> [TaskStatus: Int] {
        let cal = Calendar.current
        var counts: [TaskStatus: Int] = [:]
        for task in tasks where cal.isDate(task.day, equalTo: date, toGranularity: .month)
            && (client == nil || task.client == client) {
            counts[task.status, default: 0] += 1
        }
        return counts
    }

    func workedTime(on day: Date, now: Date = Date()) -> TimeInterval {
        timeByDay(now: now)[Calendar.current.startOfDay(for: day)]?.values.reduce(0, +) ?? 0
    }

    // Deletes right away; asks first only if the task has tracked time
    func confirmDelete(_ task: TaskItem) {
        if task.elapsed() > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Delete \u{201C}\(task.title)\u{201D}?"
            alert.informativeText = "This task has \(formatDuration(task.elapsed())) of tracked time. Deleting it also removes that time from your reports."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        delete(task)
    }

    // Moves a task to another day. Time already worked stays on the days it was
    // worked; new time is counted on the day you work, and the task keeps the total.
    func moveToNextDay(_ task: TaskItem) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let base = max(cal.startOfDay(for: task.day), today)
        move(task, to: cal.date(byAdding: .day, value: 1, to: base) ?? base)
    }

    func moveToToday(_ task: TaskItem) {
        move(task, to: Calendar.current.startOfDay(for: Date()))
    }

    // Edit title, client and day. Tracked time stays on the days it was worked.
    func updateTask(_ id: UUID, title: String, client: String, day: Date) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let cal = Calendar.current
        let newDay = cal.startOfDay(for: day)
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { tasks[i].title = t }
        tasks[i].client = client

        if !cal.isDate(tasks[i].day, inSameDayAs: newDay) {
            // Time tracked before session history existed: pin it to the old day
            let untracked = (tasks[i].timeSpent ?? 0) - (tasks[i].sessions ?? []).reduce(0) { $0 + $1.duration }
            if untracked > 1 && !tasks[i].isRunning {
                let start = cal.startOfDay(for: tasks[i].day)
                tasks[i].sessions = (tasks[i].sessions ?? []) + [WorkSession(start: start, end: start.addingTimeInterval(untracked))]
            }
            if let r = tasks[i].reminder {
                let c = cal.dateComponents([.hour, .minute], from: r)
                tasks[i].reminder = cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: newDay)
            }
            tasks[i].day = newDay
        }
        schedule(tasks[i])
    }

    // Only allowed if the new day is today or later (never back into the past)
    func canMoveToPreviousDay(_ task: TaskItem) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return task.isOpen && cal.startOfDay(for: task.day) > today
    }

    func moveToPreviousDay(_ task: TaskItem) {
        guard canMoveToPreviousDay(task) else { return }
        let cal = Calendar.current
        let day = cal.startOfDay(for: task.day)
        move(task, to: cal.date(byAdding: .day, value: -1, to: day) ?? day)
    }

    // MARK: Undo last move

    struct MoveRecord: Equatable {
        let id = UUID()
        let taskID: UUID
        let title: String
        let oldDay: Date
        let oldReminder: Date?
        let newDay: Date
        let wasRunning: Bool
    }

    @Published var lastMove: MoveRecord?

    func undoLastMove() {
        guard let m = lastMove, let i = tasks.firstIndex(where: { $0.id == m.taskID }) else {
            lastMove = nil
            return
        }
        tasks[i].day = m.oldDay
        tasks[i].reminder = m.oldReminder
        // The move paused the timer; undo starts it again
        if m.wasRunning && tasks[i].isOpen {
            startTimer(at: i)
        }
        schedule(tasks[i])
        lastMove = nil
    }

    private func move(_ task: TaskItem, to newDay: Date) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let wasRunning = tasks[i].isRunning
        stopTimer(at: i)   // pause, so the time so far is saved on the day it was worked
        lastMove = MoveRecord(taskID: tasks[i].id, title: tasks[i].title,
                              oldDay: tasks[i].day, oldReminder: tasks[i].reminder, newDay: newDay,
                              wasRunning: wasRunning)
        setDay(at: i, to: newDay)
        schedule(tasks[i])
    }

    // Plans the task on another day. Time already worked stays on the days it was worked.
    private func setDay(at i: Int, to newDay: Date) {
        let cal = Calendar.current
        guard !cal.isDate(tasks[i].day, inSameDayAs: newDay) else { return }

        // Time tracked before session history existed: pin it to the old day
        let untracked = (tasks[i].timeSpent ?? 0) - (tasks[i].sessions ?? []).reduce(0) { $0 + $1.duration }
        if untracked > 1 {
            let start = cal.startOfDay(for: tasks[i].day)
            tasks[i].sessions = (tasks[i].sessions ?? []) + [WorkSession(start: start, end: start.addingTimeInterval(untracked))]
        }
        if let r = tasks[i].reminder {
            let c = cal.dateComponents([.hour, .minute], from: r)
            tasks[i].reminder = cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: newDay)
        }
        tasks[i].day = newDay
    }

    func delete(_ task: TaskItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
        tasks.removeAll { $0.id == task.id }
    }

    // MARK: Clients

    func addClient(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty,
              !clients.contains(where: { $0.name.lowercased() == n.lowercased() }) else { return }
        var list = clients
        list.append(Client(name: n))
        list.sort { $0.name.lowercased() < $1.name.lowercased() }
        clients = list
    }

    func deleteClient(_ client: Client) {
        clients.removeAll { $0.id == client.id }
    }

    func addTemplate(_ title: String, to clientID: UUID) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = clients.firstIndex(where: { $0.id == clientID }) else { return }
        clients[i].templates.append(t)
    }

    func removeTemplate(at index: Int, from clientID: UUID) {
        guard let i = clients.firstIndex(where: { $0.id == clientID }),
              clients[i].templates.indices.contains(index) else { return }
        clients[i].templates.remove(at: index)
    }

    // MARK: Reminder notification at the chosen time

    private func schedule(_ task: TaskItem) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
        guard let date = task.reminder, date > Date(), task.status != .done else { return }

        let content = UNMutableNotificationContent()
        content.title = task.client.isEmpty ? "Reminder" : task.client
        content.body = task.title
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)
        center.add(request) { _ in }
    }
}

// MARK: - Views

let appLocale = Locale(identifier: "en_US")

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var tab = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var startDate = startOfWeek(Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var knownToday = Calendar.current.startOfDay(for: Date())
    @State private var lastActive = Date()
    @State private var hostWindow: NSWindow?

    // Opening the app after 2+ minutes away always starts on today
    private func windowBecameActive() {
        refreshToday()
        if Date().timeIntervalSince(lastActive) > 120 {
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            startDate = startOfWeek(today)
        }
        lastActive = Date()
    }

    // If the app kept running past midnight, jump from "yesterday" to the real today
    private func refreshToday() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != knownToday else { return }
        if Calendar.current.isDate(selectedDay, inSameDayAs: knownToday) {
            selectedDay = today
            startDate = startOfWeek(today)
        }
        knownToday = today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Plan").tag(0)
                Text("Clients").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == 0 {
                PlanView(startDate: $startDate, selectedDay: $selectedDay)
            } else {
                ClientsView()
            }

            HStack {
                Button {
                    openWindow(id: "reports")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Reports", systemImage: "chart.bar")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                // Start the app automatically when you log in to your Mac
                Toggle("Open at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Open at Login failed: \(error)")
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()
                // Power button: quits the app (a running timer is paused and saved first)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quit Taskovi")
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            refreshToday()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            refreshToday()
        }
        // Only the menu bar window counts, not Reports or other windows
        .background(WindowReader { window in
            if let window { hostWindow = window }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard isHostWindow(note) else { return }
            windowBecameActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isHostWindow(note) else { return }
            lastActive = Date()
        }
    }

    private func isHostWindow(_ note: Notification) -> Bool {
        guard let window = note.object as? NSWindow, let hostWindow else { return false }
        return window === hostWindow
    }
}

// Reports the window a SwiftUI view is shown in
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.onChange = onChange
    }

    final class WindowTrackingView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Outside the current view update, so SwiftUI state can change safely
            DispatchQueue.main.async { [weak self] in self?.onChange?(window) }
        }
    }
}

// MARK: Plan

struct PlanView: View {
    @EnvironmentObject var store: TaskStore
    @Binding var startDate: Date
    @Binding var selectedDay: Date

    @State private var newTitle = ""
    @AppStorage("lastClient") private var newClient = ""   // remembers the last client you picked
    @State private var useReminder = false
    @State private var reminderTime = Date()
    @AppStorage("showWaiting") private var showWaiting = true

    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }

    private var days: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: startDate) }
    }

    private var isToday: Bool { cal.isDate(selectedDay, inSameDayAs: today) }

    private var templates: [String] {
        store.clients.first { $0.name == newClient }?.templates ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            weekStrip
            Divider()
            taskList
            Divider()
            addTaskForm
            footer
        }
    }

    // How far the selected day is from today
    private var relativeDayText: String {
        let diff = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: selectedDay)).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let d where d > 1: return "In \(d) days"
        default: return "\(-diff) days ago"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(appLocale)))
                .font(.headline)
                .lineLimit(1)
            // Blue "Today", or orange when you're looking at another day
            Text(relativeDayText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((isToday ? Color.accentColor : Color.orange).opacity(0.15), in: Capsule())
                .fixedSize()
            Spacer()
            if !cal.isDate(startDate, inSameDayAs: startOfWeek(today)) || !isToday {
                Button("Today") {
                    startDate = startOfWeek(today)
                    selectedDay = today
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // Days with arrows
    private var weekStrip: some View {
        let worked = store.timeByDay()   // calculated once for the whole week
        return HStack(spacing: 2) {
            arrow("chevron.left", -7)
            ForEach(days, id: \.self) { day in
                dayButton(day, worked: worked)
            }
            arrow("chevron.right", 7)
        }
    }

    private var overdueTasks: [TaskItem] {
        isToday ? store.overdue(before: today) : []
    }

    private var taskList: some View {
        let overdue = overdueTasks
        let list = store.tasks(for: selectedDay)
        // Today also lists every task waiting for review, so it's quick to find when the answer comes
        let waiting = isToday ? store.awaitingReview(excluding: Set(list.map(\.id))) : []
        let shown = Set(overdue.map(\.id) + list.map(\.id) + waiting.map(\.id))
        let history = store.workedElsewhere(on: selectedDay, excluding: shown)

        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !waiting.isEmpty {
                    waitingSection(waiting)
                }
                if overdue.isEmpty && list.isEmpty && history.isEmpty && waiting.isEmpty {
                    Text("No tasks for this day")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(overdue) { task in
                    TaskRow(task: task, day: selectedDay, overdue: true)
                }
                ForEach(list) { task in
                    TaskRow(task: task, day: selectedDay)
                }
                ForEach(history) { task in
                    HistoryTaskRow(task: task, day: selectedDay)
                }
            }
        }
        .frame(height: 250)
        .overlay(alignment: .bottom) {
            if let move = store.lastMove {
                UndoBar(move: move)
            }
        }
    }

    // "Waiting for review (3)" — click the header to show or hide the tasks
    private func waitingSection(_ waiting: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showWaiting.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showWaiting ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Image(systemName: "paperplane")
                    Text("Waiting for review (\(waiting.count))")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showWaiting {
                ForEach(waiting) { task in
                    TaskRow(task: task, day: selectedDay)
                }
            }
            Divider().padding(.vertical, 2)
        }
    }

    private var newTaskPlaceholder: String {
        isToday ? "New task…"
                : "New task for \(selectedDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))…"
    }

    private var addTaskForm: some View {
        VStack(spacing: 6) {
            clientRow
            TextField(newTaskPlaceholder, text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(newTitle) }
            reminderRow
        }
        .onAppear {
            // Forget the remembered client if it was deleted
            if !newClient.isEmpty && !store.clients.contains(where: { $0.name == newClient }) {
                newClient = ""
            }
        }
    }

    private var clientRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: $newClient) {
                Text("No client").tag("")
                ForEach(store.clients) { c in
                    Text(c.name).tag(c.name)
                }
            }
            .labelsHidden()
            .fixedSize()

            Spacer()

            Menu {
                ForEach(templates, id: \.self) { t in
                    Button(t) { add(t) }
                }
            } label: {
                Label("From List", systemImage: "list.bullet")
            }
            .fixedSize()
            .disabled(templates.isEmpty)
            .help("Add a task from this client's list")
        }
    }

    // The chosen reminder time on the selected day, or nil when the reminder is off
    private var reminderDate: Date? {
        guard useReminder else { return nil }
        let c = cal.dateComponents([.hour, .minute], from: reminderTime)
        return cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: selectedDay)
    }

    // A reminder in the past would never be shown, so such a task can't be added
    private func reminderInPast(now: Date = Date()) -> Bool {
        reminderDate.map { $0 <= now } ?? false
    }

    private var reminderRow: some View {
        // Re-checked every 15 seconds, so the warning appears once the time passes
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let past = reminderInPast(now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle(isOn: $useReminder) {
                        Label("Reminder", systemImage: "bell")
                    }
                    .toggleStyle(.checkbox)

                    if useReminder {
                        DatePicker("", selection: $reminderTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .fixedSize()
                    }

                    Spacer()

                    Button("Add") { add(newTitle) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || past)
                }
                if past {
                    Label("This time has already passed. Pick a later time or turn the reminder off.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        let dayTasks = store.tasks(for: selectedDay)
        let done = dayTasks.filter { !$0.isOpen }.count   // done, or sent for review

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(done) of \(dayTasks.count) done")
                Spacer()
                // Time worked on the selected day (live while a timer runs)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    workedLabel(now: context.date)
                }
            }
            Divider().padding(.vertical, 2)
            MonthStats(month: selectedDay)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func workedLabel(now: Date) -> some View {
        let worked = store.workedTime(on: selectedDay, now: now)
        let text = worked > 0 ? "\(formatDuration(worked)) worked" : "No time tracked"
        return Label(text, systemImage: "timer")
    }

    private func arrow(_ icon: String, _ offset: Int) -> some View {
        Button {
            startDate = cal.date(byAdding: .day, value: offset, to: startDate) ?? startDate
            // Select today if it's in this week, otherwise Monday
            let weekEnd = cal.date(byAdding: .day, value: 7, to: startDate) ?? startDate
            selectedDay = (today >= startDate && today < weekEnd) ? today : startDate
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func dayButton(_ day: Date, worked: [Date: [String: TimeInterval]]) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isDayToday = cal.isDate(day, inSameDayAs: today)
        let open = store.tasks(for: day).filter(\.isOpen).count
        let tracked = (worked[cal.startOfDay(for: day)]?.values.reduce(0, +) ?? 0) >= 60
        // Dot: past days = you tracked time that day; today and later = open tasks
        let showDot = day < today ? tracked : (open > 0 || tracked)

        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text(isDayToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)))
                    .font(.caption2.weight(isDayToday ? .bold : .regular))
                    .foregroundStyle(isDayToday ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Today: white number in a filled circle (like Apple Calendar)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDayToday ? Color.white : Color.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isDayToday ? Color.accentColor : Color.clear))
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(showDot ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.primary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ raw: String) {
        let title = raw.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !reminderInPast() else { return }

        store.add(title: title, client: newClient, day: selectedDay, reminder: reminderDate)
        newTitle = ""
        useReminder = false
    }
}

struct TaskRow: View {
    let task: TaskItem
    let day: Date          // the day shown in Plan
    var overdue: Bool = false
    @EnvironmentObject var store: TaskStore
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            statusButton
            details
            Spacer()
            if task.isOpen {
                timerButton
            }
            trailingControls
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            TaskEditView(task: task) { editing = false }
                .environmentObject(store)
        }
    }

    // Working: click = finish this part and send it for review.
    // Waiting for review: click = choose Revision or Approved.
    @ViewBuilder
    private var statusButton: some View {
        let icon = Image(systemName: task.progressIcon)
            .foregroundStyle(task.progressColor)
            .font(.system(size: 15))

        if task.status == .done {
            icon.help("Done")
        } else if task.isAwaitingReview {
            Menu {
                reviewMenuItems
            } label: {
                icon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Review came back? Choose Revision or Approved")
        } else {
            Button {
                store.sendForReview(task)
            } label: {
                icon
            }
            .buttonStyle(.plain)
            .help("Finish \(task.currentStage?.title ?? "this part") and send it for review")
        }
    }

    @ViewBuilder
    private var reviewMenuItems: some View {
        if let next = task.revisionStage() {
            Button("Revision \u{2192} Start \(next.title)") { store.markRevision(task) }
        }
        if let next = task.approvalStage() {
            Button("Approved \u{2192} Start \(next.title)") { store.markApproved(task) }
        } else {
            Button("Approved \u{2192} Task Done") { store.markApproved(task) }
        }
    }

    private var details: some View {
        detailsContent
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { editing = true }   // double-click the name to edit
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(task.title)
                .strikethrough(task.status == .done)
                .foregroundStyle(task.isOpen ? Color.primary : Color.secondary)
                .lineLimit(1)
            infoLine
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var infoLine: some View {
        HStack(spacing: 6) {
            if !task.client.isEmpty {
                Text(task.client)
            }
            if let r = task.reminder {
                Label(r.formatted(date: .omitted, time: .shortened), systemImage: "bell")
            }
            if overdue {
                Text("Overdue").foregroundStyle(.red)
            }
            if let sent = sentOnAnotherDay {
                Text("sent \(sent)").foregroundStyle(.blue)
            }
            timeInfo
                .layoutPriority(1)
                .fixedSize()
        }
    }

    // "Mon, Oct 5" when the task waits for review since another day than the one shown
    private var sentOnAnotherDay: String? {
        guard task.isAwaitingReview, let sent = task.currentStage?.sentAt,
              !Calendar.current.isDate(sent, inSameDayAs: day) else { return nil }
        return sent.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))
    }

    @ViewBuilder
    private var timeInfo: some View {
        if task.isRunning {
            // Live timer, updates every second
            TimelineView(.periodic(from: .now, by: 1)) { context in
                timeLabel(now: context.date)
                    .foregroundStyle(.orange)
            }
        } else if task.time(on: day) > 0 {
            timeLabel(now: Date())
        }
    }

    private var timerButton: some View {
        Button {
            store.toggleTimer(task)
        } label: {
            Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 11))
                .foregroundStyle(task.isRunning ? Color.orange : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.isRunning ? "Pause timer" : "Start timer")
    }

    // Status badge; on hover it is replaced by the Move and Delete buttons (same spot, no extra width)
    private var trailingControls: some View {
        ZStack(alignment: .trailing) {
            statusBadge
                .opacity(hovering ? 0 : 1)
            HStack(spacing: 2) {
                moveButton
                deleteButton
            }
            .opacity(hovering ? 1 : 0)
        }
    }

    // The part the task is in: "Body", "Fix body 1 sent", "Hooks", "Done"…
    private var statusBadge: some View {
        Text(task.progressTitle)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(task.progressColor.opacity(0.15), in: Capsule())
    }

    // Move to tomorrow, shown when the mouse is over the task
    private var moveButton: some View {
        HoverIconButton(icon: "arrow.turn.up.right",
                        visible: hovering && task.isOpen,
                        help: "Move to tomorrow") {
            store.moveToNextDay(task)
        }
    }

    // Delete, shown when the mouse is over the task
    private var deleteButton: some View {
        HoverIconButton(icon: "trash", visible: hovering, help: "Delete task") {
            store.confirmDelete(task)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if task.isOpen {
            Button(task.isRunning ? "Pause Timer" : "Start Timer") { store.toggleTimer(task) }
            if let stage = task.currentStage {
                Button("Finish \(stage.title) & Send for Review") { store.sendForReview(task) }
            }
        }
        if task.isAwaitingReview {
            reviewMenuItems
        }
        if task.status != .done {
            Button("Mark Whole Task as Done") { store.markDone(task) }
        }
        if let undo = store.undoStepTitle(task) {
            Button(undo) { store.undoStep(task) }
        }
        if task.isOpen {
            Divider()
            if overdue {
                Button("Move to Today") { store.moveToToday(task) }
            }
            if store.canMoveToPreviousDay(task) {
                Button("Move to Previous Day") { store.moveToPreviousDay(task) }
            }
            Button("Move to Tomorrow") { store.moveToNextDay(task) }
        }
        Divider()
        Button("Edit…") { editing = true }
        Button("Delete", role: .destructive) { store.confirmDelete(task) }
    }

    // Time worked on this task on the day shown (the total is in Reports)
    private func timeLabel(now: Date) -> some View {
        let onDay = task.time(on: day, now: now)
        let text = task.isRunning ? formatClock(onDay) : formatDuration(onDay)
        return Label(text, systemImage: "timer").monospacedDigit()
    }
}

// "September: 5 done · 10 in progress · 3 to do" — updates as soon as a status changes
struct MonthStatusLine: View {
    let month: Date
    @EnvironmentObject var store: TaskStore

    var body: some View {
        let counts = store.statusCounts(inMonthOf: month)
        HStack(spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide).locale(appLocale)) + ":")
            StatusCount(status: .done, count: counts[.done] ?? 0)
            StatusCount(status: .inProgress, count: counts[.inProgress] ?? 0)
            StatusCount(status: .todo, count: counts[.todo] ?? 0)
            Spacer()
        }
    }
}

// Month summary in the main window: one chosen client + total for all clients
struct MonthStats: View {
    let month: Date
    @EnvironmentObject var store: TaskStore
    @AppStorage("statsClient") private var client = ""   // "" = all clients

    var body: some View {
        let perDay = store.timeByDay()
        let hasClient = !client.isEmpty && store.clients.contains { $0.name == client }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).locale(appLocale)))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                clientMenu
            }
            if hasClient {
                statsRow(title: client,
                         counts: store.statusCounts(inMonthOf: month, client: client),
                         time: monthTime(perDay, client: client))
            }
            statsRow(title: "Total",
                     counts: store.statusCounts(inMonthOf: month),
                     time: monthTime(perDay, client: nil))
                .fontWeight(hasClient ? .semibold : .regular)
        }
    }

    private var clientMenu: some View {
        Menu {
            Button("All Clients") { client = "" }
            Divider()
            ForEach(store.clients) { c in
                Button(c.name) { client = c.name }
            }
        } label: {
            Text("Show: \(client.isEmpty ? "All Clients" : client)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // Time worked in this month (for one client, or all when nil)
    private func monthTime(_ perDay: [Date: [String: TimeInterval]], client: String?) -> TimeInterval {
        let cal = Calendar.current
        var total: TimeInterval = 0
        for (day, clients) in perDay where cal.isDate(day, equalTo: month, toGranularity: .month) {
            if let client {
                total += clients[client] ?? 0
            } else {
                total += clients.values.reduce(0, +)
            }
        }
        return total
    }

    private func statsRow(title: String, counts: [TaskStatus: Int], time: TimeInterval) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            CompactCount(status: .done, count: counts[.done] ?? 0)
            CompactCount(status: .inProgress, count: counts[.inProgress] ?? 0)
            CompactCount(status: .todo, count: counts[.todo] ?? 0)
            Spacer()
            Label(time > 0 ? formatDuration(time) : "–", systemImage: "timer")
                .monospacedDigit()
        }
    }
}

// Status icon + number, e.g. "✓ 4" (hover shows the full name)
struct CompactCount: View {
    let status: TaskStatus
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon)
                .foregroundStyle(status.color)
            Text("\(count)")
                .monospacedDigit()
        }
        .frame(width: 44, alignment: .leading)
        .help("\(count) \(status.title.lowercased())")
    }
}

struct StatusCount: View {
    let status: TaskStatus
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon)
                .foregroundStyle(status.color)
            Text("\(count) \(status.title.lowercased())")
        }
        .fixedSize()
    }
}

// "SC66 moved to Sun, Sep 27 · Undo" — shown for 6 seconds after a task is moved
struct UndoBar: View {
    let move: TaskStore.MoveRecord
    @EnvironmentObject var store: TaskStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.right")
                .foregroundStyle(.secondary)
            Text("\(move.title) moved to \(move.newDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))")
                .lineLimit(1)
            Spacer()
            Button("Undo") { store.undoLastMove() }
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        .padding(4)
        .task(id: move.id) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if store.lastMove?.id == move.id {
                store.lastMove = nil
            }
        }
    }
}

// A task you worked on this day that was moved to another day.
// Shows only the time from this day; the task itself lives on its current day.
struct HistoryTaskRow: View {
    let task: TaskItem
    let day: Date
    @EnvironmentObject var store: TaskStore
    @State private var editing = false

    private func partsText(now: Date) -> String {
        let parts = task.stageTimes(on: day, now: now)
        guard !parts.isEmpty else { return formatDuration(task.time(on: day, now: now)) }
        return parts.map { "\($0.stage.title) \(formatDuration($0.seconds))" }.joined(separator: " · ")
    }

    private var movedText: String {
        "→ " + task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                info
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help("Worked on this day, continued on another day")
        .contextMenu {
            Button("Edit…") { editing = true }
        }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            TaskEditView(task: task) { editing = false }
                .environmentObject(store)
        }
    }

    private var info: some View {
        HStack(spacing: 6) {
            if !task.client.isEmpty {
                Text(task.client)
            }
            // Which parts you worked on this day, e.g. "Body 1h 10m · Fix body 1 20m"
            TimelineView(.periodic(from: .now, by: task.isRunning ? 1 : 60)) { context in
                Label(partsText(now: context.date), systemImage: "timer")
                    .monospacedDigit()
            }
            .fixedSize()
            Text(movedText)
                .fixedSize()
        }
    }
}

// Change a task's name, client and day
struct TaskEditView: View {
    let task: TaskItem
    var onClose: () -> Void
    @EnvironmentObject var store: TaskStore

    @State private var title: String
    @State private var client: String
    @State private var day: Date

    init(task: TaskItem, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _client = State(initialValue: task.client)
        _day = State(initialValue: task.day)
    }

    private var clientNames: [String] {
        var names = store.clients.map(\.name)
        if !task.client.isEmpty && !names.contains(task.client) { names.append(task.client) }
        return names
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Task").font(.headline)

            TextField("Task name", text: $title)
                .textFieldStyle(.roundedBorder)

            Picker("Client", selection: $client) {
                Text("No client").tag("")
                ForEach(clientNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            DatePicker("Day", selection: $day, displayedComponents: .date)

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.updateTask(task.id, title: title, client: client, day: day)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

// Small icon button that only appears on hover (keeps its space so the row doesn't jump)
struct HoverIconButton: View {
    let icon: String
    let visible: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .help(help)
    }
}

// MARK: Clients

struct ClientsView: View {
    @EnvironmentObject var store: TaskStore
    @State private var selectedID: UUID?
    @State private var newName = ""
    @State private var newTemplate = ""

    var body: some View {
        if let id = selectedID, let client = store.clients.first(where: { $0.id == id }) {
            detail(client)
        } else {
            list
        }
    }

    // All clients
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(spacing: 2) {
                    if store.clients.isEmpty {
                        Text("No clients yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(store.clients) { c in
                        Button {
                            selectedID = c.id
                        } label: {
                            HStack {
                                Text(c.name)
                                Spacer()
                                let total = store.totalTime(for: c.name)
                                if total > 0 {
                                    Label(formatDuration(total), systemImage: "timer")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(c.templates.count == 1 ? "1 task" : "\(c.templates.count) tasks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Client", role: .destructive) { store.deleteClient(c) }
                        }
                    }
                }
            }
            .frame(height: 330)

            HStack {
                TextField("New client…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addClient)
                Button("Add", action: addClient)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // One client's tasks
    private func detail(_ client: Client) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedID = nil
                newTemplate = ""
            } label: {
                Label("Clients", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(client.name).font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if client.templates.isEmpty {
                        Text("Add the tasks you do for this client")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(Array(client.templates.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element)
                            Spacer()
                            Button {
                                store.removeTemplate(at: item.offset, from: client.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Delete")
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(height: 270)

            HStack {
                TextField("New task for \(client.name)…", text: $newTemplate)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTemplate(to: client) }
                Button("Add") { addTemplate(to: client) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addClient() {
        store.addClient(newName)
        newName = ""
    }

    private func addTemplate(to client: Client) {
        store.addTemplate(newTemplate, to: client.id)
        newTemplate = ""
    }
}

// MARK: - Reports window

// "SC60 · 3h 42m total" above the selected task's details
struct TaskTotalHeader: View {
    let task: TaskItem?

    var body: some View {
        if let task {
            TimelineView(.periodic(from: .now, by: task.isRunning ? 1 : 60)) { context in
                Text("\(task.title) · \(formatDuration(task.elapsed(at: context.date))) total")
                    .font(.headline)
            }
        } else {
            Text("Task Details").font(.headline)
        }
    }
}

// Time per part of the selected task: "Body 1h 20m · Fix body 1 25m · Hooks 40m (sent)"
struct TaskStagesLine: View {
    let task: TaskItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: task.isRunning ? 1 : 60)) { context in
            ScrollView(.horizontal, showsIndicators: false) {
                stagesRow(now: context.date)
            }
        }
    }

    private func stagesRow(now: Date) -> some View {
        HStack(spacing: 14) {
            ForEach(task.stages ?? []) { stage in
                HStack(spacing: 4) {
                    Image(systemName: icon(stage))
                        .foregroundStyle(color(stage))
                    Text(stage.title)
                    Text(formatDuration(task.time(of: stage, now: now)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .fixedSize()
                .help(help(stage))
            }
        }
        .lineLimit(1)
    }

    private func icon(_ stage: TaskStage) -> String {
        switch stage.state {
        case .working: return "circle.lefthalf.filled"
        case .sent: return "paperplane.circle.fill"
        case .revision: return "arrow.uturn.backward.circle.fill"
        case .approved: return "checkmark.circle.fill"
        }
    }

    private func color(_ stage: TaskStage) -> Color {
        switch stage.state {
        case .working: return .orange
        case .sent: return .blue
        case .revision: return .red
        case .approved: return .green
        }
    }

    private func help(_ stage: TaskStage) -> String {
        switch stage.state {
        case .working: return "Working on it"
        case .sent: return "Sent for review"
        case .revision: return "Got a revision"
        case .approved: return "Approved"
        }
    }
}

// Time worked on the selected task, per date
struct TaskDaysList: View {
    let task: TaskItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("By Day")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if let task {
                TimelineView(.periodic(from: .now, by: task.isRunning ? 1 : 60)) { context in
                    rows(task.timePerDay(now: context.date))
                }
            } else {
                Text("Select a task.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func rows(_ perDay: [Date: TimeInterval]) -> some View {
        let days = perDay.keys.sorted(by: >)
        if days.isEmpty {
            Text("No time tracked yet.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
                            Spacer()
                            Text(formatDuration(perDay[day] ?? 0))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

// Time column in the Reports table (live while running)
struct TaskTimeCell: View {
    let task: TaskItem

    var body: some View {
        if task.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatClock(task.elapsed(at: context.date)))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        } else {
            Text(task.elapsed() > 0 ? formatDuration(task.elapsed()) : "–")
                .monospacedDigit()
        }
    }
}

// One row in the Reports sidebar: title on the left, time on the right, clickable across the full width
struct SidebarRow: View {
    let title: String
    let icon: String?
    let value: String

    var body: some View {
        HStack {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

struct ReportsView: View {
    @EnvironmentObject var store: TaskStore

    private static let allKey = "\u{0}all"
    private static let timeKey = "\u{0}time"
    @State private var selection: String? = ReportsView.allKey
    @State private var selectedTaskID: TaskItem.ID?
    @State private var editingTask: TaskItem?
    @State private var sortOrder = [KeyPathComparator(\TaskItem.day, order: .reverse)]

    private struct ClientGroup {
        let name: String
        let total: TimeInterval
        let count: Int
    }

    // All clients (including ones only used in tasks), most time first
    private var groups: [ClientGroup] {
        let names = Set(store.clients.map(\.name)).union(store.tasks.map(\.client))
        return names.map { name in
            let list = store.tasks.filter { $0.client == name }
            return ClientGroup(name: name,
                               total: list.reduce(0) { $0 + $1.elapsed() },
                               count: list.count)
        }
        .filter { !($0.name.isEmpty && $0.count == 0) }
        .sorted { ($0.total, $1.name.lowercased()) > ($1.total, $0.name.lowercased()) }
    }

    // Time worked this month, shown next to "Daily & Monthly"
    private var monthTotal: TimeInterval {
        let start = startOfMonth(Date())
        return store.timeByDay()
            .filter { $0.key >= start }
            .reduce(0) { $0 + $1.value.values.reduce(0, +) }
    }

    private func durationOrDash(_ t: TimeInterval) -> String {
        t > 0 ? formatDuration(t) : "–"
    }

    private func displayName(_ name: String) -> String {
        name.isEmpty ? "No Client" : name
    }

    private var rows: [TaskItem] {
        let list: [TaskItem]
        if selection == Self.allKey || selection == nil {
            list = store.tasks
        } else {
            list = store.tasks.filter { $0.client == selection }
        }
        return list.sorted(using: sortOrder)
    }

    private var selectedTask: TaskItem? {
        store.tasks.first { $0.id == selectedTaskID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailArea
        }
        .toolbar { backupButtons }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            SidebarRow(title: "Daily & Monthly", icon: "calendar", value: durationOrDash(monthTotal))
                .onTapGesture { selection = Self.timeKey }
                .tag(String?.some(Self.timeKey))

            SidebarRow(title: "All Clients", icon: "person.3", value: durationOrDash(allTotal))
                .tag(String?.some(Self.allKey))

            Section("Clients") {
                ForEach(groups, id: \.name) { g in
                    SidebarRow(title: displayName(g.name), icon: nil, value: durationOrDash(g.total))
                        .tag(String?.some(g.name))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ViewBuilder
    private var detailArea: some View {
        if selection == Self.timeKey {
            TimeOverviewView()
        } else {
            detail
        }
    }

    @ToolbarContentBuilder
    private var backupButtons: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.importBackup()
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }
            Button {
                store.exportBackup()
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var allTotal: TimeInterval {
        store.tasks.reduce(0) { $0 + $1.elapsed() }
    }

    private var detail: some View {
        let list = rows
        let total = list.reduce(0) { $0 + $1.elapsed() }
        let done = list.filter { $0.status == .done }.count
        let title = (selection == Self.allKey || selection == nil) ? "All Clients" : displayName(selection ?? "")

        return VStack(alignment: .leading, spacing: 14) {
            // Summary
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold())
                HStack(spacing: 16) {
                    Label(formatDuration(total), systemImage: "timer")
                    Label(list.count == 1 ? "1 task" : "\(list.count) tasks", systemImage: "list.bullet")
                    Label("\(done) done", systemImage: "checkmark.circle")
                }
                .foregroundStyle(.secondary)
            }

            // Tasks table (click a column header to sort, right-click to edit)
            tasksTable(list)

            // Selected task: total, time per part, time per day, and work sessions
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let task = selectedTask {
                        TaskStagesLine(task: task)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        TaskDaysList(task: selectedTask)
                            .frame(width: 200, alignment: .topLeading)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Work Sessions")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            sessionsView
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(height: 190, alignment: .top)
            } label: {
                TaskTotalHeader(task: selectedTask)
            }
        }
        .padding(20)
    }

    private func tasksTable(_ list: [TaskItem]) -> some View {
        Table(list, selection: $selectedTaskID, sortOrder: $sortOrder) {
            TableColumn("Task", value: \.title)
            TableColumn("Client", value: \.client) { task in
                Text(displayName(task.client))
            }
            TableColumn("Day", value: \.day) { task in
                Text(task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
            }
            TableColumn("Status", value: \.status.rawValue) { task in
                Label(task.progressTitle, systemImage: task.progressIcon)
                    .foregroundStyle(task.progressColor)
            }
            TableColumn("Time", value: \.totalSeconds) { task in
                TaskTimeCell(task: task)
            }
        }
        .contextMenu(forSelectionType: TaskItem.ID.self) { ids in
            if let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) {
                Button("Edit…") { editingTask = task }
                Button("Delete", role: .destructive) { store.confirmDelete(task) }
            }
        } primaryAction: { ids in
            // Double-click a row to edit
            if let id = ids.first { editingTask = store.tasks.first { $0.id == id } }
        }
        .sheet(item: $editingTask) { task in
            TaskEditView(task: task) { editingTask = nil }
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private var sessionsView: some View {
        if let task = selectedTask {
            let sessions = (task.sessions ?? []).sorted { $0.start > $1.start }
            if sessions.isEmpty && !task.isRunning {
                Text(task.elapsed() > 0
                     ? "This time was tracked before session history was added."
                     : "No time tracked for this task yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let start = task.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                sessionRow(start: start, endText: "now",
                                           part: task.currentStage?.title ?? "",
                                           duration: context.date.timeIntervalSince(start),
                                           running: true)
                            }
                        }
                        ForEach(sessions) { s in
                            sessionRow(start: s.start,
                                       endText: s.end.formatted(date: .omitted, time: .shortened),
                                       part: task.stageTitle(of: s),
                                       duration: s.duration,
                                       running: false)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            Text("Select a task to see when you worked on it.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func sessionRow(start: Date, endText: String, part: String,
                            duration: TimeInterval, running: Bool) -> some View {
        HStack {
            Text(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
                .frame(width: 100, alignment: .leading)
            Text("\(start.formatted(date: .omitted, time: .shortened)) – \(endText)")
                .frame(width: 150, alignment: .leading)
            Text(part)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(running ? formatClock(duration) : formatDuration(duration))
                .monospacedDigit()
                .foregroundStyle(running ? Color.orange : Color.primary)
        }
    }
}

// MARK: Daily & Monthly time

struct TimeOverviewView: View {
    @EnvironmentObject var store: TaskStore
    @State private var month = startOfMonth(Date())

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let running = store.tasks.contains { $0.isRunning }
        TimelineView(.periodic(from: .now, by: running ? 1 : 60)) { context in
            MonthReport(month: $month, data: MonthData(byDay: store.timeByDay(now: context.date), month: month))
        }
    }
}

// All numbers for one month, calculated once
struct MonthData {
    let days: [Date]                       // days with time, newest first
    let perDay: [Date: TimeInterval]
    let perDayClients: [Date: [String: TimeInterval]]
    let clients: [String]                  // most time first
    let perClient: [String: TimeInterval]
    let total: TimeInterval
    let longestDay: TimeInterval

    init(byDay: [Date: [String: TimeInterval]], month: Date) {
        let end = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
        let inMonth = byDay.filter { $0.key >= month && $0.key < end }

        var perDay: [Date: TimeInterval] = [:]
        var perClient: [String: TimeInterval] = [:]
        for (day, clients) in inMonth {
            for (client, t) in clients {
                perDay[day, default: 0] += t
                perClient[client, default: 0] += t
            }
        }

        self.perDayClients = inMonth
        self.perDay = perDay
        self.perClient = perClient
        self.days = perDay.keys.sorted(by: >)
        self.clients = perClient.keys.sorted { (perClient[$0] ?? 0) > (perClient[$1] ?? 0) }
        self.total = perDay.values.reduce(0, +)
        self.longestDay = max(perDay.values.max() ?? 1, 1)
    }
}

func clientDisplayName(_ name: String) -> String {
    name.isEmpty ? "No Client" : name
}

struct MonthReport: View {
    @Binding var month: Date
    let data: MonthData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            summary
            MonthStatusLine(month: month)
                .font(.title3)
            if !data.clients.isEmpty {
                clientsBox
            }
            daysBox
        }
        .padding(20)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Text(month.formatted(.dateTime.month(.wide).year().locale(appLocale)))
                .font(.largeTitle.bold())
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
            Spacer()
            if !isCurrentMonth {
                Button("This Month") { month = startOfMonth(Date()) }
            }
        }
    }

    private var summary: some View {
        let count = data.days.count
        let totalText = data.total > 0 ? "\(formatDuration(data.total)) total" : "No time tracked"
        let daysText = count == 1 ? "1 day worked" : "\(count) days worked"
        let average = count > 0 ? data.total / Double(count) : 0

        return HStack(spacing: 16) {
            Label(totalText, systemImage: "timer")
            Label(daysText, systemImage: "calendar")
            if count > 0 {
                Label("\(formatDuration(average)) per day on average", systemImage: "chart.bar")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var clientsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.clients, id: \.self) { client in
                    HStack {
                        Text(clientDisplayName(client))
                        Spacer()
                        Text(formatDuration(data.perClient[client] ?? 0))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text("By Client").font(.headline)
        }
    }

    private var daysBox: some View {
        GroupBox {
            if data.days.isEmpty {
                Text("No time tracked in this month.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(data.days, id: \.self) { day in
                            DayReportRow(day: day,
                                         total: data.perDay[day] ?? 0,
                                         longest: data.longestDay,
                                         clients: data.perDayClients[day] ?? [:])
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } label: {
            Text("By Day").font(.headline)
        }
        .frame(maxHeight: .infinity)
    }
}

// One day in "By Day": date, bar, total, and time per client
struct DayReportRow: View {
    let day: Date
    let total: TimeInterval
    let longest: TimeInterval
    let clients: [String: TimeInterval]

    private var dateText: String {
        day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))
    }

    private var clientsText: String {
        clients
            .sorted { $0.value > $1.value }
            .map { "\(clientDisplayName($0.key)) \(formatDuration($0.value))" }
            .joined(separator: " · ")
    }

    private var barWidth: CGFloat {
        CGFloat(max(4, 180 * total / longest))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(dateText)
                .frame(width: 110, alignment: .leading)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: barWidth, height: 6)
                .frame(width: 180, alignment: .leading)
            Text(formatDuration(total))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(clientsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Animated timer icon

// Moves the clock hand one step per second, only while a timer is running.
// The 12 frames are drawn once at launch, so each tick just swaps an image.
final class IconAnimator: ObservableObject {
    @Published private(set) var step = 0
    let frames: [NSImage] = (0..<12).map { makeMenuBarTimerIcon(step: $0) }

    private var ticker: AnyCancellable?
    private var watch: AnyCancellable?

    init(store: TaskStore) {
        watch = store.$tasks
            .map { tasks in tasks.contains { $0.isRunning } }
            .removeDuplicates()
            .sink { [weak self] running in self?.setRunning(running) }
    }

    private func setRunning(_ running: Bool) {
        if running {
            guard ticker == nil else { return }
            ticker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.step = (self.step + 1) % self.frames.count
                }
        } else {
            ticker = nil
            step = 0
        }
    }

    var currentFrame: NSImage { frames[step] }
}

// MARK: - App

@main
struct TaskoviApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: TaskStore
    @StateObject private var animator: IconAnimator

    init() {
        let store = TaskStore.shared
        _store = StateObject(wrappedValue: store)
        _animator = StateObject(wrappedValue: IconAnimator(store: store))
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            // Timer running: clock icon. Otherwise: icon + number of open tasks for today
            let n = store.openTodayCount
            if store.tasks.contains(where: { $0.isRunning }) {
                Image(nsImage: animator.currentFrame)
            } else if n > 0 {
                Text("\(menuBarImage()) \(n)")
            } else {
                menuBarImage()
            }
        }
        .menuBarExtraStyle(.window)

        // Separate Reports window, opened from the "Reports" button
        Window("Reports", id: "reports") {
            ReportsView()
                .environmentObject(store)
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }

    private func menuBarImage() -> Image {
        Image(nsImage: makeMenuBarIcon())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, menu bar only
        NSApp.setActivationPolicy(.accessory)

        keepSingleCopy()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Only one copy of Taskovi may run (e.g. the one from Xcode and the one from Applications).
    // Two copies would each keep their own version of the tasks and overwrite each other.
    // A newly started copy asks the older one to quit (it saves first), then loads the latest data.
    private let launchID = UUID().uuidString
    private static let quitOthers = Notification.Name("com.taskovi.quitOtherCopies")

    private func keepSingleCopy() {
        let center = DistributedNotificationCenter.default()
        let myID = launchID

        // A newer copy started: save and quit this one
        center.addObserver(forName: Self.quitOthers, object: nil, queue: .main) { note in
            guard (note.object as? String) != myID else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }

        // Ask the older copy to quit, wait until it has really quit (it saves on the way out),
        // then load what it saved. Gives up waiting after 15 seconds.
        center.postNotificationName(Self.quitOthers, object: myID, userInfo: nil, deliverImmediately: true)
        Task { @MainActor in
            for _ in 0..<150 {
                if others.allSatisfy(\.isTerminated) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            TaskStore.shared.reload()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
