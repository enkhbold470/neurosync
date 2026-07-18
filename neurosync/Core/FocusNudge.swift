//
//  FocusNudge.swift
//  neurosync
//
//  "You're crashing out — take a break." A live nudge that watches the focus score and, when it
//  stays deep below your baseline, flags it on the Dock.
//
//  Pure and nonisolated so the escalation logic is tested without a radio or a Dock. Two honesty
//  rules are baked in and must stay:
//
//   1. ONLY TRUSTWORTHY FOCUS FEEDS IT. A withheld second (electrode off, calibrating, bad rate) is
//      never a "low focus" second — it is no data. The caller must gate before calling `sample`, and
//      `reset()` on signal loss / disconnect so a frozen score can't strand a stale nudge on the Dock.
//   2. IT MUST BE SUSTAINED, NOT A BLINK. A single dip under 20 is noise; a blink or a swallow can do
//      it. The nudge only fires after the score has held low for `sustainSec`, and only clears once it
//      climbs back above a higher line (`clearAbove`) — hysteresis, so the Dock badge doesn't strobe.
//

import Foundation

nonisolated struct FocusNudge: Equatable {
    enum Level: Int, Comparable, Sendable {
        case none = 0     // fine
        case breather = 1 // focus < breatherBelow, sustained → suggest a 5-minute break
        case walk = 2     // focus < walkBelow, sustained → suggest a 10-minute walk

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        /// Dock badge — short, glanceable. The full suggestion is `message`.
        var badge: String? {
            switch self {
            case .none: return nil
            case .breather: return "!"
            case .walk: return "!!"
            }
        }

        var message: String? {
            switch self {
            case .none: return nil
            case .breather: return "You've been under your line a while — a 5-minute reset usually brings it back."
            case .walk: return "Still low — a short walk is the fastest way back in."
            }
        }

        var icon: String {
            switch self {
            case .none: return "checkmark.circle"
            case .breather: return "cup.and.saucer.fill"
            case .walk: return "figure.walk"
            }
        }
    }

    // Thresholds on the 0–100 score (50 == your own baseline).
    var breatherBelow = 20.0
    var walkBelow = 10.0
    /// Must climb back above this to clear — above both thresholds, so recovery is unambiguous.
    var clearAbove = 30.0
    /// How long the score must hold low before the nudge fires.
    var sustainSec = 45.0

    private(set) var level: Level = .none
    private var lowFor = 0.0    // seconds continuously under breatherBelow
    private var deepFor = 0.0   // seconds continuously under walkBelow

    /// Feed one TRUSTWORTHY focus sample, `dt` seconds after the last. Returns the new level.
    mutating func sample(focus: Double, dt: Double) -> Level {
        let d = max(0, dt)

        if focus < walkBelow { deepFor += d } else { deepFor = 0 }
        if focus < breatherBelow { lowFor += d } else { lowFor = 0 }

        if focus >= clearAbove {
            level = .none                       // clearly recovered
        } else if deepFor >= sustainSec {
            level = .walk                        // deep and sustained
        } else if lowFor >= sustainSec {
            level = .breather                    // low and sustained (also the walk→breather climb-out)
        }
        // Otherwise (between breatherBelow and clearAbove, not yet sustained): HOLD — hysteresis.
        return level
    }

    /// No live signal → no live nudge. Call on disconnect or sustained signal loss.
    mutating func reset() {
        level = .none
        lowFor = 0
        deepFor = 0
    }
}
