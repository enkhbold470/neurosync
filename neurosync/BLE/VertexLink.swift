//
//  VertexLink.swift
//  neurosync
//
//  CoreBluetooth central for the Vertex v4 board. Owns the radio and the DSP on its own
//  serial queue and publishes immutable snapshots; it never touches the UI.
//
//  There is no simulated source here, and there will not be one. If no board is on a head,
//  this object produces no numbers. (Manifesto II — real signal or nothing.)
//

import Foundation
import CoreBluetooth

// MARK: - Public surface

enum LinkState: Equatable, Sendable {
    case idle
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting
    /// Link is up but we have not yet heard INFO, so we do not know the sample rate.
    case interrogating
    case streaming
    case failed(String)
}

struct VertexSnapshot: Sendable {
    var metrics = FocusMetrics()
    /// Band-passed µV, electrode-referred. The scope trace.
    var waveform: [Double] = []
    var fs: Double = 0
    var info: Vertex.Info?
    var diag: Vertex.Diag?
    /// Frames lost, inferred from gaps in the wire sequence number.
    var droppedFrames: Int = 0
    var framesReceived: Int = 0
}

// MARK: - Link

nonisolated final class VertexLink: NSObject {

    var onState: (@Sendable (LinkState) -> Void)?
    var onSnapshot: (@Sendable (VertexSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "dev.neurofocus.vertex.ble")
    /// Created on the first connect(), not at launch: powering up the radio is what triggers
    /// the macOS Bluetooth permission prompt, and an app that has not been asked to connect to
    /// anything has no business asking for the radio.
    private var central: CBCentralManager?
    private var wantsScan = false
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var cmdChar: CBCharacteristic?

    private var engine: FocusEngine?
    private var snapshot = VertexSnapshot()
    private var lastSeq: UInt16?
    private var infoRetries = 0
    private var infoTimer: DispatchSourceTimer?

    /// Set when the user picks a rate before/while connected; applied once the link is up.
    private var pendingRateIndex: Int?

    private var state: LinkState = .idle {
        didSet {
            guard state != oldValue else { return }
            let s = state
            onState?(s)
        }
    }

    // MARK: Control

    func connect() {
        queue.async { [self] in
            wantsScan = true
            guard let c = central else {
                // First use. The scan starts from centralManagerDidUpdateState once the radio
                // reports .poweredOn — you cannot scan before that.
                central = CBCentralManager(delegate: self, queue: queue)
                return
            }
            startScanIfReady(c)
        }
    }

    private func startScanIfReady(_ c: CBCentralManager) {
        guard wantsScan, peripheral == nil else { return }
        switch c.state {
        case .poweredOn:
            state = .scanning
            c.scanForPeripherals(
                withServices: [CBUUID(string: Vertex.serviceUUID)],
                options: nil
            )
        case .poweredOff:
            state = .bluetoothOff
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .failed("This Mac has no Bluetooth LE radio.")
        default:
            break  // .unknown / .resetting — wait for the next state callback.
        }
    }

    func disconnect() {
        queue.async { [self] in
            wantsScan = false
            cancelInfoTimer()
            // Stop the stream cleanly. The firmware has no stale-connection handling: an
            // unclean drop leaves the board pumping notifies into a dead link and NOT
            // advertising until the supervision timeout expires.
            if let p = peripheral, let c = cmdChar {
                p.writeValue(Data([Vertex.Command.streamStop]), for: c, type: .withoutResponse)
            }
            if let p = peripheral { central?.cancelPeripheralConnection(p) }
            central?.stopScan()
            teardown()
            state = .idle
        }
    }

    /// Ask the board to switch to `Vertex.rateLadder[index]`. The board answers with an
    /// unsolicited INFO, which is what actually re-arms the DSP.
    func setRate(index: Int) {
        queue.async { [self] in
            guard let cmd = Vertex.rateCommand(index: index) else { return }
            guard let p = peripheral, let c = cmdChar else {
                pendingRateIndex = index
                return
            }
            p.writeValue(cmd, for: c, type: .withoutResponse)
        }
    }

    func requestDiag() {
        queue.async { [self] in
            guard let p = peripheral, let c = cmdChar else { return }
            p.writeValue(Data([Vertex.Command.diag]), for: c, type: .withoutResponse)
        }
    }

    func recalibrate() {
        queue.async { [self] in
            engine?.recalibrate()
            if let e = engine {
                snapshot.metrics = e.metrics
                emit()
            }
        }
    }

    private func teardown() {
        peripheral = nil
        dataChar = nil
        cmdChar = nil
        engine = nil
        lastSeq = nil
        infoRetries = 0
        snapshot = VertexSnapshot()
        emit()
    }

    private func emit() {
        let s = snapshot
        onSnapshot?(s)
    }

    // MARK: INFO handshake

    /// The board's rate survives a BLE reconnect, so we must ASK rather than assume. If INFO
    /// never lands we fail loudly instead of guessing 175 — guessing would slide every
    /// frequency in the spectrum by a constant ratio and quietly corrupt the score.
    private func requestInfo() {
        guard let p = peripheral, let c = cmdChar else { return }
        p.writeValue(Data([Vertex.Command.info]), for: c, type: .withoutResponse)

        cancelInfoTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.engine == nil else { return }  // INFO landed; nothing to do
            if self.infoRetries < 2 {
                self.infoRetries += 1
                self.requestInfo()
            } else {
                self.state = .failed("Board never answered INFO — cannot know the sample rate, so no score can be trusted.")
            }
        }
        t.resume()
        infoTimer = t
    }

    private func cancelInfoTimer() {
        infoTimer?.cancel()
        infoTimer = nil
    }

    private func handle(info: Vertex.Info) {
        cancelInfoTimer()
        snapshot.info = info
        snapshot.fs = Double(info.sps)

        // Rebuild the DSP: the filter chain, window and FFT size all derive from fs.
        engine = FocusEngine(fs: Double(info.sps))
        snapshot.metrics = engine!.metrics
        lastSeq = nil

        if let p = peripheral, let d = dataChar, !d.isNotifying {
            p.setNotifyValue(true, for: d)
        }
        state = .streaming
        emit()
    }

    private func handle(frame: Vertex.Frame) {
        guard let engine else { return }

        if let last = lastSeq {
            let expected = last &+ 1
            if frame.seq != expected {
                let gap = Int(frame.seq &- expected)
                // A wildly negative-looking gap is a wrap or a reconnect, not 65k lost frames.
                if gap > 0 && gap < 1000 { snapshot.droppedFrames += gap }
            }
        }
        lastSeq = frame.seq
        snapshot.framesReceived += 1

        for s in frame.samples { engine.push(counts: s) }

        snapshot.metrics = engine.metrics
        snapshot.waveform = engine.window
        emit()
    }
}

// MARK: - CBCentralManagerDelegate

extension VertexLink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            startScanIfReady(c)
        case .poweredOff:
            teardown()
            state = .bluetoothOff
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .failed("This Mac has no Bluetooth LE radio.")
        default:
            break
        }
    }

    func centralManager(_ c: CBCentralManager,
                        didDiscover p: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        c.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .interrogating
        p.discoverServices([CBUUID(string: Vertex.serviceUUID)])
    }

    func centralManager(_ c: CBCentralManager,
                        didFailToConnect p: CBPeripheral,
                        error: Error?) {
        teardown()
        state = .failed(error?.localizedDescription ?? "Could not connect to the board.")
    }

    func centralManager(_ c: CBCentralManager,
                        didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        cancelInfoTimer()
        teardown()
        state = error == nil ? .idle : .failed("Link dropped: \(error!.localizedDescription)")
    }
}

// MARK: - CBPeripheralDelegate

extension VertexLink: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: {
            $0.uuid == CBUUID(string: Vertex.serviceUUID)
        }) else {
            state = .failed("Board is missing the NeuroFocus GATT service.")
            return
        }
        p.discoverCharacteristics(
            [CBUUID(string: Vertex.dataCharUUID), CBUUID(string: Vertex.cmdCharUUID)],
            for: svc
        )
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == CBUUID(string: Vertex.dataCharUUID) { dataChar = ch }
            if ch.uuid == CBUUID(string: Vertex.cmdCharUUID) { cmdChar = ch }
        }
        guard let cmd = cmdChar, dataChar != nil else {
            state = .failed("Board is missing the data or command characteristic.")
            return
        }

        // ORDER MATTERS. Subscribe to the command characteristic FIRST: the firmware notifies
        // INFO and DIAG back on it, and the peripheral silently drops a notify whose CCCD is
        // not yet enabled. Writing `i` before this line means the reply is thrown away.
        p.setNotifyValue(true, for: cmd)
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateNotificationStateFor ch: CBCharacteristic,
                    error: Error?) {
        guard ch.uuid == CBUUID(string: Vertex.cmdCharUUID), ch.isNotifying else { return }

        // Now it is safe to talk to the board.
        if let idx = pendingRateIndex, let cmd = Vertex.rateCommand(index: idx) {
            pendingRateIndex = nil
            p.writeValue(cmd, for: ch, type: .withoutResponse)
        }
        requestInfo()
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        guard let data = ch.value, !data.isEmpty else { return }

        if ch.uuid == CBUUID(string: Vertex.dataCharUUID) {
            if let frame = Vertex.decode(data) { handle(frame: frame) }
            return
        }

        guard ch.uuid == CBUUID(string: Vertex.cmdCharUUID) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if let info = Vertex.parseInfo(s) {
                handle(info: info)
            } else if let diag = Vertex.parseDiag(s) {
                snapshot.diag = diag
                emit()
            }
        }
    }
}
