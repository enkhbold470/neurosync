//
//  DSP.swift
//  neurosync
//
//  Signal chain for the Vertex v4 single-channel dry-EEG insert.
//
//  Ported constant-for-constant from web-ble-monitor/src/lib/dsp.ts, which is the
//  tested reference implementation. Where a choice here looks arbitrary it is not —
//  it matches the reference so the Mac app and the browser analyzer cannot disagree
//  about what a brain is doing. Two deviations from scipy.signal.welch are load-bearing
//  and are called out at `hann` and `welch`.
//

import Foundation

// MARK: - Bands

nonisolated enum Band: String, CaseIterable, Sendable {
    case delta, theta, alpha, beta, gamma
}

/// dsp.ts BAND_DEFS. The bands touch — no gaps.
nonisolated let bandDefs: [(band: Band, lo: Double, hi: Double)] = [
    (.delta, 0.5, 4),
    (.theta, 4, 8),
    (.alpha, 8, 13),
    (.beta, 13, 30),
    (.gamma, 30, 45)
]

typealias BandPowers = [Band: Double]

// MARK: - Counts → microvolts

/// adc.ts ADC_PROFILES.v4. `gain` is the AD8422 instrumentation amp (U12) ahead of the ADC.
///
/// The firmware's own `AFE_GAIN` is 1.0, so the board's DIAG µV strings are ADC-referred and
/// read ~100x larger than these. We scale raw counts ourselves and never ingest DIAG µV.
nonisolated struct ScaleSettings: Sendable {
    var adcBits: Int = 24
    var vref: Double = 3.3
    var gain: Double = 100
    var line: Double = 60
    var bipolar: Bool = true
    var offset: Double = 0

    static let v4 = ScaleSettings()
}

/// One count is 3.3 V / 2^23 ≈ 393.2 nV at the ADC, ≈ 3.93 nV at the electrode.
nonisolated func countsToUv(_ value: Double, _ s: ScaleSettings = .v4) -> Double {
    let halfScaleCodes = pow(2.0, Double(s.bipolar ? s.adcBits - 1 : s.adcBits))
    let centered = value - s.offset
    let uvAdc = centered * ((s.vref * 1e6) / halfScaleCodes)
    return s.gain > 0 ? uvAdc / s.gain : uvAdc
}

nonisolated func nextPow2(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return max(1, p)
}

// MARK: - Biquad (RBJ cookbook, transposed direct form II)

nonisolated struct Biquad {
    private let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    static func highpass(fs: Double, f0: Double, q: Double) -> Biquad {
        let w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2,
                      a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }

    static func lowpass(fs: Double, f0: Double, q: Double) -> Biquad {
        let w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q)
        return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2,
                      a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }

    static func notch(fs: Double, f0: Double, q: Double) -> Biquad {
        let w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q)
        return Biquad(b0: 1, b1: -2 * c, b2: 1,
                      a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }
}

/// 4th-order Butterworth band-pass + mains notch (with harmonics), as cascaded biquads.
///
/// At fs=175 with line=60 there is exactly ONE notch: 120 Hz exceeds the 0.49*fs bound
/// (85.75 Hz) and is skipped.
nonisolated struct FilterChain {
    private var stages: [Biquad]

    init(fs: Double, lo: Double, hi: Double, line: Double) {
        var s: [Biquad] = []
        // 4th-order Butterworth as two cascaded sections, per-section Q.
        let sectionQ = [0.541196, 1.306563]
        for q in sectionQ { s.append(.highpass(fs: fs, f0: max(0.1, lo), q: q)) }
        for q in sectionQ { s.append(.lowpass(fs: fs, f0: min(hi, 0.49 * fs), q: q)) }
        if line > 0 {
            var f = line
            while f < 0.49 * fs {
                s.append(.notch(fs: fs, f0: f, q: 30))
                f += line
            }
        }
        stages = s
    }

    mutating func step(_ x: Double) -> Double {
        var y = x
        for i in stages.indices { y = stages[i].step(y) }
        return y
    }

    mutating func reset() {
        for i in stages.indices { stages[i].reset() }
    }
}

// MARK: - Welch PSD

nonisolated struct Psd: Sendable {
    var freqs: [Double]
    var psd: [Double]
}

/// Symmetric Hann — the `(n - 1)` denominator.
///
/// scipy.signal.welch uses a PERIODIC window (`sym=False`); the reference implementation
/// uses the symmetric one. Matching scipy here would silently shift every band power.
nonisolated private func hann(_ n: Int) -> [Double] {
    guard n > 1 else { return [Double](repeating: 1, count: max(n, 0)) }
    return (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1)) }
}

/// Per-segment linear detrend. scipy.signal.welch defaults to `detrend='constant'`.
nonisolated private func detrendLinear(_ x: ArraySlice<Double>) -> [Double] {
    let n = x.count
    guard n > 1 else { return Array(x) }
    let nd = Double(n)
    var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
    for (i, v) in x.enumerated() {
        let xi = Double(i)
        sumX += xi; sumY += v; sumXY += xi * v; sumXX += xi * xi
    }
    let denom = nd * sumXX - sumX * sumX
    guard denom != 0 else { return Array(x) }
    let slope = (nd * sumXY - sumX * sumY) / denom
    let intercept = (sumY - slope * sumX) / nd
    return x.enumerated().map { $0.element - (slope * Double($0.offset) + intercept) }
}

/// In-place iterative radix-2 FFT. N is a power of two.
///
/// Deliberately not vDSP: at N=256, 5 segments, 8x/sec this is free, and a hand-rolled
/// transform can't diverge from the reference the way vDSP's window/scaling conventions can.
nonisolated private func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    guard n > 1 else { return }

    var j = 0
    for i in 0..<(n - 1) {
        if i < j {
            re.swapAt(i, j); im.swapAt(i, j)
        }
        var k = n >> 1
        while k <= j { j -= k; k >>= 1 }
        j += k
    }

    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        let wr = cos(ang), wi = sin(ang)
        var i = 0
        while i < n {
            var cr = 1.0, ci = 0.0
            for k in 0..<(len / 2) {
                let uR = re[i + k], uI = im[i + k]
                let vR = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci
                let vI = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr
                re[i + k] = uR + vR;              im[i + k] = uI + vI
                re[i + k + len / 2] = uR - vR;    im[i + k + len / 2] = uI - vI
                let nr = cr * wr - ci * wi
                ci = cr * wi + ci * wr
                cr = nr
            }
            i += len
        }
        len <<= 1
    }
}

/// Welch one-sided PSD: Hann window, linear detrend per segment, overlap-averaged.
/// Units: µV²/Hz.
nonisolated func welch(_ x: [Double], fs: Double, nperseg: Int, overlap: Double) -> Psd {
    let n = nextPow2(nperseg)
    let nfreq = n / 2 + 1
    let freqs = (0..<nfreq).map { Double($0) * fs / Double(n) }
    var psd = [Double](repeating: 0, count: nfreq)
    guard x.count >= n else { return Psd(freqs: freqs, psd: psd) }

    let w = hann(n)
    var u = 0.0
    for v in w { u += v * v }
    let step = max(1, Int(Double(n) * (1 - overlap)))

    var segs = 0
    var start = 0
    while start + n <= x.count {
        let seg = detrendLinear(x[start..<(start + n)])
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for i in 0..<n { re[i] = seg[i] * w[i] }
        fft(&re, &im)
        for k in 0..<nfreq {
            let mag2 = re[k] * re[k] + im[k] * im[k]
            let scale = (k == 0 || k == n / 2) ? 1 / (fs * u) : 2 / (fs * u)
            psd[k] += scale * mag2
        }
        segs += 1
        start += step
    }
    if segs > 0 { for k in 0..<nfreq { psd[k] /= Double(segs) } }
    return Psd(freqs: freqs, psd: psd)
}

/// Trapezoidal integration with linear interpolation at partial band edges.
/// A naive bin-sum does NOT reproduce these numbers.
nonisolated func bandPowers(_ freqs: [Double], _ psd: [Double]) -> BandPowers {
    var out: BandPowers = [:]
    for (name, lo, hi) in bandDefs {
        var acc = 0.0
        guard freqs.count > 1 else { out[name] = 0; continue }
        for k in 1..<freqs.count {
            let f0 = freqs[k - 1], f1 = freqs[k]
            if f1 <= lo || f0 >= hi { continue }
            let a = max(f0, lo), b = min(f1, hi)
            if b <= a { continue }
            let span = (f1 - f0) == 0 ? 1 : (f1 - f0)
            let pa = psd[k - 1] + (psd[k] - psd[k - 1]) * (a - f0) / span
            let pb = psd[k - 1] + (psd[k] - psd[k - 1]) * (b - f0) / span
            acc += 0.5 * (pa + pb) * (b - a)
        }
        out[name] = acc
    }
    return out
}

/// Argmax of the PSD over [lo, hi], inclusive. nil if no bin lands in range.
nonisolated func peakFreq(_ freqs: [Double], _ psd: [Double], _ lo: Double, _ hi: Double) -> Double? {
    var best: Double?
    var bestP = -Double.infinity
    for k in freqs.indices where freqs[k] >= lo && freqs[k] <= hi {
        if psd[k] > bestP { bestP = psd[k]; best = freqs[k] }
    }
    return best
}
