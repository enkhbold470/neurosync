//
//  DayView.swift
//  neurosync
//
//  The day. What you did, what your brain did, and where the two disagree.
//

import SwiftUI

struct DayView: View {
    let model: DayModel

    var body: some View {
        Group {
            if !model.hasLocation {
                GrantFolder(model: model)
            } else if let day = model.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        DayHeader(model: model, day: day)

                        VStack(alignment: .leading, spacing: 14) {
                            Panel(title: "TIMELINE", trailing: coverageLabel(day)) {
                                DayRibbon(day: day)
                                StateLegend()
                            }

                            FindingsPanel(day: day)
                            SegmentsPanel(day: day)

                            HStack(alignment: .top, spacing: 14) {
                                StrainPanel(day: day)
                                RecoveryPanel(day: day)
                            }
                            HStack(alignment: .top, spacing: 14) {
                                BergerPanelDay(day: day)
                                BrainAgePanel()
                            }
                        }
                        // Applied at the ROOT of the day, so nothing inside can escape the hatch.
                        .syntheticWatermark(day.synthetic)
                    }
                    .padding(14)
                }
            } else {
                EmptyDay(model: model)
            }
        }
        .background(Ink.bg)
    }

    private func coverageLabel(_ day: Day) -> String {
        String(format: "%.0f%% coverage · %d session%@",
               day.coverage * 100, day.sessions.count, day.sessions.count == 1 ? "" : "s")
    }
}

// MARK: - Header

private struct DayHeader: View {
    let model: DayModel
    let day: Day

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.days) { d in
                Button {
                    model.select(d.key)
                } label: {
                    HStack(spacing: 5) {
                        Text(dayLabel(d))
                            .font(.data(10, d.key == day.key ? .bold : .regular))
                        if d.synthetic { SyntheticBadge() }
                    }
                    .foregroundStyle(d.key == day.key ? Ink.bg : Ink.dim)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(d.key == day.key ? Ink.amber : Color.clear)
                    .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(model.rootPath.replacingOccurrences(of: Store.realHome.path, with: "~"))
                .font(.data(9))
                .foregroundStyle(Ink.muted)

            Button("Reveal") { model.revealInFinder() }
                .buttonStyle(InstrumentButton())
        }
    }

    private func dayLabel(_ d: Day) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d.date) { return "TODAY" }
        if cal.isDateInYesterday(d.date) { return "YESTERDAY" }
        return d.key
    }
}

// MARK: - Legend

private struct StateLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(BrainState.allCases, id: \.self) { s in
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(Ink.state(s))
                        .frame(width: 9, height: 9)
                        .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    Text(s.label)
                        .font(.data(8))
                        .tracking(0.8)
                        .foregroundStyle(Ink.muted)
                }
                .help(s.meaning)
            }
            Spacer()
        }
    }
}

// MARK: - Findings

private struct FindingsPanel: View {
    let day: Day

    var body: some View {
        Panel(title: "FINDINGS", trailing: "\(day.findings.count)") {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(day.findings) { f in
                    HStack(alignment: .top, spacing: 9) {
                        Rectangle()
                            .fill(Ink.tone(f.tone))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.headline)
                                .font(.label(12, .semibold))
                                .foregroundStyle(Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(f.caveat)
                                .font(.label(11))
                                .foregroundStyle(Ink.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Ink.rule)

                // Printed under every findings list, always. It is not a disclaimer to be dismissed;
                // it is the strongest true statement the data supports.
                Text(confoundFooter)
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Segments

private struct SegmentsPanel: View {
    let day: Day

    var body: some View {
        Panel(title: "BLOCKS", trailing: "median focus · baseline is 50") {
            VStack(spacing: 0) {
                ForEach(day.segments) { seg in
                    SegmentRow(seg: seg)
                    if seg.id != day.segments.last?.id {
                        Divider().overlay(Ink.rule)
                    }
                }
                if day.segments.isEmpty {
                    Text("No activity blocks on this day.")
                        .font(.label(11))
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct SegmentRow: View {
    let seg: Segment

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Rectangle()
                .fill(Ink.activity(seg.span.kind))
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(seg.span.label)
                    .font(.label(12, .semibold))
                    .foregroundStyle(Ink.text)
                Text("\(seg.span.kind.label) · \(clock(seg.span.start))–\(clock(seg.span.end)) · \(Int(seg.duration / 60))m · \(seg.span.source.label)")
                    .font(.data(9))
                    .foregroundStyle(Ink.muted)
            }
            .frame(width: 240, alignment: .leading)

            Spacer(minLength: 0)

            if seg.sayable, let mf = seg.medianFocus {
                Cell("FOCUS", String(format: "%.0f", mf),
                     tint: mf < 45 ? Ink.warn : (mf >= flowThreshold ? Ink.amber : Ink.text))
                Cell("FLOW", pct(seg.share(.focused)))
                Cell("DAYDREAM", pct(seg.share(.daydream)),
                     tint: seg.share(.daydream) >= 0.30 ? Ink.warn : Ink.text)
                Cell("CLENCH", pct(seg.share(.clenched)),
                     tint: seg.share(.clenched) >= 0.15 ? Ink.warn : Ink.text)
                Cell("COVERAGE", pct(seg.coverage),
                     tint: seg.coverage < 0.6 ? Ink.warn : Ink.dim)
            } else {
                // The refusal, in the table. Not a zero, not a dash you could read as "fine".
                HStack(spacing: 6) {
                    Text("NO VERDICT")
                        .font(.data(10, .bold))
                        .tracking(1.2)
                        .foregroundStyle(Ink.warn)
                    Text("· \(pct(seg.coverage)) coverage")
                        .font(.data(9))
                        .foregroundStyle(Ink.muted)
                }
                .help("Too little of this block produced a trustworthy score to say anything about it.")
            }
        }
        .padding(.vertical, 8)
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private struct Cell: View {
        let label: String
        let value: String
        var tint: Color = Ink.text

        init(_ l: String, _ v: String, tint: Color = Ink.text) {
            label = l; value = v; self.tint = tint
        }

        var body: some View {
            VStack(alignment: .trailing, spacing: 2) {
                Text(label)
                    .font(.data(8))
                    .tracking(0.8)
                    .foregroundStyle(Ink.muted)
                Text(value)
                    .font(.data(14, .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 74, alignment: .trailing)
        }
    }
}

// MARK: - Derived panels

/// A number that is not a measurement, and says so in the panel rather than in a footnote.
private struct ProxyPanel<Content: View>: View {
    let title: String
    let caveat: String
    @ViewBuilder var content: Content

    var body: some View {
        Panel(title: title, trailing: "PROXY") {
            VStack(alignment: .leading, spacing: 9) {
                content
                Text(caveat)
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StrainPanel: View {
    let day: Day

    var body: some View {
        ProxyPanel(
            title: "COGNITIVE STRAIN",
            caveat: "Alpha suppression plus jaw load, against your own baseline. This is NOT frontal midline theta — FMθ is the validated effort marker, it is read at Fz, and an around-ear pad physically cannot reach frontal midline. Anyone selling you FMθ from an earbud is estimating it or inventing it."
        ) {
            if let v = day.cognitiveStrainProxy {
                Readout(label: "STRAIN", value: String(format: "%.0f", v), unit: "/100", emphasis: true)
            } else {
                NotEnough()
            }
        }
    }
}

private struct RecoveryPanel: View {
    let day: Day

    var body: some View {
        ProxyPanel(
            title: "MENTAL RECOVERY",
            caveat: "Share of trusted time spent alpha-dominant outside an effortful block — actual rest, not merely the absence of work. Withheld time is excluded from the denominator, so a day the electrode fell off does not read as a day of rest."
        ) {
            if let v = day.mentalRecoveryProxy {
                Readout(label: "RECOVERY", value: String(format: "%.0f", v), unit: "%", emphasis: true)
            } else {
                NotEnough()
            }
        }
    }
}

private struct BergerPanelDay: View {
    let day: Day

    var body: some View {
        Panel(title: "INDIVIDUAL ALPHA FREQUENCY", trailing: "measured") {
            VStack(alignment: .leading, spacing: 9) {
                if let f = day.individualAlphaFreq {
                    Readout(label: "IAF", value: String(format: "%.1f", f), unit: "Hz", emphasis: true)
                } else {
                    NotEnough()
                }
                Text("The Berger peak, median over trusted time. This one is real: IAF is a genuine per-subject constant, it is stable within a person, and it is the effect a single around-ear channel demonstrably shows.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Ships as a refusal.
///
/// Competitors sell this. There is no defensible basis for a "brain age" at any channel count, let
/// alone one around-ear channel, so the panel exists and prints nothing — which is a more useful
/// thing to hand a customer than a number we made up.
private struct BrainAgePanel: View {
    var body: some View {
        Panel(title: "BRAIN AGE", trailing: "NOT SHIPPED") {
            VStack(alignment: .leading, spacing: 9) {
                Text("——")
                    .font(.data(20, .semibold))
                    .foregroundStyle(Ink.muted)
                Text("Deliberately empty. Brain Age has no defensible basis at any channel count, and none at all on one around-ear electrode. The competitors who ship it are not measuring your brain's age; they are mapping a band-power scalar onto a number that sells. This panel is here so you can see the shape of the hole rather than have it quietly filled.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NotEnough: View {
    var body: some View {
        Text("NOT ENOUGH TRUSTED SIGNAL")
            .font(.data(10, .bold))
            .tracking(1.2)
            .foregroundStyle(Ink.warn)
    }
}

// MARK: - Empty states

private struct GrantFolder: View {
    let model: DayModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("NO DATA FOLDER")
                .font(.data(13, .bold))
                .tracking(3)
                .foregroundStyle(Ink.text)
            Text("NeuroSync writes plain JSON to ~/Desktop/\(Store.folderName). The sandbox will not let it reach the Desktop without your say-so — grant the folder once and it is remembered.")
                .font(.label(12))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose folder…") { model.chooseFolder() }
                .buttonStyle(InstrumentButton())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyDay: View {
    let model: DayModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("NOTHING RECORDED")
                .font(.data(13, .bold))
                .tracking(3)
                .foregroundStyle(Ink.text)

            Text("No board has streamed into this folder yet, so there is no day to show. There is no demo mode and this view will not invent one.")
                .font(.label(12))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)

            if let e = model.error {
                Text(e)
                    .font(.label(11))
                    .foregroundStyle(Ink.warn)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Divider().overlay(Ink.rule).frame(width: 260)

            VStack(spacing: 8) {
                Button(model.busy ? "Generating…" : "Generate two watermarked synthetic days") {
                    model.generateSynthetic()
                }
                .buttonStyle(InstrumentButton())
                .disabled(model.busy)

                Text("For designing this view without hardware. The waveforms are artificial and every surface that renders them is stamped SYNTHETIC. The scores are still computed by the real DSP — nothing is typed in.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
