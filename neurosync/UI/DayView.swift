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
                            Panel(title: "TIMELINE", symbol: "calendar.day.timeline.left", trailing: coverageLabel(day)) {
                                DayRibbon(day: day)
                                StateLegend()
                            }

                            FindingsPanel(day: day)
                            SegmentsPanel(day: day)

                            DerivedStrip(day: day)
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
                        .foregroundStyle(d.key == day.key ? Ink.onAccent : Ink.dim)
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
        Panel(title: "FINDINGS", symbol: "lightbulb", trailing: "\(day.findings.count)") {
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
        Panel(title: "BLOCKS", symbol: "rectangle.stack", trailing: "median focus · baseline is 50") {
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

// MARK: - Derived metrics — one compact row

/// The four derived readouts, condensed from four big panels into one row so they stop dominating the
/// day. The honest tags stay (PROXY / MEASURED / NOT SHIPPED) and every caveat is one ⓘ hover away.
struct DerivedStrip: View {
	let day: Day

	var body: some View {
		Panel(title: "DERIVED", symbol: "function", trailing: "proxies — hover ⓘ for the caveat") {
			HStack(alignment: .top, spacing: 10) {
				DerivedTile(
					title: "COGNITIVE STRAIN", tag: "PROXY",
					value: day.cognitiveStrainProxy.map { String(format: "%.0f", $0) },
					unit: "/100",
					tint: (day.cognitiveStrainProxy ?? 0) >= 66 ? Ink.warn : Ink.amber,
					note: "Alpha suppression + jaw load, vs your baseline.",
					detail: "NOT frontal midline theta — FMθ is the validated effort marker, read at Fz, and an around-ear pad cannot reach frontal midline. Anyone selling you FMθ from an earbud is estimating or inventing it."
				)
				DerivedTile(
					title: "MENTAL RECOVERY", tag: "PROXY",
					value: day.mentalRecoveryProxy.map { String(format: "%.0f", $0) },
					unit: "%",
					tint: Ink.state(.calm),
					note: "Alpha-dominant rest outside work blocks.",
					detail: "Share of trusted time spent alpha-dominant outside an effortful block — actual rest, not merely the absence of work. Withheld time is excluded from the denominator, so a day the electrode fell off does not read as a day of rest."
				)
				DerivedTile(
					title: "ALPHA (IAF)", tag: "MEASURED",
					value: day.individualAlphaFreq.map { String(format: "%.1f", $0) },
					unit: "Hz",
					tint: Ink.amber,
					note: "Your Berger peak — a stable per-person constant.",
					detail: "The Berger peak, median over trusted time. This one is real: IAF is a genuine per-subject constant, stable within a person, and the effect a single around-ear channel demonstrably shows."
				)
				DerivedTile(
					title: "BRAIN AGE", tag: "NOT SHIPPED",
					value: nil, unit: "",
					tint: Ink.muted,
					note: "Deliberately empty — no defensible basis.",
					detail: "Brain Age has no defensible basis at any channel count, and none on one around-ear electrode. Competitors who ship it map a band-power scalar onto a number that sells. This panel shows the shape of the hole rather than quietly filling it."
				)
			}
		}
	}
}

/// One derived readout: title + tag, a big value (or a dash when there is no defensible number), a
/// one-line note, and the full caveat on the ⓘ hover.
struct DerivedTile: View {
	let title: String
	let tag: String
	let value: String?
	let unit: String
	let tint: Color
	let note: String
	let detail: String

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				Text(title).font(.data(9, .semibold)).tracking(0.8).foregroundStyle(Ink.muted).lineLimit(1)
				Spacer(minLength: 4)
				Text(tag).font(.data(8, .semibold)).tracking(0.6).foregroundStyle(Ink.muted.opacity(0.8))
			}
			HStack(alignment: .firstTextBaseline, spacing: 2) {
				Text(value ?? "—")
					.font(.data(26, .bold))
					.foregroundStyle(value == nil ? Ink.muted : tint)
				if value != nil, !unit.isEmpty {
					Text(unit).font(.data(10)).foregroundStyle(Ink.muted)
				}
			}
			HStack(alignment: .top, spacing: 5) {
				Text(note)
					.font(.label(10))
					.foregroundStyle(Ink.muted)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 2)
				Image(systemName: "info.circle")
					.font(.system(size: 10)).foregroundStyle(Ink.muted)
					.help(detail)
			}
		}
		.padding(Space.md)
		.frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
		.background(Ink.plotBacking, in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
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
