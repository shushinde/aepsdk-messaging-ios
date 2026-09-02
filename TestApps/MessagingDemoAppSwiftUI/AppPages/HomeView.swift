/*
Copyright 2023 Adobe. All rights reserved.
This file is licensed to you under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License. You may obtain a copy
of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under
the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
OF ANY KIND, either express or implied. See the License for the specific language
governing permissions and limitations under the License.
*/

import AEPMessaging
import AEPCore
import AEPEdge
import AEPServices
import SwiftUI
import SQLite3

struct HomeView: View {
    @State private var viewDidLoad = false

    var body: some View {
        TabView {
            InAppView()
                .tabItem {
                    Label("InApp", systemImage: "doc.richtext.fill")
                }
            CardsView()
                .tabItem {
                    Label("Cards", systemImage: "rectangle.on.rectangle")
                }
            InboxView()
                .tabItem {
                    Label("Inbox", systemImage: "tray.fill")
                }
            LiveActivityView()
                .tabItem {
                    Label("Live Activity", systemImage: "app.badge")
                }
            CodeBasedView()
                .tabItem {
                    Label("Code Experiences", systemImage: "newspaper.fill")
                }
            PushView()
                .tabItem {
                    Label("Push", systemImage: "paperplane.fill")
                }
            PerformanceView()
                .tabItem {
                    Label("Performance", systemImage: "speedometer")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}

/// End to end disk I/O performance harness for the WAL change.
///
/// Real send: fires N Edge experience events through the real pipeline
/// (enqueue to the com.adobe.edge DataQueue, process, network, dequeue).
/// Queue only: an isolated offline queue doing add, peek, remove per event,
/// which is deterministic and hits no network.
///
/// Build the app once against the local Core (WAL) and once against the
/// remote Core (no WAL), and compare disk I/O in Instruments.
struct PerformanceView: View {
    @State private var countText = "5000"
    @State private var realSend = true
    @State private var running = false
    @State private var output = "Set N, pick a mode, then Send."

    // Real send tracking (read only, off the write path).
    @State private var enqueued = 0
    @State private var baselineDepth = 0
    @State private var expectedPeak = 0

    private let isolatedLabel = "perf.messaging.test"
    private let edgeLabel = "com.adobe.edge"

    private var n: Int { max(1, Int(countText) ?? 0) }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Simulation")) {
                    HStack {
                        Text("Events (N)")
                        Spacer()
                        TextField("count", text: $countText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    Toggle("Real send (Edge network)", isOn: $realSend)
                    Text(realSend
                         ? "Fires N Edge experience events end to end: enqueue, process, network, dequeue. The timer covers enqueue only; draining continues in the background. Read the disk deltas in Instruments."
                         : "Offline write load on an isolated queue, doing add, peek, remove per event. Deterministic disk I/O, no network.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Button(running ? "Running..." : "Send \(n) Events") { run() }
                        .disabled(running)
                    Button("Check sent status") { checkSent() }
                        .disabled(running || !realSend)
                    Button("Clear test queue") { clearQueue() }
                        .disabled(running || realSend)
                    Button("Check file protection") { checkProtection() }
                        .disabled(running)
                }
                Section(header: Text("Result")) {
                    Text(output).font(.system(.footnote, design: .monospaced))
                }
            }
            .navigationTitle("Performance")
        }
    }

    private func run() {
        running = true
        let count = n
        let real = realSend
        output = "Running \(real ? "real send" : "queue only") x\(count)..."
        DispatchQueue.global(qos: .userInitiated).async {
            let base = real ? edgeQueueDepth() : 0   // pending before this run
            let start = Date()
            if real {
                for i in 0 ..< count {
                    let event = ExperienceEvent(xdm: ["eventType": "perf.test", "index": i])
                    Edge.sendEvent(experienceEvent: event)
                }
            } else {
                let queue = ServiceProvider.shared.dataQueueService.getDataQueue(label: isolatedLabel)!
                for i in 0 ..< count {
                    _ = queue.add(dataEntity: DataEntity(data: Data("payload-\(i)".utf8))) // write
                    _ = queue.peek()                                                       // read
                    _ = queue.remove()                                                     // write
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            let inspected = inspect(label: real ? edgeLabel : isolatedLabel)
            DispatchQueue.main.async {
                running = false
                if real {
                    baselineDepth = base
                    enqueued = count
                    expectedPeak = base + count
                }
                output = """
                mode: \(real ? "real send (Edge)" : "queue only")
                events: \(count)
                \(real ? "enqueue time" : "time"): \(String(format: "%.3f", elapsed)) s
                \(inspected)
                \(real ? "Tap Check sent status to watch them drain." : "")
                """
            }
        }
    }

    /// Reads how many of the enqueued events have drained (been sent). Read only, no writes.
    private func checkSent() {
        let pending = edgeQueueDepth()
        let sent = max(0, min(enqueued, expectedPeak - pending))
        let allSent = pending <= baselineDepth
        output = """
        real send status
        enqueued: \(enqueued)
        sent (drained): \(sent)
        still pending: \(max(0, pending - baselineDepth))
        all sent: \(enqueued == 0 ? "n/a" : (allSent ? "YES" : "no"))
        """
    }

    private func edgeQueueDepth() -> Int {
        ServiceProvider.shared.dataQueueService.getDataQueue(label: edgeLabel)?.count() ?? -1
    }

    /// Reads the on disk file protection class of every SDK database plus its -wal and -shm sidecars.
    /// The SDK sets these files per file, so they should stay CompleteUntilFirstUserAuthentication
    /// even when the host app default is Complete. A control file the app writes itself inherits the
    /// host default, which proves the per file override is real.
    private func checkProtection() {
        let fm = FileManager.default
        var lines: [String] = []

        func shortName(_ raw: String?) -> String {
            guard let raw = raw else { return "nil" }
            return raw.replacingOccurrences(of: "NSFileProtection", with: "")
        }
        func report(_ base: URL, _ tag: String) {
            for suffix in ["", "-wal", "-shm"] {
                let path = base.path + suffix
                guard fm.fileExists(atPath: path) else { continue }
                let cls = (try? fm.attributesOfItem(atPath: path))?[.protectionKey] as? FileProtectionType
                lines.append("\(tag)\(suffix.isEmpty ? "" : suffix): \(shortName(cls?.rawValue))")
            }
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        report(appSupport.appendingPathComponent("com.adobe.aep.db").appendingPathComponent("com.adobe.eventHistory"), "eventHistory")

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["com.adobe.module.identity", "com.adobe.module.signal", "com.adobe.edge"] {
            report(caches.appendingPathComponent(name), name)
        }

        // Control: a file the app writes itself. Should inherit the host default (Complete).
        let control = caches.appendingPathComponent("perf.control.txt")
        try? Data("x".utf8).write(to: control)
        let controlCls = (try? fm.attributesOfItem(atPath: control.path))?[.protectionKey] as? FileProtectionType
        lines.append("control (app file): \(shortName(controlCls?.rawValue))")

        output = lines.isEmpty
            ? "No SDK db files found yet. Send some events first."
            : "file protection\n" + lines.joined(separator: "\n")
    }

    private func clearQueue() {
        _ = ServiceProvider.shared.dataQueueService.getDataQueue(label: isolatedLabel)?.clear()
        output = "Cleared \(isolatedLabel)."
    }

    /// Reads queue depth and the on disk journal mode for the inspected label.
    private func inspect(label: String) -> String {
        let depth = ServiceProvider.shared.dataQueueService.getDataQueue(label: label)?.count() ?? -1
        let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let dbPath = caches?.appendingPathComponent(label).path ?? ""
        let walExists = FileManager.default.fileExists(atPath: dbPath + "-wal")

        var mode = "unknown"
        var handle: OpaquePointer?
        if sqlite3_open(dbPath, &handle) == SQLITE_OK {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, "PRAGMA journal_mode;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { mode = String(cString: c) }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(handle)
        }
        return "queue: \(label)\ndepth: \(depth)   journal_mode: \(mode)   wal: \(walExists ? "present" : "absent")"
    }
}
