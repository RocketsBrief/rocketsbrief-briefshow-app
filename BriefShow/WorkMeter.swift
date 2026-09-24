//
//  WorkMeter.swift
//  BriefShow
//
//  One bar for every wait — asked for 24.09: *„neki put cekam secund 2 ili tri
//  cak i vise … i ne vidim da se nista desava … treba za svko cekanje da
//  dobije loading bar … jedan loading bar za sveee … dok se radi a nije
//  zavrseno loading bar real time!!!"*.
//
//  Every piece of background work the editor does goes through `tracked` on its
//  queue, which signs it in when it is queued and out when it has run. The bar
//  beside the file name shows the biggest thing still running.
//
//  ⚠️ HOW FULL, when the work cannot say. A render is one Core Image call with
//  no progress of its own, so the bar fills against how long the SAME kind of
//  work took the last times on THIS Mac (an average it keeps learning, saved
//  between launches), and holds at 95 % until the work really ends — then it
//  jumps to 100 % and goes. It never claims done before done.
//
//  ⚠️ AND IT NEVER REDRAWS THE EDITOR. Everything published here is read only
//  by `WorkMeterBar`, which observes this object on its own — the ActiveStroke
//  rule. A 20 Hz tick that invalidated DevelopView would be the lag it reports.
//

import SwiftUI
import Combine

final class WorkMeter: ObservableObject {
    static let shared = WorkMeter()

    @Published private(set) var label: String = ""
    @Published private(set) var fraction: Double = 0
    @Published private(set) var isVisible = false
    @Published private(set) var others = 0

    private struct Job { let label: String; let shown: String; let started: Date; let expected: Double }

    /// The editor keeping its picture up to date — asked for 25.09: *„umesto da
    /// se zove loading sharp view, da ima vise naziva ali skracenih … randomly"*.
    /// These three are the same thing to the client (the picture catching up),
    /// so the bar says a word from this list instead. Picked ONCE per job, when
    /// it begins — the word does not change under a running bar, and the cost
    /// is one random index. Every other wait keeps its real name (Opening photo,
    /// Exporting, AI Clean Up…): there the client needs to know what it is.
    static let playfulLabels: Set<String> = ["Rendering", "Updating view", "Loading sharp view"]
    static let playfulWords = [
        "Pontificating", "Working", "Deliberating", "Ruminating", "Contemplating",
        "Dissecting", "Formulating", "Executing", "Iterating", "Grinding",
        "Hammering away", "Tinkering", "Elaborating", "Noodling", "Discourse-building",
        "Pondering", "Honing", "Drafting", "Exploring", "Structuring", "Mapping out", "Polishing",
    ]
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var nextToken = 0
    private var learned: [String: Double]
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var lastSaved = Date.distantPast

    /// Work shorter than this never shows a bar — a flicker is worse than nothing.
    static let showAfter: TimeInterval = 0.15

    private static let defaultsKey = "workMeter.learned"
    private static let firstGuess: [String: Double] = [
        "Rendering": 0.3, "Updating view": 0.25, "Opening photo": 1.5, "Loading sharp view": 1.0,
        "AI Clean Up": 8, "Exporting": 5, "Background preview": 0.4
    ]

    private init() {
        learned = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
    }

    func begin(_ label: String) -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        let expected = learned[label] ?? Self.firstGuess[label] ?? 3
        let shown = Self.playfulLabels.contains(label)
            ? (Self.playfulWords.randomElement() ?? label) : label
        jobs[token] = Job(label: label, shown: shown, started: Date(), expected: max(expected, 0.1))
        lock.unlock()
        onMain { self.startTicking() }
        return token
    }

    func end(_ token: Int) {
        lock.lock()
        if let job = jobs.removeValue(forKey: token) {
            // Learn: three parts old, one part new.
            let took = Date().timeIntervalSince(job.started)
            let old = learned[job.label] ?? took
            learned[job.label] = old * 0.75 + took * 0.25
        }
        let empty = jobs.isEmpty
        let snapshot = learned
        lock.unlock()
        if empty {
            onMain {
                // At most every 5 s: a slider drag ends thirty renders a second.
                if Date().timeIntervalSince(self.lastSaved) > 5 {
                    self.lastSaved = Date()
                    UserDefaults.standard.set(snapshot, forKey: Self.defaultsKey)
                }
                self.finish()
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func startTicking() {
        hideWork?.cancel()
        hideWork = nil
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        lock.lock()
        let running = jobs.values
        lock.unlock()
        guard let main = running.max(by: { $0.expected < $1.expected }) else { return }
        let oldest = running.map(\.started).min() ?? main.started
        guard Date().timeIntervalSince(oldest) >= Self.showAfter else { return }
        let elapsed = Date().timeIntervalSince(main.started)
        let value = min(elapsed / main.expected, 0.95)
        if !isVisible { isVisible = true }
        if label != main.shown { label = main.shown }
        if abs(value - fraction) > 0.004 { fraction = value }
        if others != running.count - 1 { others = running.count - 1 }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        guard isVisible else {
            fraction = 0
            return
        }
        fraction = 1
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isVisible = false
            self.fraction = 0
            self.others = 0
        }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: hide)
    }
}

extension DispatchQueue {
    /// `async`, signed in to the WorkMeter for as long as it is queued and running.
    func tracked(_ label: String, qos: DispatchQoS = .unspecified, execute work: @escaping () -> Void) {
        let token = WorkMeter.shared.begin(label)
        async(qos: qos) {
            defer { WorkMeter.shared.end(token) }
            work()
        }
    }

    /// The same for a cancellable work item: a cancelled one signs out without running.
    func tracked(_ label: String, item: DispatchWorkItem) {
        let token = WorkMeter.shared.begin(label)
        async {
            defer { WorkMeter.shared.end(token) }
            if !item.isCancelled { item.perform() }
        }
    }
}

/// The bar beside the file name: what is being done, and how far.
struct WorkMeterBar: View {
    @ObservedObject var meter = WorkMeter.shared
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            if meter.isVisible {
                Text(caption)
                    .font(.custom("Figtree", size: 10.5).weight(.medium))
                    .foregroundColor(AppColors.muted)
                    .lineLimit(1)
                    .fixedSize()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColors.border.opacity(0.6))
                        Capsule().fill(tint)
                            .frame(width: proxy.size.width * meter.fraction)
                    }
                }
                .frame(height: 5)
                .animation(.linear(duration: 0.1), value: meter.fraction)
            }
        }
        .frame(height: 16)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: meter.isVisible)
    }

    private var caption: String {
        let percent = Int((meter.fraction * 100).rounded(.down))
        return meter.others > 0
            ? "\(meter.label) \(percent)% · +\(meter.others)"
            : "\(meter.label) \(percent)%"
    }
}
