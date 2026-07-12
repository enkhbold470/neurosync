//
//  VertexProtocol.swift
//  neurosync
//
//  The BLE wire contract for the Vertex v4 board (Seeed XIAO ESP32-S3 + TI ADS1220).
//
//  Derived from neurofocus/firmware/v4/src/ — the firmware is the source of truth for this
//  protocol and this file must never be written from memory. Cited inline.
//
//  Two things here are easy to get wrong and both are silent failures:
//
//   1. The COMMAND characteristic also NOTIFIES. INFO and DIAG replies come back on it, not
//      on the data stream, and the peripheral drops a notify whose CCCD isn't enabled. If you
//      write `i` before subscribing to the command characteristic, the reply is thrown away
//      and you wait forever. Subscribe first, then write.
//
//   2. The sample rate PERSISTS ACROSS A BLE RECONNECT (it only resets on power cycle). A
//      client that assumes the 175 SPS boot default after reconnecting to a board someone
//      left at 600 renders real 10 Hz alpha at ~34 Hz. Always read `sps` from INFO.
//

import Foundation

nonisolated enum Vertex {

    // MARK: - GATT (firmware v4 src/ble_manager.h:14-16)

    static let serviceUUID = "0338FF7C-6251-4029-A5D5-24E4FA856C8D"
    static let dataCharUUID = "AD615F2B-CC93-4155-9E4D-F5F32CB9A2D7"
    static let cmdCharUUID = "B5E3D1C9-8A2F-4E7B-9C6D-1A3F5E7B9C2D"

    /// src/config.h:98. We scan by service UUID rather than name — `setScanResponse(true)`
    /// keeps the name out of the ADV PDU, so UUID matching is the deterministic path.
    static let deviceName = "NEUROFOCUS_V4_headphone"

    // MARK: - Commands (src/config.h:20-25)

    enum Command {
        static let streamStart: UInt8 = 0x62  // 'b'
        static let streamStop: UInt8 = 0x73   // 's'
        static let reset: UInt8 = 0x76        // 'v'
        static let diag: UInt8 = 0x64         // 'd'
        static let info: UInt8 = 0x69         // 'i'
        static let setRate: UInt8 = 0x7E      // '~' — followed by an ASCII digit 0...7
    }

    /// The ADS1220 output-rate ladder. Index is what `~<n>` selects.
    /// src/ads1220_driver.cpp:40-49. Index 7 is Turbo mode.
    static let rateLadder: [Int] = [20, 45, 90, 175, 330, 600, 1000, 2000]

    /// The boot rate (src/config.h:42-43). Only ever a *default* — never assume it on a
    /// reconnect; ask the board.
    static let defaultRate = 175

    static func rateCommand(index: Int) -> Data? {
        guard rateLadder.indices.contains(index) else { return nil }
        return Data([Command.setRate, UInt8(0x30 + index)])
    }

    /// Sample rates at which the Pope index is physically defensible, given 60 Hz mains.
    static func feasibleRates(line: Double = 60) -> [Int] {
        rateLadder.filter { focusFeasibility(fs: Double($0), line: line).ok }
    }

    // MARK: - Data frame (src/ble_manager.cpp:209-231)

    /// `[0xE7 0x1E] [seq u16 LE] [n u8] [n × i32 LE raw counts]` — one frame per notification.
    ///
    /// Samples are raw ADC counts, sign-extended 24-bit carried in an int32. The firmware
    /// applies no scaling to the wire, so its own AFE_GAIN is irrelevant here; we scale.
    struct Frame: Equatable {
        var seq: UInt16
        var samples: [Int32]
    }

    static let frameMagic: [UInt8] = [0xE7, 0x1E]
    static let headerSize = 5  // 2 magic + 2 seq + 1 count

    /// Returns nil for anything that isn't a well-formed frame. A short buffer means the
    /// notification was truncated by a too-small ATT MTU — the peripheral truncates silently,
    /// so validate the length rather than trusting it.
    static func decode(_ data: Data) -> Frame? {
        let b = [UInt8](data)
        guard b.count >= headerSize,
              b[0] == frameMagic[0], b[1] == frameMagic[1] else { return nil }

        let seq = UInt16(b[2]) | (UInt16(b[3]) << 8)
        let n = Int(b[4])
        guard b.count >= headerSize + 4 * n else { return nil }

        var samples = [Int32]()
        samples.reserveCapacity(n)
        for i in 0..<n {
            let o = headerSize + 4 * i
            let raw = UInt32(b[o])
                | (UInt32(b[o + 1]) << 8)
                | (UInt32(b[o + 2]) << 16)
                | (UInt32(b[o + 3]) << 24)
            samples.append(Int32(bitPattern: raw))
        }
        return Frame(seq: seq, samples: samples)
    }

    // MARK: - INFO (src/main.cpp:68-81)

    /// Emitted on `i`, and unsolicited after every `~` rate change. Exact shape:
    ///
    ///   INFO fw=v4.1 sps=175 mode=binary_batch batch=6 bits=24 vref=3.3 pga=1 afe=1.0
    ///        name=NEUROFOCUS_V4_headphone
    ///
    /// `afe` is the firmware's own AFE_GAIN, which is an unmeasured placeholder of 1.0 — it
    /// tells you the board's DIAG µV are ADC-referred, and nothing about the real AD8422 gain.
    struct Info: Equatable {
        var fw: String
        var sps: Int
        var mode: String
        var batch: Int
        var bits: Int
        var vref: Double
        var pga: Int
        var afe: Double
        var name: String
    }

    static func parseInfo(_ text: String) -> Info? {
        guard text.hasPrefix("INFO ") else { return nil }
        var kv: [String: String] = [:]
        for token in text.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            kv[String(parts[0])] = String(parts[1])
        }
        guard let sps = kv["sps"].flatMap(Int.init) else { return nil }
        return Info(
            fw: kv["fw"] ?? "?",
            sps: sps,
            mode: kv["mode"] ?? "?",
            batch: kv["batch"].flatMap(Int.init) ?? 0,
            bits: kv["bits"].flatMap(Int.init) ?? 24,
            vref: kv["vref"].flatMap(Double.init) ?? 3.3,
            pga: kv["pga"].flatMap(Int.init) ?? 1,
            afe: kv["afe"].flatMap(Double.init) ?? 1.0,
            name: kv["name"] ?? Vertex.deviceName
        )
    }

    // MARK: - DIAG (src/signal_diagnostics.cpp:219-224)

    /// `DIAG rail=0 dc=12.3%FS rms_uV=8.4 m50=1.2 m60=3.4 alpha=2.1 m/a=1.6 v=OK`
    /// `v=` is one of RAILED / DC_SAT / FLAT / FLOAT / OK, or the line is `DIAG err=adc_timeout`.
    struct Diag: Equatable {
        var verdict: String
        var rmsUvAdcReferred: Double?
        var mainsToAlpha: Double?
        var error: String?
    }

    static func parseDiag(_ text: String) -> Diag? {
        guard text.hasPrefix("DIAG ") else { return nil }
        var kv: [String: String] = [:]
        for token in text.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            kv[String(parts[0])] = String(parts[1])
        }
        if let err = kv["err"] {
            return Diag(verdict: "ERR", rmsUvAdcReferred: nil, mainsToAlpha: nil, error: err)
        }
        return Diag(
            verdict: kv["v"] ?? "?",
            rmsUvAdcReferred: kv["rms_uV"].flatMap(Double.init),
            mainsToAlpha: kv["m/a"].flatMap(Double.init),
            error: nil
        )
    }
}
