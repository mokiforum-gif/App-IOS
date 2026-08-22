import Foundation
import CoreBluetooth

/// Central-side transport for the Bruce NUS bridge.
///
/// Responsibilities (plan phases 1-2):
/// - scan filtering by the NUS service UUID and connect;
/// - discover RX/TX characteristics and subscribe to TX notifications;
/// - `send(_:)` a command (appends `\n`, chunks to the negotiated MTU);
/// - reassemble TX notifications into complete lines for the UI.
@MainActor
final class BLEManager: NSObject, ObservableObject {

    enum State: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case discovering
        case ready
        case disconnected

        /// Localized through `L10n` rather than `Text`: this crosses into views as
        /// a plain `String`, which SwiftUI would render verbatim.
        var label: String {
            switch self {
            case .poweredOff:   return L10n.t("Bluetooth desligado")
            case .unauthorized: return L10n.t("Sem permissão de Bluetooth")
            case .idle:         return L10n.t("Pronto para escanear")
            case .scanning:     return L10n.t("Procurando o Bruce…")
            case .connecting:   return L10n.t("Conectando…")
            case .discovering:  return L10n.t("Descobrindo serviços…")
            case .ready:        return L10n.t("Conectado")
            case .disconnected: return L10n.t("Desconectado")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [TerminalLine] = []
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var deviceName: String?
    /// True while a multi-line transfer is streaming — used to serialize
    /// operations (Bruce's serial RX has no queue; overlapping writes corrupt it).
    @Published private(set) var isBusy = false

    /// The mirrored device display, driven by the binary draw packets that arrive
    /// interleaved with text output once `display start` is active.
    let screen = TFTScreen()

    /// Absolute paths (lowercased) of files found on the device in the folders the
    /// library cares about. Backs the Library's "synced" badge.
    @Published private(set) var deviceFiles: Set<String> = []
    /// Which folders `deviceFiles` actually reflects. A file whose folder was never
    /// listed reads as "unknown" rather than "not on the device".
    @Published private(set) var scannedFolders: Set<String> = []
    /// The in-flight folder scan, so overlapping refreshes share one run.
    private var indexTask: Task<Void, Never>?

    /// Which filesystem the device's `storage` commands are hitting, and how much
    /// room each one has. Nil until probed (or after a disconnect), because the
    /// answer is device state the app can only learn by asking.
    @Published private(set) var storageReport: DeviceStorageReport?
    /// The in-flight storage probe, so overlapping refreshes share one run.
    private var storageTask: Task<Void, Never>?

    /// What the device says about itself (`info`, `free`, `uptime`, `date`), for
    /// the "Meu Bruce" screen. Nil until read, and dropped on disconnect.
    @Published private(set) var deviceStatus: DeviceStatus?
    /// When the overview last finished, so the screen can say how fresh it is.
    /// Reading is no longer automatic on every visit, which makes this the only
    /// way to tell a live reading from one taken an hour ago.
    @Published private(set) var lastOverviewRefresh: Date?
    /// Which step the overview read is on, or nil when nothing is being read.
    /// Drives the loading screen — the whole sequence is several round trips over
    /// a slow link, so "what is it doing" is worth showing.
    @Published private(set) var probeStep: DeviceProbeStep?
    /// The in-flight overview read, so overlapping refreshes share one run.
    private var overviewTask: Task<Void, Never>?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Where commands are written. On the custom layout this equals `notifyCharacteristic`.
    private var writeCharacteristic: CBCharacteristic?
    /// Where output notifications arrive.
    private var notifyCharacteristic: CBCharacteristic?
    /// Battery Level (`2A19`), kept so the reading can be asked for again.
    ///
    /// The firmware's battery task refreshes the characteristic's value every
    /// minute but never notifies (`BatteryService.cpp` calls `setValue` only), so
    /// the subscription delivers nothing after the initial read: without an
    /// explicit re-read the badge shows the charge as it was when we connected.
    private var batteryCharacteristic: CBCharacteristic?

    /// Separates TFT draw packets from ordinary text on the shared TX stream.
    private var demuxer = TFTStreamDemuxer()

    /// Incomplete tail of the received text, awaiting a newline.
    private var rxLineBuffer: [UInt8] = []

    /// Backstop for a peripheral that never confirms its subscription.
    private var readinessFallback: DispatchWorkItem?

    /// Installed for the duration of a raw binary transfer (see `handleTX`).
    private var rawByteSink: (@MainActor (Data) -> Void)?

    /// Chunks waiting on the radio's flow control. See `writeRaw`.
    private var writeQueue: [Data] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        lines.removeAll(keepingCapacity: true)
        rxLineBuffer.removeAll(keepingCapacity: true)
        demuxer.reset()
        screen.clear()
        state = .scanning
        // Scan unfiltered and match by name: Bruce's advertisement often omits the
        // 128-bit service UUID, so a service-filtered scan can miss the device.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    /// Ask the device for its charge again.
    ///
    /// Costs nothing on the serial side — this is a plain GATT read, so it does not
    /// queue behind a command or make the firmware repaint its menu. The new value
    /// lands in `batteryLevel` through `didUpdateValueFor`, which is why this does
    /// not wait for anything.
    func refreshBatteryLevel() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    /// Send a command line to the Bruce parser. A trailing `\n` is appended and
    /// the payload is split into MTU-sized chunks.
    ///
    /// Set `echo` to false to keep the line out of the Terminal — the screen mirror
    /// does this so that a stream of navigation presses and screen refreshes does
    /// not crowd out real output.
    func send(_ command: String, echo: Bool = true) {
        var line = command
        if !line.hasSuffix("\n") { line += "\n" }
        guard let data = line.data(using: .utf8) else { return }
        writeRaw(data)
        if echo { appendOutput(command, kind: .sent) }
    }

    /// Send a typed command. Renders to its serial line and reuses `send(_:)`.
    func send(_ command: BruceCommand, echo: Bool = true) {
        send(command.serialLine, echo: echo)
    }

    /// Write bytes to the serial characteristic verbatim (no newline, no echo),
    /// chunked to the MTU and paced by the radio's own flow control.
    ///
    /// The firmware's RX characteristic advertises `WRITE_NR`, so iOS uses
    /// write-without-response — and **silently discards** those payloads once its
    /// internal queue is full, with no error and no delegate callback. Handing it
    /// several chunks in a row therefore loses some of them. Text uploads hid this
    /// behind their 40 ms per-line pacing; a binary block, written as one burst,
    /// does not, which is why the device would sit waiting for bytes that were
    /// never transmitted. Chunks are queued here and released only while
    /// `canSendWriteWithoutResponse` is true, resuming from the delegate.
    private func writeRaw(_ data: Data) {
        guard let peripheral, let writeCharacteristic else { return }
        let maxLen = max(1, peripheral.maximumWriteValueLength(for: writeType(for: writeCharacteristic)))

        var offset = 0
        while offset < data.count {
            let end = min(offset + maxLen, data.count)
            writeQueue.append(data.subdata(in: offset..<end))
            offset = end
        }
        drainWriteQueue()
    }

    private func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    /// Hand queued chunks to the radio while it says it can take them.
    ///
    /// With-response writes are queued by CoreBluetooth itself and never dropped,
    /// so those drain in one go.
    private func drainWriteQueue() {
        guard let peripheral, let writeCharacteristic else {
            writeQueue.removeAll()
            return
        }
        let type = writeType(for: writeCharacteristic)
        while !writeQueue.isEmpty {
            if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                return          // resumed by peripheralIsReady(toSendWriteWithoutResponse:)
            }
            peripheral.writeValue(writeQueue.removeFirst(), for: writeCharacteristic, type: type)
        }
    }

    // MARK: - Raw byte mode (binary transfers)

    /// Take over the incoming stream, byte for byte, until `endRawByteMode()`.
    ///
    /// Marks the manager busy for the duration: only one transfer at a time, and a
    /// second sink would silently steal the first one's replies. Returns false when
    /// something else already holds the stream.
    @discardableResult
    func beginRawByteMode(_ sink: @escaping @MainActor (Data) -> Void) -> Bool {
        guard !isBusy, rawByteSink == nil else { return false }
        finishCollecting()          // no text request may be left waiting on this stream
        isBusy = true
        rawByteSink = sink
        return true
    }

    func endRawByteMode() {
        rawByteSink = nil
        isBusy = false
        rxLineBuffer.removeAll(keepingCapacity: true)
    }

    /// Write bytes verbatim, chunked to the MTU. Used by the Y-modem sender.
    func writeBytes(_ data: Data) { writeRaw(data) }

    /// Echo a line into the Terminal from a transfer that owns the raw stream.
    func log(_ text: String, kind: TerminalLine.Kind = .received) {
        appendOutput(text, kind: kind)
    }

    // MARK: - Request / response

    /// The Bruce serial parser has no reply delimiter, so a response is defined
    /// as "everything received until the device goes quiet." Collection starts
    /// on the first received line and completes after `quiet` seconds of silence,
    /// bounded by an overall `timeout`. Output still flows to the Terminal too.

    private var collectBuffer: [String] = []
    private var collectContinuation: CheckedContinuation<[String], Never>?
    private var collectToken = 0
    private var collectQuiet: TimeInterval = 0.6
    private var quietWork: DispatchWorkItem?
    /// When set, a request finishes as soon as this returns true for the buffer
    /// (and the quiet timer is not used — good for commands with a long lead-in
    /// like `ir rx`, which waits silently for the user to press the remote).
    private var collectCompletion: (([String]) -> Bool)?
    /// Whether lines gathered by the in-flight request also reach the Terminal.
    private var collectEcho = true
    private var isCollecting: Bool { collectContinuation != nil }

    /// Send a command and collect the device's reply lines.
    ///
    /// By default a response is "everything until the device goes quiet for
    /// `quiet` seconds". Pass `completedWhen` to instead finish as soon as the
    /// accumulated lines satisfy a predicate (no quiet timer) — use this when the
    /// device stays silent before producing output.
    ///
    /// `echo` false keeps both the command and its reply out of the Terminal, for
    /// bulk traffic such as a screen dump that would otherwise flush the log.
    @discardableResult
    func request(
        _ command: BruceCommand,
        quiet: TimeInterval = 0.6,
        timeout: TimeInterval = 12,
        echo: Bool = true,
        completedWhen: (([String]) -> Bool)? = nil
    ) async -> [String] {
        await withCheckedContinuation { continuation in
            beginCollecting(quiet: quiet, timeout: timeout, echo: echo,
                            completion: completedWhen, continuation: continuation)
            send(command, echo: echo)
        }
    }

    /// Refresh the device-side file index for the library's known folders.
    ///
    /// Lists each folder quietly (kept out of the Terminal) and records the file
    /// names present, so the library can flag which captures are already on the
    /// Bruce. Missing folders simply contribute nothing — the listing of an absent
    /// path returns no entries, which is the correct "nothing there" answer.
    ///
    /// Concurrent callers are collapsed onto one run: `beginCollecting` resolves any
    /// in-flight request before starting the next, so two overlapping refreshes would
    /// cut each other's listings short and publish an index of folders marked scanned
    /// but empty — every item then reads as "not on the device".
    func refreshDeviceIndex(folders: [String]) async {
        guard state == .ready else {
            // Nothing can be verified while disconnected; drop the stale index so
            // items fall back to "unknown" instead of a remembered answer.
            deviceFiles.removeAll()
            scannedFolders.removeAll()
            storageReport = nil
            return
        }
        // Same reason as the overview: every `storage list` ends in a forced menu
        // repaint on the device, which is the last thing the mirror needs.
        guard !screen.isStreaming else { return }
        // Know the filesystem before listing it: the probe can invalidate the index
        // (it mounts a freshly inserted card), and a scan interleaved with it would
        // have its listings cut short by the shared request collector.
        await refreshStorageReport()
        if let running = indexTask {
            await running.value
            return
        }
        let task = Task { [weak self] in await self?.scanFolders(folders) ?? () }
        indexTask = task
        await task.value
        indexTask = nil
    }

    private func scanFolders(_ folders: [String]) async {
        var files: Set<String> = []
        var scanned: Set<String> = []
        for folder in folders {
            let lines = await request(StorageCommand.list(path: folder), echo: false)
            for entry in BruceFile.parseListing(lines, parent: folder) where !entry.isDirectory {
                files.insert(entry.path.lowercased())
            }
            scanned.insert(folder.lowercased())
        }
        // Merge rather than replace: a partial refresh (after an upload, say) must
        // not wipe what the other folders contributed and send their items back to
        // "unknown". Entries under the rescanned folders are dropped first so files
        // deleted on the device stop counting as synced.
        let prefixes = scanned.map { "\($0)/" }
        deviceFiles = deviceFiles
            .filter { path in !prefixes.contains { path.hasPrefix($0) } }
            .union(files)
        scannedFolders.formUnion(scanned)
    }

    /// Ask the device which filesystem it is using and how full both are.
    ///
    /// `storage free` is the only storage subcommand that names a filesystem, so
    /// this pair of calls is the app's only way to know whether a listing came from
    /// the SD card or from the internal LittleFS — every other `storage` command
    /// silently follows `getFsStorage()`.
    ///
    /// Cached until `force`, because the SD probe is not free of consequences: the
    /// firmware answers it through `setupSdCard()`, which mounts a card inserted
    /// after boot and from then on redirects every `storage` command to it. When
    /// that flips the active filesystem the file index is dropped — those entries
    /// describe the *other* storage and would report the wrong sync state.
    func refreshStorageReport(force: Bool = false) async {
        guard state == .ready else { storageReport = nil; return }
        if !force, storageReport != nil { return }
        // Never while the mirror is streaming. `storage free sd` is answered through
        // `setupSdCard()`, and on the T-Embed CC1101 the card sits on the *display's*
        // SPI bus (SDCARD_MOSI/MISO/SCK are the TFT's pins — see the board's
        // `pins_arduino.h`, and sd_functions' own "SDCard in the same Bus as TFT").
        // Mounting it from the serial task while the tft_logger task is drawing puts
        // two tasks on one bus, which is not a race worth taking for a capacity
        // reading. The probe simply waits for a quieter moment.
        guard !screen.isStreaming else { return }
        if let running = storageTask {
            await running.value
            return
        }
        let task = Task { [weak self] in await self?.probeStorage() ?? () }
        storageTask = task
        await task.value
        storageTask = nil
    }

    private func probeStorage() async {
        let sdLines = await request(StorageCommand.free(storage: .sd), echo: false)
        let sd = StorageSpace.parse(sdLines, for: .sd)
        let noCard = sdLines.contains { $0.localizedCaseInsensitiveContains("no sd card") }

        let fsLines = await request(StorageCommand.free(storage: .littleFS), echo: false)
        let littleFS = StorageSpace.parse(fsLines, for: .littleFS)

        // A device that answered nothing at all must not be reported as "LittleFS
        // only" — that reads identically to a real answer with no card.
        guard sd != nil || littleFS != nil || noCard else { storageReport = nil; return }

        let report = DeviceStorageReport(sd: sd, littleFS: littleFS)
        if report.active != storageReport?.active {
            deviceFiles.removeAll()
            scannedFolders.removeAll()
        }
        storageReport = report
    }

    /// Read everything the "Meu Bruce" screen shows: firmware build, memory,
    /// uptime, clock and storage.
    ///
    /// Five separate round trips, run in sequence — the firmware has no combined
    /// status output, and the request collector serves one at a time anyway. Each
    /// step publishes twice: `probeStep` before it starts, so the loading screen
    /// can name what is in flight, and `deviceStatus` after it lands, so a screen
    /// that stays up fills in rather than appearing all at once at the end.
    ///
    /// Kept off the Terminal (`echo: false`) so opening a screen does not bury
    /// whatever the user was reading there.
    /// `libraryFolders` are the device folders the phone's library has captures
    /// for; passing them in adds the sync scan as a final step. Empty means the
    /// library has nothing to compare, so that step is skipped entirely.
    func refreshDeviceOverview(force: Bool = false, libraryFolders: [String] = []) async {
        guard state == .ready else { deviceStatus = nil; probeStep = nil; return }
        // Kicked off first and never awaited: the charge is the one reading that does
        // not come over the serial link, so it lands while the commands below are
        // still going out — and it is still worth having on the paths that skip the
        // serial reads entirely. Without it a pull-to-refresh would leave the badge
        // in the status bar showing the charge from when the session started.
        refreshBatteryLevel()
        // Not while the screen mirror is running. `handleSerialCommands` calls
        // `backToMenu()` after every command that is not `nav`/`option`, so each of
        // these reads forces the device's main task to repaint its whole menu — and
        // with the mirror on, every repaint floods the 64-entry draw log and the BLE
        // link with it. Six reads at connect is a load spike the device does not
        // need while it is already busy drawing. The screen retries when the user
        // comes back to it, since `deviceStatus` is still nil.
        guard !screen.isStreaming else { return }
        if let running = overviewTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            await self?.probeOverview(force: force, libraryFolders: libraryFolders) ?? ()
        }
        overviewTask = task
        await task.value
        overviewTask = nil
    }

    private func probeOverview(force: Bool, libraryFolders: [String]) async {
        // Cleared however this ends — a disconnect mid-sequence must not leave the
        // screen spinning on a step that will never finish. The timestamp records
        // when the app last *asked*, partial answers included: that is what makes
        // a stale-looking screen explainable.
        defer {
            probeStep = nil
            lastOverviewRefresh = Date()
        }

        var status = DeviceStatus()
        probeStep = .info
        status.info = await readDeviceInfo()
        deviceStatus = status

        probeStep = .memory
        status.memory = DeviceMemory.parse(await request(SystemCommand.free, echo: false))
        deviceStatus = status

        probeStep = .uptime
        status.uptime = DeviceStatus.parseUptime(await request(SystemCommand.uptime, echo: false))
        deviceStatus = status

        probeStep = .clock
        status.clock = DeviceStatus.parseClock(await request(SystemCommand.date, echo: false))
        deviceStatus = status

        probeStep = .storage
        await refreshStorageReport(force: force)

        guard !libraryFolders.isEmpty else { return }
        probeStep = .library
        await refreshDeviceIndex(folders: libraryFolders)
    }

    /// `info`, retried once when it answers nothing.
    ///
    /// Belt and braces next to the readiness fix: an unanswered first command
    /// leaves the whole "Dispositivo" section blank, which reads as "this device
    /// reports nothing about itself" rather than as a dropped reply.
    private func readDeviceInfo(attempts: Int = 2) async -> DeviceInfo {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            let info = DeviceInfo.parse(await request(SystemCommand.info, echo: false))
            if !info.isEmpty { return info }
        }
        return DeviceInfo()
    }

    /// The sync state of a library item against the last device index.
    func syncState(for item: LibraryItem) -> SyncState {
        guard let folder = LibraryCategory.of(item).deviceFolder else { return .unknown }
        guard scannedFolders.contains(folder.lowercased()) else { return .unknown }
        let path = BruceFile.join(folder, item.name).lowercased()
        return deviceFiles.contains(path) ? .synced : .notSynced
    }

    /// Upload a text file via `storage write` (paced, `EOF`-terminated).
    /// Returns the device's reply lines (contains "File written" on success).
    @discardableResult
    func uploadTextFile(path: String, content: String, timeout: TimeInterval = 12) async -> [String] {
        let size = Data(content.utf8).count + 1024   // firmware caps the buffer at `size`
        return await streamPayload(header: StorageCommand.write(path: path, size: size).serialLine,
                                   content: content, timeout: timeout)
    }

    /// Save text to the device, retrying until the firmware acknowledges it.
    ///
    /// Creates the parent directory first. Reliability matters because Bruce's BLE
    /// RX is fragile — but this runs **once** (e.g. saving a learned `.ir`), after
    /// which playback is a single dependable command (`ir tx_from_file`).
    func saveTextFileVerified(path: String, content: String, attempts: Int = 3) async -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty, dir != "/" { _ = await request(StorageCommand.mkdir(path: dir)) }
        for _ in 0..<attempts {
            let ack = await uploadTextFile(path: path, content: content)
            if ack.contains(where: { $0.localizedCaseInsensitiveContains("File written") }) { return true }
        }
        return false
    }

    /// Transmit an in-memory `.ir` capture via `ir tx_from_buffer` — replays
    /// signals that carry a `state` (air conditioners) or raw data. Less reliable
    /// than a saved file; prefer `saveTextFileVerified` + `ir tx_from_file`.
    @discardableResult
    func transmitIRBuffer(content: String, timeout: TimeInterval = 12) async -> [String] {
        await streamPayload(header: "ir tx_from_buffer", content: content, timeout: timeout)
    }

    /// Fire an IR button's action on the device.
    func perform(_ action: IRButtonAction) {
        switch action {
        case let .decoded(proto, address, command):
            send(IRCommand.tx(protocol: proto, address: address, command: command))
        case let .file(path):
            guard !isBusy else { return }
            if path.lowercased().hasSuffix(".ir") {
                Task { await transmitIRFile(path: path) }
            } else {
                send(IRCommand.txFromFile(path: path))
            }
        case let .buffer(content):
            guard !isBusy else { return }
            Task { await transmitIRBuffer(content: content) }
        }
    }

    /// Replay a `.ir` file from storage, automatically choosing the most reliable
    /// path for each signal type:
    /// - `ir tx_raw` for raw captures (headless, avoids the tx_from_buffer UI bug).
    /// - `ir tx_from_file` for simple decoded frames.
    /// - Rewrites A/C `state:` captures as `value:` and replays from storage,
    ///   because the firmware's `txIrFile` parser ignores `state:` lines.
    @discardableResult
    func transmitIRFile(path: String, timeout: TimeInterval = 12) async -> Bool {
        let lines = await request(StorageCommand.read(path: path), timeout: 20)
        let content = lines.joined(separator: "\n")
        let capture = IRCapture.parse(lines)

        guard capture.isValid else { return false }

        // RAW: direct headless transmission, no file parser involved.
        if capture.type == "raw",
           let frequency = capture.frequency,
           let data = capture.rawData {
            send(IRCommand.txRaw(frequency: frequency, data: data))
            return true
        }

        // Simple decoded frame: single-command file replay is reliable.
        if capture.isSimpleDecoded {
            let reply = await request(IRCommand.txFromFile(path: path), timeout: timeout)
            return reply.contains {
                $0.localizedCaseInsensitiveContains("sent")
                || $0.localizedCaseInsensitiveContains("command")
                || $0.localizedCaseInsensitiveContains("opened")
            }
        }

        // A/C or other state-based frame: txIrFile only understands `value:`.
        // Patch a temp copy and replay it headlessly.
        if capture.hasState, let state = capture.state {
            let tempPath = BruceFolder.path(BruceFolder.ir, ".tmp_state.ir")
            let patched = content.replacingOccurrences(of: "state: \(state)", with: "value: \(state)")
            guard await saveTextFileVerified(path: tempPath, content: patched) else { return false }
            let reply = await request(IRCommand.txFromFile(path: tempPath), timeout: timeout)
            _ = await request(StorageCommand.remove(path: tempPath))
            return reply.contains {
                $0.localizedCaseInsensitiveContains("sent")
                || $0.localizedCaseInsensitiveContains("command")
                || $0.localizedCaseInsensitiveContains("opened")
            }
        }

        return false
    }

    // MARK: - Screen mirror

    /// Begin mirroring the device display.
    ///
    /// `display start` is what allocates the draw log in the first place — the
    /// firmware offers no way to log without also streaming — and it starts from an
    /// empty buffer, so nothing is known about the current screen until something
    /// repaints it. `forceRepaint` supplies that first frame.
    ///
    /// The `display stop` in front is not redundant. Streaming is device-side state
    /// that outlives this app: a session that ends without stopping it — the app
    /// backgrounded or force-quit, the link dropped, the device reset — leaves the
    /// logger enabled and pushing into a `serialDevice` nobody is draining, and its
    /// 64-entry queue fills. `xQueueSend` in the logger uses a timeout of 0, so from
    /// then on every draw call is dropped in silence: reconnecting and issuing
    /// `display start` again finds logging already on, changes nothing, and the
    /// mirror stays blank until the device is power-cycled. Stopping first tears the
    /// log down so `start` builds a fresh one.
    func startScreenMirror() async {
        guard state == .ready else { return }
        send(DisplayCommand.stop, echo: false)
        try? await Task.sleep(for: .milliseconds(200))
        guard state == .ready else { return }
        send(DisplayCommand.start, echo: false)
        screen.isStreaming = true
        try? await Task.sleep(for: .milliseconds(250))
        await forceRepaint()
    }

    /// Stop streaming and let the device release the log buffer.
    func stopScreenMirror() {
        screen.isStreaming = false
        guard state == .ready else { return }
        send(DisplayCommand.stop, echo: false)
    }

    /// Press a device button.
    ///
    /// Nothing is read back: the repaint the press causes arrives on its own
    /// through the draw stream.
    func press(_ nav: NavCommand, longPress: Bool = false) {
        guard state == .ready else { return }
        let command: BruceCommand = longPress ? nav.held() : nav
        send(command, echo: false)
    }

    /// Make the device repaint, so the whole screen is re-streamed.
    ///
    /// Stepping one item forward and straight back leaves the selection where it
    /// was while forcing a full redraw — the same warm-up the firmware's own
    /// reference navigator (`sd_files/esp32_serial_navigator.html`) performs.
    ///
    /// This exists because `display dump`, the obvious way to re-read the screen,
    /// **panics the device**: its callback puts a `MAX_LOG_ENTRIES * MAX_LOG_SIZE`
    /// buffer on the stack, which on a PSRAM board is 8192 bytes — the entire
    /// `SERIAL_CMDS_TASK_STACK_SIZE`. Boards without PSRAM use smaller limits and
    /// survive, which is why the command looks usable.
    ///
    /// Nothing is lost by avoiding it: `fillScreen` calls `clearLog()`, so the
    /// device's log resets on each full repaint exactly as `TFTScreen` does, and
    /// the deduplication in `pushLogIfUnique` can only suppress draw calls this
    /// side already holds.
    func forceRepaint() async {
        guard state == .ready else { return }
        send(NavCommand.next, echo: false)
        try? await Task.sleep(for: .milliseconds(180))
        send(NavCommand.previous, echo: false)
    }

    /// Shared streaming path for `storage write` / `ir tx_from_buffer`.
    ///
    /// The firmware's BLE RX now has a proper byte FIFO and a `readStringUntil`
    /// that consumes and strips the terminator, so we use the standard protocol:
    /// one `\n`-terminated line per write, then `EOF\n`. Operations are still
    /// serialized (`isBusy`) and we wait for the device's "Reading input…" notice
    /// before streaming so no line is misread as a command.
    private func streamPayload(header: String, content: String, timeout: TimeInterval) async -> [String] {
        guard writeCharacteristic != nil, !isBusy else { return [] }  // serialize; no overlap
        isBusy = true
        defer { isBusy = false }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        // 1) Issue the command and wait until the firmware is actually reading.
        let lead = await withCheckedContinuation { continuation in
            beginCollecting(quiet: 0.6, timeout: 4, completion: { buffer in
                buffer.contains { $0.lowercased().contains("reading input") }
            }, continuation: continuation)
            send(header)
        }

        // Strict gate: if the device never entered its read loop, abort rather
        // than stream lines that the command parser would misread as commands.
        guard lead.contains(where: { $0.lowercased().contains("reading input") }) else {
            return []
        }

        // 2) Stream one line per write, each terminated by a real newline (0x0A).
        for line in lines {
            writeRaw(Data((line + "\n").utf8))
            try? await Task.sleep(for: .milliseconds(40))
        }

        // 3) Terminate with "EOF\n" and collect the acknowledgement.
        return await withCheckedContinuation { continuation in
            beginCollecting(quiet: 0.8, timeout: timeout, completion: nil, continuation: continuation)
            writeRaw(Data("EOF\n".utf8))
        }
    }

    private func beginCollecting(
        quiet: TimeInterval,
        timeout: TimeInterval,
        echo: Bool = true,
        completion: (([String]) -> Bool)?,
        continuation: CheckedContinuation<[String], Never>
    ) {
        finishCollecting()                 // resolve any in-flight request first
        collectToken += 1
        let token = collectToken
        collectContinuation = continuation
        collectBuffer = []
        collectQuiet = quiet
        collectCompletion = completion
        collectEcho = echo
        // Overall cap: fires even if the device never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.collectToken == token else { return }
            self.finishCollecting()
        }
    }

    /// Restart the quiet timer after each received line.
    private func scheduleQuiet() {
        let token = collectToken
        quietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.collectToken == token else { return }
            self.finishCollecting()
        }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collectQuiet, execute: work)
    }

    private func finishCollecting() {
        guard let continuation = collectContinuation else { return }
        collectContinuation = nil
        collectCompletion = nil
        collectEcho = true
        quietWork?.cancel()
        quietWork = nil
        let result = collectBuffer
        collectBuffer = []
        continuation.resume(returning: result)
    }

    // MARK: - Output handling

    /// Split incoming bytes into screen packets and text lines.
    ///
    /// With the screen mirror running the device interleaves binary draw packets
    /// with ordinary output on this one characteristic, so the split happens at the
    /// byte level: decoding the chunk as UTF-8 up front would fail outright the
    /// moment it carried packet bytes, discarding the text along with them.
    private func handleTX(_ data: Data) {
        // A binary transfer owns the stream while it runs: Y-modem's replies are
        // bare bytes (`C`, ACK, NAK) with no newline, which the line assembler
        // would hold forever, and whose values the screen demuxer could mistake
        // for packet markers.
        if let sink = rawByteSink {
            sink(data)
            return
        }

        let (text, packets) = demuxer.consume(data)
        for packet in packets { screen.ingest(packet: packet) }

        rxLineBuffer.append(contentsOf: text)

        while let newline = rxLineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            // Decode leniently: a multi-byte character split across two BLE
            // notifications must cost at most a glyph, never the whole line.
            var line = String(decoding: rxLineBuffer[..<newline], as: UTF8.self)
            rxLineBuffer.removeFirst(newline + 1)

            // The firmware prints "# " as a prompt after each command *without* a
            // newline, so it arrives glued to the first line of the next response
            // ("# gree_ac.ir\t156"). Strip it so parsers see clean data. A lone "#"
            // is preserved — it is a real separator inside `.ir`/`.sub` files.
            while line.hasPrefix("# ") { line.removeFirst(2) }

            if line.isEmpty { continue }
            if !isCollecting || collectEcho {
                appendOutput(line, kind: .received)
            }
            if isCollecting {
                collectBuffer.append(line)
                if let completion = collectCompletion {
                    if completion(collectBuffer) { finishCollecting() }
                } else {
                    scheduleQuiet()
                }
            }
        }
    }

    // MARK: - Readiness

    /// Become ready only once the notify characteristic is *actually* notifying.
    ///
    /// Discovering a characteristic and subscribing to it are two different
    /// events: `setNotifyValue(true:)` is a request, and until the peripheral
    /// confirms it, anything written gets an answer nobody is listening for. The
    /// symptom was precise — after connecting, the first command of a sequence
    /// (`info`, feeding the "Dispositivo" section) came back empty while every
    /// later one worked.
    private func updateReadiness() {
        guard state != .ready,
              writeCharacteristic != nil,
              let notify = notifyCharacteristic, notify.isNotifying
        else { return }
        readinessFallback?.cancel()
        readinessFallback = nil
        state = .ready
    }

    /// Don't hang forever on a peripheral that never reports `isNotifying`:
    /// after this, having both characteristics is taken as good enough.
    private func scheduleReadinessFallback() {
        readinessFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .ready,
                  self.writeCharacteristic != nil, self.notifyCharacteristic != nil
            else { return }
            self.state = .ready
        }
        readinessFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func appendOutput(_ text: String, kind: TerminalLine.Kind) {
        lines.append(TerminalLine(text: text, kind: kind))
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:    if state == .poweredOff { state = .idle }
            case .poweredOff:   state = .poweredOff
            case .unauthorized: state = .unauthorized
            default:            break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            guard BruceBLE.matchesName(advName) || BruceBLE.matchesName(peripheral.name) else { return }

            central.stopScan()
            self.peripheral = peripheral
            self.deviceName = peripheral.name ?? advName ?? BruceBLE.advertisedName
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .discovering
            peripheral.discoverServices(BruceBLE.servicesToDiscover)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            finishCollecting()
            readinessFallback?.cancel()
            readinessFallback = nil
            writeQueue.removeAll()
            self.peripheral = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            batteryCharacteristic = nil
            batteryLevel = nil
            rxLineBuffer.removeAll(keepingCapacity: true)
            demuxer.reset()
            screen.clear()
            deviceFiles.removeAll()
            scannedFolders.removeAll()
            storageReport = nil
            deviceStatus = nil
            probeStep = nil
            lastOverviewRefresh = nil
            state = .disconnected
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated { state = .disconnected }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                switch service.uuid {
                case BruceBLE.serialService:
                    peripheral.discoverCharacteristics([BruceBLE.serialCharacteristic], for: service)
                case BruceBLE.nusService:
                    peripheral.discoverCharacteristics([BruceBLE.nusRX, BruceBLE.nusTX], for: service)
                case BruceBLE.batteryService:
                    peripheral.discoverCharacteristics([BruceBLE.batteryLevel], for: service)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case BruceBLE.serialCharacteristic:          // custom: one char, both directions
                    writeCharacteristic = characteristic
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case BruceBLE.nusRX:                         // NUS: write side
                    writeCharacteristic = characteristic
                case BruceBLE.nusTX:                         // NUS: notify side
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case BruceBLE.batteryLevel:
                    batteryCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }
            if writeCharacteristic != nil && notifyCharacteristic != nil {
                scheduleReadinessFallback()
                updateReadiness()
            }
        }
    }

    /// Subscription confirmed — usually what actually flips the link to ready.
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated { updateReadiness() }
    }

    /// The radio can take more write-without-response payloads.
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { drainWriteQueue() }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value else { return }
            if characteristic.uuid == BruceBLE.batteryLevel {
                batteryLevel = data.first.map(Int.init)
            } else if characteristic.uuid == notifyCharacteristic?.uuid {
                handleTX(data)
            }
        }
    }
}
