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
                    Text(dayLabel(d))
                        .font(.data(12, d.key == day.key ? .bold : .regular))
                        .foregroundStyle(d.key == day.key ? Ink.bg : Ink.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(d.key == day.key ? Ink.amber : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
                            .strokeBorder(Ink.rule, lineWidth: 1))
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
            VStack(alignment: .leading, spacing: 13) {
                ForEach(day.findings) { f in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: f.tone.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.tone(f.tone))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.headline)
                                .font(.label(14, .semibold))
                                .foregroundStyle(Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(f.caveat)
                                .font(.label(12))
                                .foregroundStyle(Ink.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Ink.rule)

                // The confound line. Shortened on the surface; the full statement is on hover — it is
                // not a disclaimer to dismiss, it is the strongest true thing the data supports.
                Label("Association only, not causation — one person, one day, uncontrolled.",
                      systemImage: "info.circle")
                    .font(.label(11))
                    .foregroundStyle(Ink.muted)
                    .help(confoundFooter)
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
        HStack(alignment: .center, spacing: 14) {
            IconChip(system: seg.span.kind.icon, tint: Ink.activity(seg.span.kind).opacity(1), size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(seg.span.label)
                    .font(.label(14, .semibold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                Text("\(seg.span.kind.label) · \(clock(seg.span.start))–\(clock(seg.span.end)) · \(Int(seg.duration / 60))m · \(seg.span.source.label)")
                    .font(.data(11))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
            }
            .frame(width: 244, alignment: .leading)

            Spacer(minLength: 0)

            if seg.sayable, let mf = seg.medianFocus {
                MetricCell(label: "FOCUS", display: String(format: "%.0f", mf),
                           value: mf / 100,
                           tint: mf < 45 ? Ink.warn : (mf >= flowThreshold ? Ink.amber : Ink.text),
                           baseline: 0.5)
                MetricCell(label: "FLOW", display: pct(seg.share(.focused)),
                           value: seg.share(.focused), tint: Ink.amber)
                MetricCell(label: "DAYDREAM", display: pct(seg.share(.daydream)),
                           value: seg.share(.daydream),
                           tint: seg.share(.daydream) >= 0.30 ? Ink.warn : Ink.state(.daydream))
                MetricCell(label: "CLENCH", display: pct(seg.share(.clenched)),
                           value: seg.share(.clenched),
                           tint: seg.share(.clenched) >= 0.15 ? Ink.warn : Ink.dim)
                MetricCell(label: "COVERAGE", display: pct(seg.coverage),
                           value: seg.coverage,
                           tint: seg.coverage < 0.6 ? Ink.warn : Ink.dim)
            } else {
                // The refusal, in the table. Not a zero, not a dash you could read as "fine".
                HStack(spacing: 8) {
                    Image(systemName: "nosign").font(.system(size: 14)).foregroundStyle(Ink.warn)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NO VERDICT")
                            .font(.data(12, .bold)).tracking(1.0).foregroundStyle(Ink.warn)
                        Text("\(pct(seg.coverage)) coverage")
                            .font(.data(11)).foregroundStyle(Ink.muted)
                    }
                }
                .help("Too little of this block produced a trustworthy score to say anything about it.")
            }
        }
        .padding(.vertical, 10)
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}

// MARK: - Derived panels

/// A proxy panel: an icon + gauge, one short line, and the full explanation on hover. The long
/// caveat is not gone — it moved to the tooltip, so the panel reads at a glance and an agent (or a
/// curious human) can still pull the whole story with `ⓘ`.
private struct ProxyPanel<Gauge: View>: View {
    let title: String
    let icon: String
    let note: String
    let detail: String
    @ViewBuilder var gauge: Gauge

    var body: some View {
        Panel(title: title, trailing: "PROXY") {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Ink.muted)
                    gauge
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(note)
                        .font(.label(13))
                        .foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("what this is", systemImage: "info.circle")
                        .font(.data(10)).foregroundStyle(Ink.muted)
                        .help(detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct StrainPanel: View {
    let day: Day

    var body: some View {
        ProxyPanel(
            title: "COGNITIVE STRAIN",
            icon: "gauge.with.dots.needle.67percent",
            note: "Alpha suppression + jaw load, vs your baseline.",
            detail: "NOT frontal midline theta — FMθ is the validated effort marker, read at Fz, and an around-ear pad cannot reach frontal midline. Anyone selling you FMθ from an earbud is estimating or inventing it."
        ) {
            if let v = day.cognitiveStrainProxy {
                RingGauge(value: v / 100, center: String(format: "%.0f", v), unit: "/100",
                          tint: v >= 66 ? Ink.warn : Ink.amber)
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
            icon: "leaf.fill",
            note: "Alpha-dominant rest outside work blocks.",
            detail: "Share of trusted time spent alpha-dominant outside an effortful block — actual rest, not merely the absence of work. Withheld time is excluded from the denominator, so a day the electrode fell off does not read as a day of rest."
        ) {
            if let v = day.mentalRecoveryProxy {
                RingGauge(value: v / 100, center: String(format: "%.0f", v), unit: "%",
                          tint: Ink.state(.calm))
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
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 14)).foregroundStyle(Ink.muted)
                    if let f = day.individualAlphaFreq {
                        VStack(spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(String(format: "%.1f", f)).font(.data(28, .bold)).foregroundStyle(Ink.amber)
                                Text("Hz").font(.data(11)).foregroundStyle(Ink.muted)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Ink.rule)
                                    Capsule().fill(Ink.amber).frame(width: 3)
                                        .offset(x: g.size.width * min(1, max(0, (f - 8) / 5)))
                                }
                            }
                            .frame(width: 92, height: 4)
                            Text("8–13 Hz").font(.data(9)).foregroundStyle(Ink.muted)
                        }
                    } else {
                        NotEnough()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Berger peak — a real, stable per-person constant.")
                        .font(.label(13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("what this is", systemImage: "info.circle")
                        .font(.data(10)).foregroundStyle(Ink.muted)
                        .help("The Berger peak, median over trusted time. This one is real: IAF is a genuine per-subject constant, stable within a person, and the effect a single around-ear channel demonstrably shows.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Ships as a refusal — see the tooltip for why.
private struct BrainAgePanel: View {
    var body: some View {
        Panel(title: "BRAIN AGE", trailing: "NOT SHIPPED") {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(Ink.muted)
                    Image(systemName: "nosign").font(.system(size: 30)).foregroundStyle(Ink.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deliberately empty — it has no defensible basis.")
                        .font(.label(13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("what this is", systemImage: "info.circle")
                        .font(.data(10)).foregroundStyle(Ink.muted)
                        .help("Brain Age has no defensible basis at any channel count, and none on one around-ear electrode. Competitors who ship it map a band-power scalar onto a number that sells. This panel shows the shape of the hole rather than quietly filling it.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct NotEnough: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 20)).foregroundStyle(Ink.warn)
            Text("NOT ENOUGH\nTRUSTED SIGNAL")
                .font(.data(10, .bold)).tracking(0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ink.warn)
        }
        .frame(width: 92)
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
                Button(model.busy ? "Generating…" : "Generate two synthetic days") {
                    model.generateSynthetic()
                }
                .buttonStyle(InstrumentButton())
                .disabled(model.busy)

                Text("For designing this view without hardware. The waveforms are artificial, and each record carries \"synthetic\": true in its JSON. The scores are still computed by the real DSP — nothing is typed in.")
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
