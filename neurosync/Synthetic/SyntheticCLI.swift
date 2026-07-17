//
//  SyntheticCLI.swift
//  neurosync
//
//  `neurosync --generate-synthetic` — build the two synthetic days, write them, exit.
//
//  Exists so the day can be regenerated without a GUI click, and so CI/snapshot work has a way in.
//  It is an explicit, named, opt-in command. It is NOT wired to launch, to first run, or to the
//  empty state. Nothing generates data because a folder happened to be empty.
//

import Foundation

@MainActor
enum SyntheticCLI {
    static let flag = "--generate-synthetic"

    static var requested: Bool { CommandLine.arguments.contains(flag) }

    static func run() -> Never {
        let store = Store()

        guard store.hasLocation else {
            FileHandle.standardError.write(Data("""
            neurosync: cannot reach \(Store.preferredRoot.path).

            The sandbox refused it and there is no granted bookmark. Launch the app, open DAY, and
            use "Choose folder…" once — the grant is remembered.

            """.utf8))
            exit(1)
        }

        print("neurosync: generating two synthetic days → \(store.root?.path ?? "?")")
        print("neurosync: waveforms are generated; every score is computed by the real DSP.\n")

        let started = Date()
        let records = generateSyntheticDays()

        for r in records {
            do {
                let url = try store.write(r)
                let states = Dictionary(grouping: r.epochs, by: \.state).mapValues(\.count)
                let summary = BrainState.allCases
                    .compactMap { s in states[s].map { "\(s.rawValue) \($0)s" } }
                    .joined(separator: "  ")

                print(String(
                    format: "  %@  %5.0f min  %3.0f%% coverage  %@",
                    ISO8601DateFormatter().string(from: r.startedAt),
                    r.duration / 60,
                    r.coverage * 100,
                    summary
                ))
                print("    → \(url.lastPathComponent)")
            } catch {
                FileHandle.standardError.write(Data("  FAILED: \(error)\n".utf8))
                exit(1)
            }
        }

        print(String(format: "\nneurosync: %d sessions in %.1fs.", records.count, Date().timeIntervalSince(started)))
        exit(0)
    }
}
