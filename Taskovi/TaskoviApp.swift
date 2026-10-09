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
// Body → Revision 1, 2… → (approved) → Hooks → Hooks revision 1, 2… → (approved) → Done
enum StageKind: String, Codable, CaseIterable {
    case body, bodyFix, hooks, hooksFix

    var isBodyPart: Bool { self == .body || self == .bodyFix }

    // Name for all parts of this kind together, used in reports
    var groupTitle: String {
        switch self {
        case .body: return "Body"
        case .bodyFix: return "Body revisions"
        case .hooks: return "Hooks"
        case .hooksFix: return "Hooks revisions"
        }
    }
}

enum StageState: String, Codable {
    case working    // being worked on
    case sent       // sent for review, waiting for an answer
    case revision   // review came back with a revision (a revision part follows)
    case approved   // review approved it
}

struct TaskStage: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: StageKind
    var number: Int = 0          // which revision: 1, 2, …  (0 for Body and Hooks)
    var state: StageState = .working
    var sentAt: Date? = nil

    var title: String {
        switch kind {
        case .body: return "Body"
        case .bodyFix: return "Revision \(number)"
        case .hooks: return "Hooks"
        case .hooksFix: return "Hooks revision \(number)"
        }
    }

    var stateIcon: String {
        switch state {
        case .working: return "circle.lefthalf.filled"
        case .sent: return "paperplane.circle.fill"
        case .revision: return "arrow.uturn.backward.circle.fill"
        case .approved: return "checkmark.circle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .working: return .orange
        case .sent: return .blue
        case .revision: return .red
        case .approved: return .green
        }
    }

    var stateTitle: String {
        switch state {
        case .working: return "Working on it"
        case .sent: return "Sent for review"
        case .revision: return "Got a revision"
        case .approved: return "Approved"
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
    var stages: [TaskStage]? = nil       // Body, revisions, Hooks… (the last one is the current part)

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

    var hasHooks: Bool { (stages ?? []).contains { $0.kind == .hooks } }

    // The part that starts when a review is approved. None after the hooks, or after a
    // body revision when the hooks were already done: then the task is done.
    func approvalStage() -> TaskStage? {
        guard let last = currentStage, last.kind.isBodyPart, !hasHooks else { return nil }
        return TaskStage(kind: .hooks)
    }

    // The revision part that reopens a finished task (hooks only if the task had hooks)
    func reopenStage(hooks: Bool) -> TaskStage? {
        guard !hooks || hasHooks else { return nil }
        let kind: StageKind = hooks ? .hooksFix : .bodyFix
        let number = (stages ?? []).filter { $0.kind == kind }.count + 1
        return TaskStage(kind: kind, number: number)
    }

    // Where the task is now: "Body", "Revision 1 sent", "Done"…
    var progressTitle: String {
        if status == .done { return "Done" }
        guard let stage = currentStage else { return status.title }
        return stage.state == .sent ? "\(stage.title) sent" : stage.title
    }

    // Whole days since the current part was sent for review (nil when not waiting)
    var daysWaiting: Int? {
        guard isAwaitingReview, let sent = currentStage?.sentAt else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: sent), to: cal.startOfDay(for: Date())).day
    }

    // "waiting 3 days" — blue at first, orange after 2 days, red after 4
    var waitingText: String? {
        guard let days = daysWaiting, days > 0 else { return nil }
        return days == 1 ? "waiting 1 day" : "waiting \(days) days"
    }

    var waitingColor: Color {
        switch daysWaiting ?? 0 {
        case ..<2: return .blue
        case 2..<4: return .orange
        default: return .red
        }
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

    // Time per kind of part: all body revisions together, all hooks revisions together…
    func timeByKind(now: Date = Date()) -> [StageKind: TimeInterval] {
        var result: [StageKind: TimeInterval] = [:]
        for stage in stages ?? [] {
            result[stage.kind, default: 0] += time(of: stage, now: now)
        }
        return result
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
    var manual: Bool? = nil    // added by hand with "Adjust Time"
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
        .sink { [weak self] _ in
            self?.pauseAll()
            self?.autoBackup()
        }
        .store(in: &cancellables)

        // Notice when you were away from the Mac while a timer kept running
        Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkAway() }
            .store(in: &cancellables)

        // Automatic backup: shortly after launch, then every hour
        Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .merge(with: Just(Date()).delay(for: .seconds(30), scheduler: RunLoop.main))
            .sink { [weak self] _ in self?.autoBackup() }
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

    // Tasks whose name or client contains the text: waiting for review first,
    // then open ones, then done; newest day first
    func search(_ query: String) -> [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func rank(_ t: TaskItem) -> Int { t.isAwaitingReview ? 0 : (t.isOpen ? 1 : 2) }
        return tasks
            .filter { $0.title.localizedCaseInsensitiveContains(q) || $0.client.localizedCaseInsensitiveContains(q) }
            .sorted { (rank($0), $1.day) < (rank($1), $0.day) }
    }

    // MARK: Parts (Body → revisions → Hooks → revisions → Done)

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

    // The review came back with a revision: the next revision starts today, with its own timer running
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

    // A finished task needs more work: start a body or hooks revision today, with the timer running
    func reopen(_ task: TaskItem, hooks: Bool) {
        guard let i = index(of: task), tasks[i].status == .done,
              let next = tasks[i].reopenStage(hooks: hooks) else { return }
        tasks[i].stages = (tasks[i].stages ?? []) + [next]
        tasks[i].status = .inProgress
        setDay(at: i, to: todayStart)
        startTimer(at: i)
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
            if stages[stages.count - 2].state == .revision { return "Undo Revision" }
            return last.kind == .hooks ? "Undo Approval" : "Undo Reopen"
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
            // Remove the part and the few minutes tracked on it
            stopTimer(at: i)
            let removed = stages.removeLast()
            let sessions = tasks[i].sessions ?? []
            let removedTime = sessions.filter { $0.stageID == removed.id }.reduce(0) { $0 + $1.duration }
            tasks[i].sessions = sessions.filter { $0.stageID != removed.id }
            tasks[i].timeSpent = max(0, (tasks[i].timeSpent ?? 0) - removedTime)
            if removed.kind != .hooks && stages[stages.count - 1].state == .approved {
                tasks[i].status = .done                 // undo a reopen: the task is finished again
            } else {
                stages[stages.count - 1].state = .sent  // the previous part waits for review again
            }
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

        do {
            try backupData().write(to: url, options: .atomic)
            showAlert("Backup saved",
                      "\(tasks.count) tasks and \(clients.count) clients were saved to \(url.lastPathComponent).")
        } catch {
            showAlert("Couldn't save the backup", error.localizedDescription)
        }
    }

    private func backupData() throws -> Data {
        let backup = Backup(version: 1, exportedAt: Date(), tasks: tasks, clients: clients)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    // ~/Library/Application Support/Taskovi/Backups
    static var backupsFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Taskovi/Backups", isDirectory: true)
    }

    // One backup file per day (updated through the day), the newest 30 days are kept
    func autoBackup() {
        let fm = FileManager.default
        guard let folder = Self.backupsFolder,
              !(tasks.isEmpty && clients.isEmpty) else { return }   // never replace a backup with nothing
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let day = Date().formatted(.iso8601.year().month().day())
            try backupData().write(to: folder.appendingPathComponent("Taskovi Backup \(day).json"), options: .atomic)

            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Taskovi Backup ") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in files.dropFirst(30) {
                try? fm.removeItem(at: old)
            }
        } catch {
            print("Automatic backup failed: \(error)")
        }
    }

    func openBackupsFolder() {
        guard let folder = Self.backupsFolder else { return }
        autoBackup()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
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

    // MARK: Away from the Mac

    // After this long without using the mouse or keyboard, you count as away
    private static let awayLimit: TimeInterval = 10 * 60
    private var awaySince: Date?

    private func checkAway() {
        guard tasks.contains(where: \.isRunning) else {
            awaySince = nil
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        if idle >= Self.awayLimit {
            if awaySince == nil { awaySince = Date().addingTimeInterval(-idle) }
        } else if let since = awaySince {
            // You're back: ask whether the time away should count
            awaySince = nil
            askAboutAwayTime(since: since, back: Date().addingTimeInterval(-idle))
        }
    }

    private func askAboutAwayTime(since: Date, back: Date) {
        guard let task = tasks.first(where: \.isRunning), let started = task.startedAt else { return }
        let from = max(since, started)
        let away = back.timeIntervalSince(from)
        guard away >= 60 else { return }

        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        let part = task.currentStage.map { " \u{00B7} \($0.title)" } ?? ""
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You were away for \(formatDuration(away))"
        alert.informativeText = "From \(time(from)) to \(time(back)) the timer for \(task.title)\(part) kept running. Should that time count?"
        alert.addButton(withTitle: "Keep the Time")
        alert.addButton(withTitle: "Remove It")
        alert.addButton(withTitle: "Remove It & Stop Timer")
        let answer = alert.runModal()
        guard answer != .alertFirstButtonReturn else { return }
        removeAwayTime(taskID: task.id, from: from, back: back, stop: answer == .alertThirdButtonReturn)
    }

    // Saves the work up to when you left; the timer continues from when you came back (or stops)
    private func removeAwayTime(taskID: UUID, from: Date, back: Date, stop: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }), let started = tasks[i].startedAt else { return }
        let end = max(from, started)
        if end > started {
            tasks[i].timeSpent = (tasks[i].timeSpent ?? 0) + end.timeIntervalSince(started)
            tasks[i].sessions = (tasks[i].sessions ?? [])
                + [WorkSession(start: started, end: end, stageID: tasks[i].currentStage?.id)]
        }
        tasks[i].startedAt = stop ? nil : min(back, Date())
        updateStatus(at: i)
    }

    // MARK: Fixing time by hand

    // Adds time to a part (on a chosen day), or takes it off the most recent work on that part
    func adjustTime(_ task: TaskItem, stageID: UUID, by seconds: TimeInterval, on day: Date) {
        guard let i = index(of: task), seconds != 0 else { return }
        let cal = Calendar.current
        var sessions = tasks[i].sessions ?? []

        if seconds > 0 {
            // Today: ends now (or where the running timer started); another day: from noon
            let end = cal.isDateInToday(day)
                ? (tasks[i].startedAt ?? Date())
                : (cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day).addingTimeInterval(seconds)
            sessions.append(WorkSession(start: end.addingTimeInterval(-seconds), end: end,
                                        stageID: stageID, manual: true))
            tasks[i].sessions = sessions
            tasks[i].timeSpent = (tasks[i].timeSpent ?? 0) + seconds
        } else {
            var remaining = -seconds
            // The running timer is the most recent work
            if tasks[i].currentStage?.id == stageID, let started = tasks[i].startedAt {
                let cut = min(remaining, max(0, Date().timeIntervalSince(started)))
                tasks[i].startedAt = started.addingTimeInterval(cut)
                remaining -= cut
            }
            let first = tasks[i].stages?.first?.id
            var removed: TimeInterval = 0
            for k in sessions.indices.sorted(by: { sessions[$0].end > sessions[$1].end }) {
                if remaining <= 0 { break }
                guard (sessions[k].stageID ?? first) == stageID else { continue }
                let cut = min(remaining, sessions[k].duration)
                sessions[k].end = sessions[k].end.addingTimeInterval(-cut)
                remaining -= cut
                removed += cut
            }
            tasks[i].sessions = sessions.filter { $0.duration >= 1 }
            tasks[i].timeSpent = max(0, (tasks[i].timeSpent ?? 0) - removed)
        }
        updateStatus(at: i)
    }

    func confirmDeleteSession(_ task: TaskItem, _ session: WorkSession) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete this work session?"
        alert.informativeText = "\(formatDuration(session.duration)) on \(task.title) will be removed from your time."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let i = index(of: task) else { return }
        tasks[i].sessions = (tasks[i].sessions ?? []).filter { $0.id != session.id }
        tasks[i].timeSpent = max(0, (tasks[i].timeSpent ?? 0) - session.duration)
        updateStatus(at: i)
    }

    // Task to show when Reports opens from a task card in the menu bar
    @Published var reportTaskID: UUID?

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

    private func showReports() {
        showReportsWindow(openWindow)
    }

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
                    showReports()
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
            if let window {
                hostWindow = window
                menuBarWindow = window
            }
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

// The menu bar window, so it can be closed when Reports opens
weak var menuBarWindow: NSWindow?

// Opens Reports, or brings it back to the front if it is already open
// (behind other apps, or minimized), and closes the menu bar window
func showReportsWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "reports")
    DispatchQueue.main.async {
        menuBarWindow?.close()
        guard let window = NSApp.windows.first(where: isReportsWindow) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

// The Reports window (SwiftUI names it after the scene id "reports")
func isReportsWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix("reports") == true || window.title == "Reports"
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
    @State private var showReminderPicker = false
    @State private var addingClient = false
    @State private var newClientName = ""
    @AppStorage("showWaiting") private var showWaiting = true
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

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
            if searching {
                searchBar
                Divider()
                searchResults
            } else {
                header
                weekStrip
                Divider()
                taskList
                Divider()
                addTaskForm
            }
            footer
        }
    }

    // MARK: Search

    private func openSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        searching = false
        query = ""
    }

    private var searchButton: some View {
        Button(action: openSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut("f", modifiers: .command)
        .help("Search all tasks (\u{2318}F)")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all tasks or clients…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand(perform: closeSearch)   // Esc closes the search
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button("Done", action: closeSearch)
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // Matching tasks from every day; click one to open its card (Move to Today, Revision, Approved…)
    private var searchResults: some View {
        let results = store.search(query)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type a task or client name")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if results.isEmpty {
                    Text("No tasks found")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(results) { task in
                    TaskRow(task: task, day: task.day, showDay: true)
                }
            }
        }
        .frame(height: 400)
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
            searchButton
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

    private var selectedDayText: String {
        selectedDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))
    }

    // "New Task" panel: name + Add, then chips for client, the client's list and a reminder
    private var addTaskForm: some View {
        // Re-checked every 15 seconds, so the reminder warning appears once the time passes
        LiveView(every: 15) { now in
            let past = reminderInPast(now: now)
            let canAdd = !newTitle.trimmingCharacters(in: .whitespaces).isEmpty && !past

            VStack(alignment: .leading, spacing: 8) {
                PanelTitle(icon: "plus.circle.fill",
                           title: "New Task",
                           detail: isToday ? "for today" : "for \(selectedDayText)")
                HStack(spacing: 6) {
                    TextField("Task name, e.g. SC01", text: $newTitle)
                        .entryField()
                        .onSubmit { add(newTitle) }
                    Button {
                        add(newTitle)
                    } label: {
                        Text("Add").fontWeight(.semibold).padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                }
                HStack(spacing: 6) {
                    clientChip
                    if !templates.isEmpty {
                        templatesChip
                    }
                    reminderChip
                    Spacer(minLength: 0)
                }
                if addingClient {
                    newClientRow
                }
                if past {
                    Label("This time has already passed. Pick a later time or remove the reminder.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .entryPanel()
        }
        .onAppear {
            // Forget the remembered client if it was deleted
            if !newClient.isEmpty && !store.clients.contains(where: { $0.name == newClient }) {
                newClient = ""
            }
        }
    }

    // Who the task is for; also lets you create a new client right here
    private var clientChip: some View {
        Menu {
            Button {
                newClient = ""
            } label: {
                if newClient.isEmpty { Label("No client", systemImage: "checkmark") } else { Text("No client") }
            }
            if !store.clients.isEmpty {
                Divider()
            }
            ForEach(store.clients) { c in
                Button {
                    newClient = c.name
                } label: {
                    if c.name == newClient { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Divider()
            Button {
                addingClient = true
            } label: {
                Label("New Client…", systemImage: "plus")
            }
        } label: {
            Chip(icon: "person.fill", text: newClient.isEmpty ? "Client" : newClient, active: !newClient.isEmpty)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the client")
    }

    // Tasks you regularly do for this client: one click adds it
    private var templatesChip: some View {
        Menu {
            Section("Add from \(newClient)'s list") {
                ForEach(templates, id: \.self) { t in
                    Button(t) { add(t) }
                }
            }
        } label: {
            Chip(icon: "list.bullet", text: "From list", active: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a task from this client's list")
    }

    private var reminderChip: some View {
        Button {
            if !useReminder {
                // Suggest the next full hour
                let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                reminderTime = cal.date(bySetting: .minute, value: 0, of: next) ?? next
            }
            showReminderPicker = true
        } label: {
            Chip(icon: useReminder ? "bell.fill" : "bell",
                 text: useReminder ? reminderTime.formatted(date: .omitted, time: .shortened) : "Reminder",
                 active: useReminder)
        }
        .buttonStyle(.plain)
        .help("Get a notification at a set time")
        .popover(isPresented: $showReminderPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Remind me at").font(.headline)
                DatePicker("", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                HStack {
                    if useReminder {
                        Button("Remove") {
                            useReminder = false
                            showReminderPicker = false
                        }
                    }
                    Spacer()
                    Button("Set") {
                        useReminder = true
                        showReminderPicker = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 220)
        }
    }

    private var newClientRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.secondary)
            TextField("New client name", text: $newClientName)
                .entryField()
                .onSubmit(saveNewClient)
            Button("Save", action: saveNewClient)
                .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                addingClient = false
                newClientName = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel")
        }
    }

    // Adds the client and picks it for the new task
    private func saveNewClient() {
        let name = newClientName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.addClient(name)
        newClient = store.clients.first { $0.name.lowercased() == name.lowercased() }?.name ?? name
        addingClient = false
        newClientName = ""
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
    var showDay: Bool = false   // search results: show which day the task is planned on
    @EnvironmentObject var store: TaskStore
    @State private var hovering = false
    @State private var editing = false
    @State private var showingDetail = false

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            details
            Spacer()
            if task.isOpen {
                timerButton
            }
            trailingControls
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showingDetail = true }   // click a task to see it and its next step
        .contextMenu { menuItems }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            TaskEditView(task: task) { editing = false }
                .environmentObject(store)
        }
    }

    private var statusIcon: some View {
        Image(systemName: task.progressIcon)
            .foregroundStyle(task.progressColor)
            .font(.system(size: 15))
            .frame(width: 17)
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
            .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
                TaskDetailView(taskID: task.id, day: day) { showingDetail = false }
                    .environmentObject(store)
            }
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
            if showDay {
                Label(Calendar.current.isDateInToday(task.day) ? "Today"
                        : task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)),
                      systemImage: "calendar")
            }
            if let r = task.reminder {
                Label(r.formatted(date: .omitted, time: .shortened), systemImage: "bell")
            }
            if overdue {
                Text("Overdue").foregroundStyle(.red)
            }
            if let waiting = task.waitingText {
                Text(waiting).foregroundStyle(task.waitingColor)
            }
            timeInfo
                .layoutPriority(1)
                .fixedSize()
        }
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

    // The part the task is in: "Body", "Revision 1 sent", "Hooks", "Done"…
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
        if task.status == .done {
            if let body = task.reopenStage(hooks: false) {
                Button("Body Revision \u{2192} Start \(body.title)") { store.reopen(task, hooks: false) }
            }
            if let hooks = task.reopenStage(hooks: true) {
                Button("Hooks Revision \u{2192} Start \(hooks.title)") { store.reopen(task, hooks: true) }
            }
        } else {
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
    @State private var hovering = false
    @State private var showingDetail = false

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
        .padding(.horizontal, 4)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showingDetail = true }
        .help("Worked on this day, continued on another day")
        .contextMenu {
            Button("Open…") { showingDetail = true }
        }
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            TaskDetailView(taskID: task.id, day: day) { showingDetail = false }
                .environmentObject(store)
        }
    }

    private var info: some View {
        HStack(spacing: 6) {
            if !task.client.isEmpty {
                Text(task.client)
            }
            // Which parts you worked on this day, e.g. "Body 1h 10m · Revision 1 20m"
            LiveView(every: task.isRunning ? 1 : 60) { now in
                Label(partsText(now: now), systemImage: "timer")
                    .monospacedDigit()
            }
            .fixedSize()
            Text(movedText)
                .fixedSize()
        }
    }
}

// The card that opens when you click a task: where it is, time per part,
// and big buttons for the next step (Start Body, Finish Body, Revision, Approved…)
struct TaskDetailView: View {
    let taskID: UUID
    let day: Date          // the day shown in Plan
    var showReportButton = true
    var onClose: () -> Void
    @EnvironmentObject var store: TaskStore
    @Environment(\.openWindow) private var openWindow
    @State private var editing = false
    @State private var adjusting = false

    var body: some View {
        if let task = store.tasks.first(where: { $0.id == taskID }) {
            if editing {
                TaskEditView(task: task) { editing = false }
            } else {
                LiveView(every: task.isRunning ? 1 : 30) { now in
                    content(task, now: now)
                }
            }
        } else {
            Text("This task was deleted.")
                .foregroundStyle(.secondary)
                .padding(20)
        }
    }

    private func content(_ task: TaskItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(task)
            if task.isOpen && !Calendar.current.isDateInToday(task.day) {
                moveBanner(task)
            }
            currentCard(task, now: now)
            partsList(task, now: now)
            actions(task)
            HStack(spacing: 8) {
                if showReportButton {
                    reportButton
                }
                adjustButton(task)
            }
            Divider()
            footer(task)
        }
        .padding(16)
        .frame(width: 310)
    }

    // MARK: Header

    private func header(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 10) {
                if !task.client.isEmpty {
                    Label(task.client, systemImage: "person")
                }
                Label(task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)),
                      systemImage: "calendar")
                if let r = task.reminder {
                    Label(r.formatted(date: .omitted, time: .shortened), systemImage: "bell")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // "Planned for Tue, Oct 6 · Move to Today"
    private func moveBanner(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.orange)
            Text("Planned for \(task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))")
                .font(.caption)
            Spacer()
            Button("Move to Today") { store.moveToToday(task) }
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Where the task is now

    private func currentCard(_ task: TaskItem, now: Date) -> some View {
        let done = task.status == .done
        let partTime = task.currentStage.map { task.time(of: $0, now: now) } ?? 0
        let timeText = done ? formatDuration(task.elapsed(at: now))
                            : (task.isRunning ? formatClock(partTime) : formatDuration(partTime))

        return HStack(spacing: 12) {
            Image(systemName: task.progressIcon)
                .font(.system(size: 28))
                .foregroundStyle(task.progressColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(done ? "Task finished" : (task.currentStage?.title ?? ""))
                    .font(.headline)
                Text(stateText(task, partTime: partTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(timeText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(task.isRunning ? Color.orange : Color.primary)
                Text(done ? "total" : "this part")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(task.progressColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(task.progressColor.opacity(0.25)))
    }

    private func stateText(_ task: TaskItem, partTime: TimeInterval) -> String {
        if task.status == .done { return "All parts approved" }
        if task.isAwaitingReview {
            guard let sent = task.currentStage?.sentAt else { return "Waiting for review" }
            let when = sent.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(appLocale))
            let days = task.waitingText.map { " (\($0))" } ?? ""
            return "Sent \(when) · waiting for review\(days)"
        }
        if task.isRunning { return "Timer running" }
        return partTime > 0 ? "Paused" : "Not started yet"
    }

    // MARK: All parts, in order

    private func partsList(_ task: TaskItem, now: Date) -> some View {
        let stages = task.stages ?? []
        // Hooks still to come after the body parts
        let hooksAhead = task.status != .done && !stages.contains { !$0.kind.isBodyPart }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PARTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Total \(formatDuration(task.elapsed(at: now)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 6)

            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                partRow(icon: stage.stateIcon,
                        color: stage.stateColor,
                        title: stage.title,
                        subtitle: stage.stateTitle,
                        time: formatDuration(task.time(of: stage, now: now)),
                        isCurrent: stage.id == task.currentStage?.id && task.status != .done,
                        line: index < stages.count - 1 || hooksAhead)
            }
            if hooksAhead {
                partRow(icon: "circle.dotted", color: .secondary, title: "Hooks",
                        subtitle: "After the body is approved", time: "",
                        isCurrent: false, line: false)
                    .opacity(0.5)
            }
        }
    }

    private func partRow(icon: String, color: Color, title: String, subtitle: String,
                         time: String, isCurrent: Bool, line: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Icon with a line down to the next part
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .frame(height: 16)
                Rectangle()
                    .fill(Color.secondary.opacity(line ? 0.3 : 0))
                    .frame(width: 2, height: 14)
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(time)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Next step

    @ViewBuilder
    private func actions(_ task: TaskItem) -> some View {
        if task.status == .done {
            // Finished, but more work came in: reopen with a revision
            VStack(alignment: .leading, spacing: 8) {
                Text("More work on it?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        store.reopen(task, hooks: false)
                    } label: {
                        Label("Body Revision", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                    if task.hasHooks {
                        Button {
                            store.reopen(task, hooks: true)
                        } label: {
                            Label("Hooks Revision", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.purple)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(reopenHint(task))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if task.isAwaitingReview {
            VStack(alignment: .leading, spacing: 8) {
                Text("Did the review come back?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        store.markRevision(task)
                    } label: {
                        Label("Revision", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                    Button {
                        store.markApproved(task)
                    } label: {
                        Label("Approved", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(reviewHint(task))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let stage = task.currentStage {
            let started = task.time(of: stage) > 0
            VStack(spacing: 8) {
                Button {
                    store.toggleTimer(task)
                } label: {
                    Label(task.isRunning ? "Pause \(stage.title)"
                                         : (started ? "Continue \(stage.title)" : "Start \(stage.title)"),
                          systemImage: task.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(task.isRunning ? Color.orange : Color.accentColor)
                Button {
                    store.sendForReview(task)
                } label: {
                    Label("Finish \(stage.title) & Send", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.blue)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func reopenHint(_ task: TaskItem) -> String {
        let parts = [task.reopenStage(hooks: false), task.reopenStage(hooks: true)].compactMap { $0?.title }
        return "Starts \(parts.joined(separator: " or ")) today, with the timer running"
    }

    private func reviewHint(_ task: TaskItem) -> String {
        let revision = task.revisionStage().map { "Revision starts \($0.title)" } ?? ""
        let approved = task.approvalStage().map { "Approved starts \($0.title)" } ?? "Approved finishes the task"
        return "\(revision) · \(approved)"
    }

    // MARK: Small actions

    // Opens Reports with this task's full statistics
    private var reportButton: some View {
        Button {
            store.reportTaskID = taskID
            onClose()
            showReportsWindow(openWindow)
        } label: {
            Label("Task Report", systemImage: "chart.bar.xaxis")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help("Time by part, by day, and every work session")
    }

    // Forgot the timer, or left it running? Add or remove time by hand
    private func adjustButton(_ task: TaskItem) -> some View {
        Button {
            adjusting = true
        } label: {
            Label("Adjust Time", systemImage: "plusminus.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help("Add or remove time on any part")
        .popover(isPresented: $adjusting, arrowEdge: .bottom) {
            AdjustTimeView(task: task) { adjusting = false }
                .environmentObject(store)
        }
    }

    private func footer(_ task: TaskItem) -> some View {
        HStack(spacing: 14) {
            if let undo = store.undoStepTitle(task) {
                Button {
                    store.undoStep(task)
                } label: {
                    Label(undo, systemImage: "arrow.uturn.backward")
                }
            }
            Spacer()
            if task.status != .done {
                Button {
                    store.markDone(task)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Mark the whole task as done")
            }
            Button {
                editing = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Edit name, client and day")
            Button {
                onClose()
                DispatchQueue.main.async { store.confirmDelete(task) }
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete task")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// "Forgot the timer?" — add time to a part, or take some off
struct AdjustTimeView: View {
    let task: TaskItem
    var onClose: () -> Void
    @EnvironmentObject var store: TaskStore

    @State private var stageID: UUID
    @State private var minutes = 30
    @State private var day = Calendar.current.startOfDay(for: Date())

    init(task: TaskItem, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _stageID = State(initialValue: task.currentStage?.id ?? task.stages?.first?.id ?? UUID())
    }

    private var seconds: TimeInterval { TimeInterval(minutes * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust Time").font(.headline)

            Picker("Part", selection: $stageID) {
                ForEach(task.stages ?? []) { stage in
                    Text(stage.title).tag(stage.id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button(formatDuration(TimeInterval(m * 60))) { minutes = m }
                            .buttonStyle(.bordered)
                            .tint(minutes == m ? Color.accentColor : nil)
                            .controlSize(.small)
                    }
                }
                Stepper(value: $minutes, in: 5...720, step: 5) {
                    Text(formatDuration(seconds))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }

            DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)

            HStack {
                Button("Remove") {
                    store.adjustTime(task, stageID: stageID, by: -seconds, on: day)
                    onClose()
                }
                .help("Takes the time off the most recent work on this part")
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    store.adjustTime(task, stageID: stageID, by: seconds, on: day)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            Text("Add puts the time on the chosen day. Remove takes it off the most recent work on this part.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

// Full statistics for one task (shown in Reports under its card):
// time by kind of part, time by day, and every work session
struct TaskStatsView: View {
    let taskID: UUID
    @EnvironmentObject var store: TaskStore

    var body: some View {
        if let task = store.tasks.first(where: { $0.id == taskID }) {
            LiveView(every: task.isRunning ? 1 : 30) { now in
                content(task, now: now)
            }
        }
    }

    private func content(_ task: TaskItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            byKind(task, now: now)
            byDay(task, now: now)
            sessions(task, now: now)
        }
        .padding(16)
        .frame(width: 310, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // Body / Body revisions / Hooks / Hooks revisions
    private func byKind(_ task: TaskItem, now: Date) -> some View {
        let times = task.timeByKind(now: now)
        let kinds = StageKind.allCases.filter { times[$0] != nil }
        let longest = max(times.values.max() ?? 1, 1)
        let total = times.values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TIME BY TYPE")
            ForEach(kinds, id: \.self) { kind in
                let t = times[kind] ?? 0
                let count = (task.stages ?? []).filter { $0.kind == kind }.count
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(kind.groupTitle)
                        if kind == .bodyFix || kind == .hooksFix {
                            Text("\u{00D7}\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(t))
                            .monospacedDigit()
                        Text(total > 0 ? "\(Int((t / total * 100).rounded()))%" : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    ProgressBar(fraction: t / longest)
                }
            }
        }
    }

    private func byDay(_ task: TaskItem, now: Date) -> some View {
        let perDay = task.timePerDay(now: now).filter { $0.value >= 1 }
        let days = perDay.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("BY DAY")
            if days.isEmpty {
                Text("No time tracked yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { day in
                HStack {
                    Text(Calendar.current.isDateInToday(day) ? "Today"
                         : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
                    Text(task.stageTimes(on: day, now: now).map(\.stage.title).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatDuration(perDay[day] ?? 0))
                        .monospacedDigit()
                }
            }
        }
    }

    // Every start–stop, newest first; a session can be deleted
    private func sessions(_ task: TaskItem, now: Date) -> some View {
        let list = (task.sessions ?? []).sorted { $0.start > $1.start }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("WORK SESSIONS")
            if let start = task.startedAt {
                sessionRow(start: start, endText: "now", part: task.currentStage?.title ?? "",
                           duration: now.timeIntervalSince(start), running: true, manual: false, onDelete: nil)
            }
            if list.isEmpty && !task.isRunning {
                Text(task.elapsed() > 0 ? "This time was tracked before session history was added."
                                        : "No sessions yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(list) { s in
                sessionRow(start: s.start,
                           endText: s.end.formatted(date: .omitted, time: .shortened),
                           part: task.stageTitle(of: s),
                           duration: s.duration, running: false, manual: s.manual == true) {
                    store.confirmDeleteSession(task, s)
                }
            }
        }
    }

    private func sessionRow(start: Date, endText: String, part: String, duration: TimeInterval,
                            running: Bool, manual: Bool, onDelete: (() -> Void)?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))) · \(start.formatted(date: .omitted, time: .shortened)) – \(endText)")
                    .lineLimit(1)
                Text(manual ? "\(part) · added by hand" : part)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(running ? formatClock(duration) : formatDuration(duration))
                .monospacedDigit()
                .foregroundStyle(running ? Color.orange : Color.primary)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete this session")
            }
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

// Shows content that refreshes on a timer (for live times) and also right away whenever
// anything it uses changes. TimelineView only redraws on its own schedule, so a click
// could take up to a minute to show; this redraws immediately.
struct LiveView<Content: View>: View {
    let every: TimeInterval
    @ViewBuilder let content: (Date) -> Content
    @State private var tick = Date()

    var body: some View {
        let _ = tick   // redraw on every tick
        content(Date())
            .task(id: every) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                    tick = Date()
                }
            }
    }
}

// MARK: Entry panels (New Task, New Client, client lists)

extension View {
    // Text field look used in the entry panels
    func entryField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
    }

    // Rounded box around an entry panel
    func entryPanel() -> some View {
        self
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

// "⊕ New Task  for today"
struct PanelTitle: View {
    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// Small rounded option button: "👤 Siba ▾", "🔔 10:00"
struct Chip: View {
    let icon: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .opacity(0.6)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
        .contentShape(Capsule())
    }
}

// Title + text field + Add, in a rounded panel
struct EntryPanel: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle(icon: icon, title: title)
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .entryField()
                    .onSubmit(onAdd)
                Button(action: onAdd) {
                    Text("Add").fontWeight(.semibold).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .entryPanel()
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
            .frame(height: 300)

            EntryPanel(icon: "person.crop.circle.badge.plus", title: "New Client",
                       placeholder: "Client name, e.g. Siba", text: $newName, onAdd: addClient)
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
            .frame(height: 240)

            EntryPanel(icon: "text.badge.plus", title: "Add to \(client.name)'s list",
                       placeholder: "Task you often do, e.g. Body", text: $newTemplate) {
                addTemplate(to: client)
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

func clientDisplayName(_ name: String) -> String {
    name.isEmpty ? "No Client" : name
}

// Background of the cards in Reports
let reportCardBackground = Color(nsColor: .controlBackgroundColor)

// Everything Reports shows for one month (all clients, or one), calculated once
struct MonthSummary {
    struct TaskLine: Identifiable {
        let task: TaskItem
        let monthTime: TimeInterval        // time worked on it in this month
        let byKind: [StageKind: TimeInterval]   // all its time, per kind of part
        var id: UUID { task.id }
    }

    // One kind of part across the month's tasks: total, how many tasks had it, average per task
    struct PartLine: Identifiable {
        let kind: StageKind
        let total: TimeInterval
        let tasks: Int
        var average: TimeInterval { tasks > 0 ? total / Double(tasks) : 0 }
        var id: StageKind { kind }
    }

    struct ClientLine: Identifiable {
        let name: String
        let time: TimeInterval
        let tasks: Int
        var id: String { name }
    }

    let lines: [TaskLine]                  // tasks worked on or planned this month, most time first
    let clients: [ClientLine]              // most time first
    let perDay: [Date: TimeInterval]
    let perDayClients: [Date: [String: TimeInterval]]
    let days: [Date]                       // days with time, newest first
    let total: TimeInterval
    let longestDay: TimeInterval
    let done: Int
    let waiting: Int
    let working: Int
    let parts: [PartLine]                  // Body, Body revisions, Hooks, Hooks revisions

    func tasksWith(_ kind: StageKind) -> Int {
        parts.first { $0.kind == kind }?.tasks ?? 0
    }

    init(tasks: [TaskItem], month: Date, client: String?, now: Date) {
        let cal = Calendar.current
        let end = cal.date(byAdding: .month, value: 1, to: month) ?? month

        var lines: [TaskLine] = []
        var perDay: [Date: TimeInterval] = [:]
        var perDayClients: [Date: [String: TimeInterval]] = [:]
        var clientTime: [String: TimeInterval] = [:]
        var clientTasks: [String: Int] = [:]

        for task in tasks where client == nil || task.client == client {
            var monthTime: TimeInterval = 0
            for (day, t) in task.timePerDay(now: now) where day >= month && day < end {
                monthTime += t
                perDay[day, default: 0] += t
                perDayClients[day, default: [:]][task.client, default: 0] += t
            }
            let plannedThisMonth = task.day >= month && task.day < end
            guard monthTime >= 1 || plannedThisMonth else { continue }
            lines.append(TaskLine(task: task, monthTime: monthTime, byKind: task.timeByKind(now: now)))
            clientTime[task.client, default: 0] += monthTime
            clientTasks[task.client, default: 0] += 1
        }

        self.lines = lines.sorted {
            ($0.monthTime, $1.task.title.lowercased()) > ($1.monthTime, $0.task.title.lowercased())
        }
        self.clients = clientTasks.keys
            .map { ClientLine(name: $0, time: clientTime[$0] ?? 0, tasks: clientTasks[$0] ?? 0) }
            .sorted { ($0.time, $1.name.lowercased()) > ($1.time, $0.name.lowercased()) }
        self.perDay = perDay
        self.perDayClients = perDayClients
        self.days = perDay.keys.filter { (perDay[$0] ?? 0) >= 1 }.sorted(by: >)
        self.total = perDay.values.reduce(0, +)
        self.longestDay = max(perDay.values.max() ?? 1, 1)
        self.done = lines.filter { $0.task.status == .done }.count
        self.waiting = lines.filter { $0.task.isAwaitingReview }.count
        self.working = lines.filter { $0.task.isOpen }.count

        var partTotal: [StageKind: TimeInterval] = [:]
        var partTasks: [StageKind: Int] = [:]
        for line in lines {
            for (kind, t) in line.byKind {
                partTotal[kind, default: 0] += t
                partTasks[kind, default: 0] += 1
            }
        }
        self.parts = StageKind.allCases.compactMap { kind in
            guard let count = partTasks[kind] else { return nil }
            return PartLine(kind: kind, total: partTotal[kind] ?? 0, tasks: count)
        }
    }
}

// One row in the Reports sidebar: title on the left, time on the right
// A plain button (not a List selection, which didn't react to clicks here),
// highlighted by hand when selected
struct SidebarRow: View {
    let title: String
    let icon: String?
    let value: String
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor
                                 : (hovering ? Color.primary.opacity(0.07) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// What the Reports sidebar has selected
enum ReportsScope: Hashable {
    case all
    case client(String)
}

struct ReportsView: View {
    @EnvironmentObject var store: TaskStore

    @State private var selection: ReportsScope = .all
    @State private var month = startOfMonth(Date())
    @State private var weekStart = startOfWeek(Date())
    @State private var search = ""
    @State private var selectedTaskID: UUID?

    // nil = all clients (also when nothing is selected in the sidebar)
    private var client: String? {
        if case .client(let name) = selection { return name }
        return nil
    }

    // Live every second while a timer runs, otherwise once a minute
    private var refresh: TimeInterval {
        store.tasks.contains { $0.isRunning } ? 1 : 60
    }

    // Laid out by hand (sidebar | month | task panel): the system split view and
    // inspector cut the panel off and crashed when the window was resized
    var body: some View {
        HStack(spacing: 0) {
            // Updates whenever the tasks change
            sidebar(MonthSummary(tasks: store.tasks, month: month, client: nil, now: Date()))
                .frame(width: 230)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.03))
            Divider()
            LiveView(every: refresh) { now in
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    MonthDashboard(
                        summary: MonthSummary(tasks: store.tasks, month: month, client: client, now: now),
                        week: WeekSummary(tasks: store.tasks, weekStart: weekStart, client: client, now: now),
                        title: client.map(clientDisplayName) ?? "All Clients",
                        showClients: client == nil,
                        month: $month,
                        weekStart: $weekStart,
                        selectedTaskID: $selectedTaskID,
                        selectClient: { selection = .client($0) },
                        showAll: { selection = .all })
                } else {
                    SearchResultsView(query: search, now: now, selectedTaskID: $selectedTaskID)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            if let id = selectedTaskID {
                Divider()
                taskPanel(id)
                    .frame(width: 344)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        // Opened from "Task Report" on a task card in the menu bar
        .onAppear(perform: showRequestedTask)
        .onChange(of: store.reportTaskID) { _, _ in showRequestedTask() }
        // Another month: show its last week (or this week for the current month)
        .onChange(of: month) { _, newMonth in
            let cal = Calendar.current
            if cal.isDate(newMonth, equalTo: Date(), toGranularity: .month) {
                weekStart = startOfWeek(Date())
            } else if newMonth < Date() {
                let lastDay = cal.date(byAdding: DateComponents(month: 1, day: -1), to: newMonth) ?? newMonth
                weekStart = startOfWeek(lastDay)
            } else {
                weekStart = startOfWeek(newMonth)
            }
        }
        .toolbar { backupButtons }
        .frame(minWidth: 1100, minHeight: 640)
        // While Reports is open the app shows in the Dock and in Cmd+Tab, so the window
        // is easy to get back to after clicking somewhere else
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // The selected task: its card (with all the buttons) and its full statistics
    private func taskPanel(_ id: UUID) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Task Report")
                    .font(.headline)
                Spacer()
                Button {
                    selectedTaskID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TaskDetailView(taskID: id, day: Calendar.current.startOfDay(for: Date()),
                                   showReportButton: false) {
                        selectedTaskID = nil
                    }
                    Divider().padding(.horizontal, 16)
                    TaskStatsView(taskID: id)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tasks or clients", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sidebar(_ all: MonthSummary) -> some View {
        // Every client in the client list, plus names only used in tasks this month
        let names = Set(store.clients.map(\.name)).union(all.clients.map(\.name))
        let times = Dictionary(all.clients.map { ($0.name, $0.time) }, uniquingKeysWith: +)
        let sorted = names.sorted {
            ((times[$0] ?? 0), $1.lowercased()) > ((times[$1] ?? 0), $0.lowercased())
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                searchField
                    .padding(.bottom, 14)
                sidebarHeader(month.formatted(.dateTime.month(.wide).year().locale(appLocale)))
                SidebarRow(title: "All Clients", icon: "square.grid.2x2",
                           value: all.total > 0 ? formatDuration(all.total) : "–",
                           selected: selection == .all) {
                    selection = .all
                }
                sidebarHeader("Clients")
                    .padding(.top, 14)
                ForEach(sorted, id: \.self) { name in
                    let t = times[name] ?? 0
                    SidebarRow(title: clientDisplayName(name), icon: nil,
                               value: t > 0 ? formatDuration(t) : "–",
                               selected: selection == .client(name)) {
                        selection = .client(name)
                    }
                }
            }
            .padding(10)
        }
    }

    private func sidebarHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func showRequestedTask() {
        guard let id = store.reportTaskID else { return }
        search = ""
        selectedTaskID = id
        store.reportTaskID = nil
    }

    @ToolbarContentBuilder
    private var backupButtons: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.openBackupsFolder()
            } label: {
                Label("Automatic Backups", systemImage: "clock.arrow.circlepath")
            }
            .help("Open the folder with the automatic daily backups (last 30 days)")
            Button {
                store.importBackup()
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }
            .help("Import Backup")
            Button {
                store.exportBackup()
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            .help("Export Backup")
        }
    }
}

// One month: summary cards, time per client, the month's tasks, and time per day
struct MonthDashboard: View {
    let summary: MonthSummary
    let week: WeekSummary
    let title: String
    let showClients: Bool
    @Binding var month: Date
    @Binding var weekStart: Date
    @Binding var selectedTaskID: UUID?
    var selectClient: (String) -> Void
    var showAll: () -> Void

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statCards
                WeekCard(week: week, weekStart: $weekStart)
                if !summary.parts.isEmpty {
                    partsCard
                }
                if showClients && !summary.clients.isEmpty {
                    clientsCard
                }
                tasksCard
                if !summary.days.isEmpty {
                    daysCard
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // "All Clients" with the month switcher on the right
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                if !showClients {
                    Button(action: showAll) {
                        Label("All Clients", systemImage: "chevron.left")
                    }
                    .buttonStyle(.link)
                }
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: exportCSV) {
                    Label("Export CSV", systemImage: "tablecells")
                }
                .buttonStyle(.bordered)
                .help("Save this month's tasks as a spreadsheet (opens in Excel or Numbers)")
                .padding(.trailing, 10)
                if !isCurrentMonth {
                    Button("This Month") { month = startOfMonth(Date()) }
                        .buttonStyle(.link)
                        .padding(.trailing, 6)
                }
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                Text(month.formatted(.dateTime.month(.wide).year().locale(appLocale)))
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 140)
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }

    // One row per task: client, day, status, minutes per kind of part, this month and total
    private func exportCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let monthText = month.formatted(.iso8601.year().month())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Taskovi \(title) \(monthText).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func field(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func minutes(_ t: TimeInterval) -> String { "\(Int((t / 60).rounded()))" }

        let kinds = StageKind.allCases
        var rows: [[String]] = [
            ["Task", "Client", "Planned day", "Status"]
            + kinds.map { "\($0.groupTitle) (min)" }
            + ["This month (min)", "This month", "Total (min)", "Total"]
        ]
        for line in summary.lines {
            let task = line.task
            let total = task.elapsed()
            rows.append([task.title, clientDisplayName(task.client),
                         task.day.formatted(.iso8601.year().month().day()), task.progressTitle]
                        + kinds.map { minutes(line.byKind[$0] ?? 0) }
                        + [minutes(line.monthTime), formatDuration(line.monthTime),
                           minutes(total), formatDuration(total)])
        }
        let monthTotal = summary.lines.reduce(0) { $0 + $1.monthTime }
        rows.append(["Total", "", "", ""] + kinds.map { _ in "" }
                    + [minutes(monthTotal), formatDuration(monthTotal), "", ""])

        // BOM so Excel reads letters like č and ć correctly
        let csv = "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the CSV file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private var statCards: some View {
        let count = summary.days.count
        let average = count > 0 ? summary.total / Double(count) : 0
        let daysText = count == 0 ? "No days worked"
            : "\(count == 1 ? "1 day" : "\(count) days") · \(formatDuration(average)) a day"

        return HStack(spacing: 12) {
            StatCard(icon: "timer", color: .accentColor, title: "Time worked",
                     value: summary.total > 0 ? formatDuration(summary.total) : "–",
                     detail: daysText)
            StatCard(icon: "checkmark.circle.fill", color: .green, title: "Done",
                     value: "\(summary.done)", detail: summary.done == 1 ? "task finished" : "tasks finished")
            StatCard(icon: "paperplane.circle.fill", color: .blue, title: "Waiting for review",
                     value: "\(summary.waiting)", detail: "sent, no answer yet")
            StatCard(icon: "circle.lefthalf.filled", color: .orange, title: "In progress",
                     value: "\(summary.working)", detail: "still to work on")
        }
    }

    // How long each kind of part takes on average, and how often revisions come back
    private var partsCard: some View {
        let bodyTasks = summary.tasksWith(.body)
        let hooksTasks = summary.tasksWith(.hooks)
        var notes: [String] = []
        if bodyTasks > 0 {
            notes.append("\(summary.tasksWith(.bodyFix)) of \(bodyTasks) bodies got a revision")
        }
        if hooksTasks > 0 {
            notes.append("\(summary.tasksWith(.hooksFix)) of \(hooksTasks) hooks got a revision")
        }

        return ReportCard(title: "By Part", trailing: "tasks of this month") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Part")
                    Spacer()
                    Text("Tasks").frame(width: 60, alignment: .trailing)
                    Text("Total").frame(width: 80, alignment: .trailing)
                    Text("Average per task").frame(width: 120, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                ForEach(summary.parts) { part in
                    HStack(spacing: 12) {
                        Text(part.kind.groupTitle)
                        Spacer()
                        Text("\(part.tasks)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Text(formatDuration(part.total))
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                        Text(formatDuration(part.average))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(width: 120, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                }
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
    }

    // Each client's share of the month
    private var clientsCard: some View {
        let longest = max(summary.clients.map(\.time).max() ?? 1, 1)
        return ReportCard(title: "By Client") {
            VStack(spacing: 2) {
                ForEach(summary.clients) { c in
                    Button {
                        selectClient(c.name)
                    } label: {
                        HStack(spacing: 12) {
                            Text(clientDisplayName(c.name))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            ProgressBar(fraction: c.time / longest)
                            Text(c.time > 0 ? formatDuration(c.time) : "–")
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Text(c.tasks == 1 ? "1 task" : "\(c.tasks) tasks")
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tasksCard: some View {
        ReportCard(title: "Tasks", trailing: summary.lines.isEmpty ? nil : "\(summary.lines.count)") {
            if summary.lines.isEmpty {
                Text("No tasks this month.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    TaskColumnsHeader(firstTime: "This month", secondTime: "Total")
                    ForEach(summary.lines) { line in
                        TaskReportRow(task: line.task,
                                      firstTime: line.monthTime,
                                      secondTime: line.task.elapsed(),
                                      showClient: showClients,
                                      selected: selectedTaskID == line.task.id) {
                            selectedTaskID = line.task.id
                        }
                    }
                }
            }
        }
    }

    private var daysCard: some View {
        ReportCard(title: "By Day") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.days, id: \.self) { day in
                    DayReportRow(day: day,
                                 total: summary.perDay[day] ?? 0,
                                 longest: summary.longestDay,
                                 clients: showClients ? (summary.perDayClients[day] ?? [:]) : [:])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// Time worked in one week (Monday to Sunday), for all clients or one
struct WeekSummary {
    let start: Date
    let days: [Date]                   // Monday … Sunday
    let perDay: [Date: TimeInterval]
    let total: TimeInterval
    let daysWorked: Int                // days with at least a minute
    let average: TimeInterval          // per day worked
    let longest: TimeInterval

    init(tasks: [TaskItem], weekStart: Date, client: String?, now: Date) {
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let end = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart

        var perDay: [Date: TimeInterval] = [:]
        for task in tasks where client == nil || task.client == client {
            for (day, t) in task.timePerDay(now: now) where day >= weekStart && day < end {
                perDay[day, default: 0] += t
            }
        }

        let total = perDay.values.reduce(0, +)
        let daysWorked = perDay.values.filter { $0 >= 60 }.count
        self.start = weekStart
        self.days = days
        self.perDay = perDay
        self.total = total
        self.daysWorked = daysWorked
        self.average = daysWorked > 0 ? total / Double(daysWorked) : 0
        self.longest = max(perDay.values.max() ?? 1, 1)
    }
}

// One week: total, days worked, average per day, and a bar for each day
struct WeekCard: View {
    let week: WeekSummary
    @Binding var weekStart: Date

    private var cal: Calendar { Calendar.current }

    private var isThisWeek: Bool {
        cal.isDate(weekStart, inSameDayAs: startOfWeek(Date()))
    }

    // "Oct 5 – 11" or "Sep 29 – Oct 5"
    private var rangeText: String {
        let last = week.days.last ?? weekStart
        let first = weekStart.formatted(.dateTime.month(.abbreviated).day().locale(appLocale))
        let sameMonth = cal.isDate(weekStart, equalTo: last, toGranularity: .month)
        let end = sameMonth ? last.formatted(.dateTime.day().locale(appLocale))
                            : last.formatted(.dateTime.month(.abbreviated).day().locale(appLocale))
        return "\(first) – \(end)"
    }

    private func shift(_ weeks: Int) {
        weekStart = cal.date(byAdding: .day, value: 7 * weeks, to: weekStart) ?? weekStart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 28) {
                metric("Total", week.total > 0 ? formatDuration(week.total) : "–")
                metric("Days worked", "\(week.daysWorked) of 7")
                metric("Average per day worked", week.average > 0 ? formatDuration(week.average) : "–")
                Spacer(minLength: 0)
            }
            bars
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reportCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(isThisWeek ? "This Week" : "Week").font(.headline)
            Text(rangeText).foregroundStyle(.secondary)
            Spacer()
            if !isThisWeek {
                Button("This Week") { weekStart = startOfWeek(Date()) }
                    .buttonStyle(.link)
                    .padding(.trailing, 4)
            }
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 22, height: 22)
            }
            .help("Previous week")
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").frame(width: 22, height: 22)
            }
            .help("Next week")
        }
        .buttonStyle(.borderless)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    // Monday … Sunday, today highlighted
    private var bars: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(week.days, id: \.self) { day in
                let t = week.perDay[day] ?? 0
                let isToday = cal.isDateInToday(day)
                VStack(spacing: 5) {
                    Text(t >= 60 ? formatDuration(t) : "")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(t >= 60 ? Color.accentColor.opacity(isToday ? 1 : 0.6) : Color.primary.opacity(0.08))
                        .frame(height: t >= 60 ? max(6, 90 * t / week.longest) : 4)
                    Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)))
                        .font(.caption.weight(isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                    Text(day.formatted(.dateTime.day().locale(appLocale)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150, alignment: .bottom)
    }
}

// Search across every month: find a task fast, then click it to change its status
struct SearchResultsView: View {
    let query: String
    let now: Date
    @Binding var selectedTaskID: UUID?
    @EnvironmentObject var store: TaskStore

    var body: some View {
        let results = store.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(results.isEmpty ? "No tasks found"
                                     : (results.count == 1 ? "1 task found" : "\(results.count) tasks found"))
                    .font(.largeTitle.bold())
                Text("Searching all months for \u{201C}\(query)\u{201D}")
                    .foregroundStyle(.secondary)
                if !results.isEmpty {
                    ReportCard(title: "Results") {
                        VStack(spacing: 0) {
                            TaskColumnsHeader(firstTime: "Total", secondTime: nil)
                            ForEach(results) { task in
                                TaskReportRow(task: task,
                                              firstTime: task.elapsed(at: now),
                                              secondTime: nil,
                                              showClient: true,
                                              selected: selectedTaskID == task.id) {
                                    selectedTaskID = task.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// A rounded card with a title, used for every section in Reports
struct ReportCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reportCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

// Small summary card: icon, title, big number, explanation
struct StatCard: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reportCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25)))
    }
}

// Horizontal bar, full width = 1.0
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

// Column titles above the task rows
struct TaskColumnsHeader: View {
    let firstTime: String
    let secondTime: String?

    var body: some View {
        HStack(spacing: 12) {
            Text("Task").padding(.leading, 30)
            Spacer()
            Text("Status").frame(width: 150, alignment: .leading)
            Text(firstTime).frame(width: 80, alignment: .trailing)
            if let secondTime {
                Text(secondTime).frame(width: 70, alignment: .trailing)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

// One task in Reports; click it to open its card on the right
struct TaskReportRow: View {
    let task: TaskItem
    let firstTime: TimeInterval
    let secondTime: TimeInterval?
    let showClient: Bool
    let selected: Bool
    var onSelect: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        var parts: [String] = []
        if showClient { parts.append(clientDisplayName(task.client)) }
        parts.append(task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.progressIcon)
                .font(.system(size: 16))
                .foregroundStyle(task.progressColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(task.progressTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(task.progressColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(task.progressColor.opacity(0.14), in: Capsule())
                .frame(width: 150, alignment: .leading)
            Text(timeText(firstTime))
                .monospacedDigit()
                .foregroundStyle(task.isRunning ? Color.orange : Color.primary)
                .frame(width: 80, alignment: .trailing)
            if let secondTime {
                Text(timeText(secondTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15)
                             : (hovering ? Color.primary.opacity(0.05) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }

    private func timeText(_ t: TimeInterval) -> String {
        t >= 60 ? formatDuration(t) : (t > 0 ? "<1m" : "–")
    }
}

// One day in "By Day": date, bar, total, and time per client
struct DayReportRow: View {
    let day: Date
    let total: TimeInterval
    let longest: TimeInterval
    let clients: [String: TimeInterval]

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private var dateText: String {
        day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale))
    }

    private var clientsText: String {
        clients
            .sorted { $0.value > $1.value }
            .map { "\(clientDisplayName($0.key)) \(formatDuration($0.value))" }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(isToday ? "Today" : dateText)
                .fontWeight(isToday ? .semibold : .regular)
                .frame(width: 100, alignment: .leading)
            ProgressBar(fraction: total / longest)
                .frame(width: 200)
            Text(formatDuration(total))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(clientsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
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
        .defaultSize(width: 1240, height: 780)
        .defaultLaunchBehavior(.suppressed)
    }

    private func menuBarImage() -> Image {
        Image(nsImage: makeMenuBarIcon())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Clicking the Dock icon (shown while Reports is open) brings Reports to the front
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSApp.windows.first(where: isReportsWindow), window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return false
    }

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
