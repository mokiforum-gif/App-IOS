import Foundation

/// A typed command that renders to a single Bruce serial line.
///
/// Instead of concatenating loose strings across the UI, each module models its
/// operations as an enum that conforms to `BruceCommand` and knows how to render
/// itself (`serialLine`). `BLEManager.send(_:)` accepts any `BruceCommand`, so
/// the transport never sees hand-built text.
///
/// The line syntax mirrors the Bruce firmware serial parser
/// (`handleSerialCommands`), which is largely Flipper-CLI compatible. When in
/// doubt, `RawCommand` is an escape hatch that passes text through verbatim, and
/// the raw Terminal remains available for anything not modeled here.
protocol BruceCommand {
    /// The exact line written to the RX characteristic (without the trailing `\n`,
    /// which the transport appends).
    var serialLine: String { get }
}

/// Passes an arbitrary line straight through — the same path the raw Terminal uses.
struct RawCommand: BruceCommand {
    let line: String
    var serialLine: String { line }
}

// MARK: - Infrared (CC1101-independent, IR transceiver)

enum IRCommand: BruceCommand {
    /// Listen for an incoming IR frame. Bruce decodes and prints it.
    case rx
    /// Listen in RAW mode (captures the timing train instead of decoding).
    ///
    /// Required for air conditioners: Bruce's own IR Read forces raw whenever
    /// `hasACState(protocol)` is true, because replaying an A/C from its parsed
    /// `state` does not reliably drive the unit. Raw replays the waveform.
    ///
    /// Bruce's SimpleCLI flags require a leading `-`, so the correct serial
    /// syntax is `ir rx -raw`. Without the dash the flag is not recognized and
    /// the command fails silently / returns nothing.
    case rxRaw
    /// Replay a captured `.ir` file from storage.
    case txFromFile(path: String)
    /// Transmit a decoded frame directly. Firmware requires `address` and
    /// `command` to be exactly 8 hex chars: `ir tx NEC 04000000 08000000`.
    case tx(protocol: String, address: String, command: String)
    /// Transmit a raw timing train directly (headless, no file parser).
    case txRaw(frequency: Int, data: String)

    var serialLine: String {
        switch self {
        case .rx:
            return "ir rx"
        case .rxRaw:
            return "ir rx -raw"
        case .txRaw(let frequency, let data):
            // `samples` must be quoted: SimpleCLI otherwise stops at the first
            // space and treats the rest of the timing train as stray arguments.
            return "ir tx_raw -frequency \(frequency) -samples \"\(data)\""
        case .txFromFile(let path):
            // The firmware's `irTxFileCallback` expects the string "true"/"false"
            // for hideDefaultUI and tests it as a String, not a bool:
            // `bool hideDefaultUI = !hideDefaultUIStr.equalsIgnoreCase("false");`
            // Pass "true" to keep the on-device UI hidden (headless), avoiding
            // the "Running, Wait" pause that needs a physical button press.
            return "ir tx_from_file \(path.quotedIfNeeded) true"
        case .tx(let proto, let address, let command):
            return "ir tx \(proto) \(address) \(command)"
        }
    }
}

// MARK: - Sub-GHz (CC1101). Alias on the firmware side: `rf`.

enum SubGHzCommand: BruceCommand {
    /// Listen on the configured frequency and print received frames.
    case rx
    /// Replay a captured `.sub` file from storage.
    case txFromFile(path: String)
    /// Transmit a decoded frame. Firmware syntax: `subghz tx <value> <freq> <te> <count>`.
    case tx(value: String, frequency: Int, te: Int, count: Int)

    var serialLine: String {
        switch self {
        case .rx:
            return "subghz rx"
        case .txFromFile(let path):
            return "subghz tx_from_file \(path.quotedIfNeeded) true"   // headless (see IRCommand)
        case .tx(let value, let frequency, let te, let count):
            return "subghz tx \(value) \(frequency) \(te) \(count)"
        }
    }
}

// MARK: - Storage (microSD / LittleFS)
//
// Mirrors the Bruce `storage` composite command. Paths are absolute from the root
// of *one* filesystem — the device picks it in `getFsStorage()` (SD when a card is
// mounted, LittleFS otherwise) and no path or flag can override that. `free` is
// the single exception: it names the filesystem it reports on, which is what lets
// the app tell the user which one it is browsing. See `DeviceStorage`.

enum StorageCommand: BruceCommand {
    case list(path: String)
    case read(path: String)
    case remove(path: String)
    case mkdir(path: String)
    case rmdir(path: String)
    case rename(from: String, to: String)
    /// Header only — the payload bytes are streamed separately, then an `EOF`
    /// line terminates the transfer. See `BLEManager.uploadTextFile`.
    case write(path: String, size: Int)
    /// Open a Y-modem receive session on `path`. The bytes follow as framed
    /// blocks, not as text — see `BLEManager.sendFileYModem`.
    case ymodem(path: String)
    /// Space report for one filesystem.
    ///
    /// Note the side effect on `.sd`: the firmware's callback calls `setupSdCard()`,
    /// so probing mounts a card that was inserted after boot — and thereby switches
    /// every later `storage` command from LittleFS to the SD.
    case free(storage: DeviceStorage)

    var serialLine: String {
        switch self {
        case .list(let p):   return "storage list \(p.quotedIfNeeded)"
        case .read(let p):   return "storage read \(p.quotedIfNeeded)"
        case .remove(let p): return "storage remove \(p.quotedIfNeeded)"
        case .mkdir(let p):  return "storage mkdir \(p.quotedIfNeeded)"
        case .rmdir(let p):  return "storage rmdir \(p.quotedIfNeeded)"
        case .rename(let f, let t): return "storage rename \(f.quotedIfNeeded) \(t.quotedIfNeeded)"
        case .write(let p, let s):  return "storage write \(p.quotedIfNeeded) \(s)"
        case .ymodem(let p):        return "storage ymodem \(p.quotedIfNeeded)"
        case .free(let storage):    return "storage free \(storage.commandArgument)"
        }
    }
}

// MARK: - NFC / RFID
//
// Mirrors the firmware's `rfid` composite command (`rfid_commands.cpp`, aliased
// as `nfc`). The driver keeps the last read tag in memory, so most operations are
// two steps: put a tag in the module's state (`read` or `loadfile`), then act on
// it (`write`, `clone`, `emulate`, `save`).

enum RFIDCommand: BruceCommand {
    /// Wait for a tag and dump it. The firmware polls until `timeout` ms elapse.
    case read(timeout: Int)
    /// Re-print the tag currently held in the driver's memory.
    case info
    /// Write the loaded dump back to a tag of the same type.
    case write(timeout: Int)
    /// Write the loaded UID onto a "magic" (writable-UID) card.
    case clone(timeout: Int)
    /// Emulate the loaded tag.
    ///
    /// This **blocks the device's serial task** for up to 60 s (or until ESC is
    /// pressed on the Bruce itself) — no other command is served meanwhile.
    case emulate
    /// Wipe the tag on the reader.
    case erase
    /// Load a saved dump from storage into the driver.
    case loadFile(path: String)
    /// Ask the firmware to write the loaded dump to `/BruceRFID/<name>.rfid`.
    /// The device appends `_1`, `_2`… if the name is taken, so the resulting
    /// filename is not knowable from the reply.
    case save(name: String, flipperFormat: Bool)
    /// Drop the driver instance, forcing a re-init on the next command.
    case reset

    var serialLine: String {
        switch self {
        case .read(let t):   return "rfid read \(t)"
        case .info:          return "rfid info"
        case .write(let t):  return "rfid write \(t)"
        case .clone(let t):  return "rfid clone \(t)"
        case .emulate:       return "rfid emulate"
        case .erase:         return "rfid erase"
        case .loadFile(let p): return "rfid loadfile \(p.quotedIfNeeded)"
        case .save(let n, let flipper):
            return "rfid save \(n.quotedIfNeeded) \(flipper ? "flipper" : "bruce")"
        case .reset:         return "rfid reset"
        }
    }
}

// MARK: - System / diagnostics

enum SystemCommand: BruceCommand, CaseIterable {
    case info
    case free
    case uptime
    case date

    var serialLine: String {
        switch self {
        case .info:   return "info"
        case .free:   return "free"
        case .uptime: return "uptime"
        case .date:   return "date"
        }
    }

    /// Short label for a quick-action button.
    var label: String {
        switch self {
        case .info:   return "Info"
        case .free:   return L10n.t("Memória")
        case .uptime: return "Uptime"
        case .date:   return L10n.t("Data/Hora")
        }
    }
}

// MARK: - Power

enum PowerCommand: BruceCommand {
    case off, reboot, sleep
    var serialLine: String {
        switch self {
        case .off:    return "power off"
        case .reboot: return "power reboot"
        case .sleep:  return "power sleep"
        }
    }
}

// MARK: - Audio (speaker)

enum AudioCommand: BruceCommand {
    case say(String)
    case tone(frequency: Int, duration: Int)
    case music(path: String)
    var serialLine: String {
        switch self {
        case .say(let text):           return "say \(text)"
        case .tone(let freq, let dur): return "tone \(freq) \(dur)"
        case .music(let path):         return "music_player \(path.quotedIfNeeded)"
        }
    }
}

// MARK: - RGB LED

/// The board's RGB LED, driven by the composite `led` command
/// (`src/core/serial_commands/led_commands.cpp`, compiled only where the board
/// defines `HAS_RGB_LED` — elsewhere the whole command is absent).
///
/// Every subcommand goes through a `bruceConfig` setter and each setter calls
/// `saveFile()`, so a choice made here survives a reboot — and a UI that streamed
/// one command per drag frame would be writing the config file all the way down
/// the slider. `LEDView` applies on release for exactly that reason.
///
/// The per-channel form (`led r 255`, which keeps the other two channels) is not
/// modeled: the app always knows the full color it is showing, so it states all
/// three at once and stays in sync with what the picker displays.
enum LEDCommand: BruceCommand {
    /// All three channels, 0–255 each. The firmware used to accept a bare
    /// `led <r> <g> <b>`; `led` became a composite command and now answers only to
    /// its subcommands, so the old form fails to parse.
    case rgb(r: Int, g: Int, b: Int)
    /// 0–100, the same scale as the device's LED brightness menu.
    case brightness(Int)
    case effect(LEDEffect)
    /// The color menu's "OFF" — sets the color to black. The effect stays selected,
    /// so this is "dark", not "back to solid".
    case off

    var serialLine: String {
        switch self {
        case .rgb(let r, let g, let b): return "led rgb \(r) \(g) \(b)"
        case .brightness(let value):    return "led brightness \(value)"
        case .effect(let effect):       return "led effect \(effect.rawValue)"
        case .off:                      return "led off"
        }
    }
}

// MARK: - WiFi / network

enum WiFiCommand: BruceCommand {
    case on, off
    case add(ssid: String, password: String)
    case arp, listen, sniffer, webui
    var serialLine: String {
        switch self {
        case .on:                    return "wifi on"
        case .off:                   return "wifi off"
        case .add(let ssid, let pw): return "wifi add \"\(ssid)\" \"\(pw)\""
        case .arp:                   return "arp"
        case .listen:                return "listen"
        case .sniffer:               return "sniffer"
        case .webui:                 return "webui"
        }
    }
}

// MARK: - GPIO / I2C

enum GPIOCommand: BruceCommand {
    case mode(pin: Int, value: Int)
    case set(pin: Int, value: Int)
    var serialLine: String {
        switch self {
        case .mode(let pin, let value): return "gpio mode \(pin) \(value)"
        case .set(let pin, let value):  return "gpio set \(pin) \(value)"
        }
    }
}

enum I2CCommand: BruceCommand {
    case scan
    var serialLine: String { "i2c scan" }
}

// MARK: - Remote control (input injection + screen mirror)

/// Pushes a button press into the device's own input queue.
///
/// `navCallback` (`src/core/serial_commands/util_commands.cpp`) raises the matching
/// `*Press` global and holds it for `duration` milliseconds, so the firmware reacts
/// exactly as it would to the physical encoder or buttons — this drives the real
/// menus, not a parallel command surface.
enum NavCommand: BruceCommand, CaseIterable {
    case up, down
    /// Encoder counter-clockwise / clockwise on hardware that has one.
    case previous, next
    case select, escape
    /// Page jumps. Not surfaced in the remote's UI: on this firmware only the SD
    /// file browser and the PN532 module read `NextPagePress`/`PrevPagePress`, so
    /// the buttons did nothing on every menu.
    case previousPage, nextPage

    /// Hold time that the firmware reads as a long press.
    static let longPressDuration = 600

    /// The token the firmware's parser matches on.
    var key: String {
        switch self {
        case .up:           return "up"
        case .down:         return "down"
        case .previous:     return "prev"
        case .next:         return "next"
        case .select:       return "sel"
        case .escape:       return "esc"
        case .previousPage: return "prevpage"
        case .nextPage:     return "nextpage"
        }
    }

    var serialLine: String { "nav \(key)" }

    /// The same press, held down for `milliseconds`.
    func held(for milliseconds: Int = NavCommand.longPressDuration) -> RawCommand {
        RawCommand(line: "nav \(key) \(milliseconds)")
    }
}

/// Controls the TFT draw log that backs the screen mirror.
///
/// Bruce logs display calls instead of exposing a framebuffer: `start` pushes them
/// to the serial device as the UI paints, over BLE when the BLE API is active. See
/// `TFTFrame.swift` for the wire format.
///
/// The firmware's fourth subcommand, `display dump`, is deliberately absent: it
/// puts a `MAX_LOG_ENTRIES * MAX_LOG_SIZE` buffer on the stack, which on a PSRAM
/// board exactly equals `SERIAL_CMDS_TASK_STACK_SIZE`, and resets the device.
enum DisplayCommand: BruceCommand {
    case start, stop, status, info

    var serialLine: String {
        switch self {
        case .start:  return "display start"
        case .stop:   return "display stop"
        case .status: return "display status"
        case .info:   return "display info"
        }
    }
}

/// Device-side display settings (`src/core/serial_commands/screen_commands.cpp`).
///
/// Unlike the LED, none of this is persisted: the color callbacks assign
/// `bruceConfig.priColor` directly ("change global var, dont save in config") and
/// the backlight is set with `save = false`. Both are back to the stored values
/// after a reboot.
enum ScreenCommand: BruceCommand {
    /// Backlight on Flipper's raw 0–255 scale. Prefer `brightness(percent:)`.
    case brightness(Int)
    /// UI accent color as a 6-digit hex string, without a leading `#`.
    case colorHex(String)
    /// UI accent color, 0–255 per channel. The firmware squeezes it through
    /// `tft.color565`, so the shade the device ends up with is the nearest 16-bit
    /// one — close, not identical.
    case color(r: Int, g: Int, b: Int)
    /// Prints the device clock over serial. Nothing is drawn on the display.
    case clock

    var serialLine: String {
        switch self {
        case .brightness(let value):      return "screen brightness \(value)"
        case .colorHex(let hex):          return "screen color hex \(hex)"
        case .color(let r, let g, let b): return "screen color rgb \(r) \(g) \(b)"
        case .clock:                      return "clock"
        }
    }

    /// The backlight the way the UI talks about it.
    ///
    /// The command takes 0–255 for Flipper compatibility but the firmware
    /// immediately rescales it (`value * 100 / 255`, clamped to 1–100) and reports
    /// the percentage back, so the percentage is the real unit — this converts once,
    /// here, instead of at every call site.
    static func brightness(percent: Int) -> ScreenCommand {
        .brightness(Int((Double(min(max(percent, 0), 100)) * 255 / 100).rounded()))
    }
}

// MARK: - Settings

enum SettingsCommand: BruceCommand {
    /// Dumps the whole config. Note the firmware serializes this one to `Serial`
    /// rather than to `serialDevice`, so over BLE it answers nothing — the reply
    /// only ever reaches a USB cable.
    case view
    /// One field, answered as `name = value` on `serialDevice` (so it does arrive
    /// over BLE). The names are the JSON keys of `BruceConfig::toJson` — see
    /// `DeviceSetting` for the ones the app reads.
    case get(name: String)
    case set(name: String, value: String)
    case factoryReset
    var serialLine: String {
        switch self {
        case .view:                   return "settings"
        case .get(let name):          return "settings \(name)"
        case .set(let name, let val): return "settings \(name) \(val)"
        case .factoryReset:           return "factory_reset"
        }
    }
}

// MARK: - JavaScript interpreter

/// Drives the on-device JS interpreter (`js,run,interpret/er`,
/// `src/core/serial_commands/interpreter_commands.cpp`).
///
/// The App Store installs a script under `/BruceJS/<Category>/<name>.js` and runs
/// it with `runFromFile`. `js <path>` (Flipper-compatible fallback) works too, but
/// the explicit subcommand is unambiguous when a path contains spaces.
enum JSCommand: BruceCommand {
    /// Execute a script already on the device storage.
    case runFromFile(path: String)
    /// Stop the running interpreter.
    case exit

    var serialLine: String {
        switch self {
        case .runFromFile(let path): return "js run_from_file \(path.quotedIfNeeded)"
        case .exit:                  return "js exit"
        }
    }
}

// MARK: - Helpers

extension String {
    /// Wraps a path in quotes when it contains whitespace, so the firmware parser
    /// treats it as a single argument.
    var quotedIfNeeded: String {
        contains(" ") ? "\"\(self)\"" : self
    }
}
