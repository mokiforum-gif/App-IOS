import SwiftUI

/// The "LEDs & Tela" module: the board's RGB LED and the color the device paints
/// its own interface with.
///
/// They are two different lights and two different firmware settings, so they get
/// two sections. `led …` writes the config (`saveFile()` on every setter), so a
/// color, brightness or effect chosen here survives a reboot; `screen color …`
/// only assigns `priColor` in memory, so that one does not. The screen says which
/// is which instead of leaving the user to discover it.
///
/// Nothing on this screen is guessed. The firmware has no getter for the LED or the
/// interface color, but `settings <field>` answers `field = value` on the active
/// serial device — so on open it reads `ledColor`, `ledBright`, `ledEffect`,
/// `priColor` and `bright` back and shows what the Bruce is really set to. Pull to
/// read them again.
struct LEDView: View {
    @EnvironmentObject private var ble: BLEManager

    // MARK: State

    @State private var ledColor: Color = BruceColor.purple
    @State private var ledBrightness: Double = 100
    @State private var effect: LEDEffect = .solid
    @State private var screenColor: Color = BruceColor.purple
    @State private var screenBrightness: Double = 100

    /// What the device was last *asked* for, kept so a value that is already set is
    /// not sent again.
    ///
    /// This is what makes a live color picker affordable: dragging it publishes
    /// dozens of colors, each of which would otherwise be a serial command, a
    /// config-file write and a forced menu repaint on the device. It also keeps the
    /// read-back from bouncing straight back at the Bruce — after a read these hold
    /// the values that were just read, so the debounced apply finds nothing to do.
    @State private var sentLED: UInt32?
    @State private var sentLEDBrightness: Int?
    @State private var sentEffect: LEDEffect?
    /// In RGB565, the only precision `priColor` actually has.
    @State private var sentScreen: UInt16?
    @State private var sentScreenBrightness: Int?

    @State private var isLoading = false
    @State private var didRead = false
    /// Whether the board has an RGB LED at all, once the read can tell — see
    /// `read()`. Nil while unknown, which is how it stays when disconnected.
    @State private var hasRGBLED: Bool?
    /// The template being applied, so its card can show progress.
    @State private var applying: LightingTemplate.ID?
    @State private var ledColorApply: Task<Void, Never>?
    @State private var screenColorApply: Task<Void, Never>?
    @State private var showFineTune = false
    /// Answer to the last `clock`, shown inline rather than only in the Terminal.
    @State private var clockReply: String?

    /// Long enough that a drag across the color wheel is one command instead of
    /// thirty, short enough that the LED still feels like it is following the finger.
    private let colorDebounce = Duration.milliseconds(450)

    private var isReady: Bool { ble.state == .ready }
    /// Controls stay put while a read or a template is in flight — both drive the
    /// shared request collector, which serves one caller at a time.
    private var isBlocked: Bool { !isReady || isLoading || applying != nil }
    /// Known to have no RGB LED, as opposed to not knowing yet.
    private var hasNoLED: Bool { hasRGBLED == false }

    // MARK: Body

    var body: some View {
        List {
            previewSection
            templatesSection
            ledSection
            effectSection
            screenSection
        }
        .scrollContentBackground(.hidden)
        .background(BruceColor.backdrop.ignoresSafeArea())
        .navigationTitle("LEDs & Tela")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .task(id: ble.state) { await readIfNeeded() }
        .refreshable { await read() }
        // The picker publishes every intermediate color while the wheel is being
        // dragged; the apply is debounced rather than driven from here.
        .onChange(of: ledColor) { _, _ in scheduleLEDColorApply() }
        .onChange(of: screenColor) { _, _ in scheduleScreenColorApply() }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ledTile
                    screenTile
                }
                statusLine
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(BruceColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// The LED as it should look right now: the chosen color for the effects that
    /// paint with it, and the effect's own palette for the ones that don't.
    private var ledTile: some View {
        VStack(spacing: 10) {
            ledOrbAnimated
                .opacity(hasNoLED ? 0.3 : 1)
            Text(hasNoLED ? "sem LED RGB" : effect.name)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
            // The reading itself is `verbatim`: a percentage is the same in every
            // language, and interpolating it into the key would put a format string
            // in the catalog for a translator to get wrong.
            (Text("brilho") + Text(verbatim: " \(Int(ledBrightness))%"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(BruceColor.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// Animated only for the effects that move, so a solid color does not pulse for
    /// no reason.
    @ViewBuilder
    private var ledOrbAnimated: some View {
        if effect == .solid {
            ledOrb
        } else {
            ledOrb.phaseAnimator([false, true]) { orb, lit in
                orb.scaleEffect(lit ? 1.05 : 0.95)
                    .opacity(lit ? 1 : 0.8)
            } animation: { _ in .easeInOut(duration: 1.1) }
        }
    }

    private var ledOrb: some View {
        Circle()
            .fill(ledFill)
            .frame(width: 58, height: 58)
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            // The glow is the brightness: a 10% LED should read as barely lit.
            .shadow(color: glowColor.opacity(isDark ? 0 : 0.25 + 0.55 * ledBrightness / 100),
                    radius: 18)
            .overlay {
                if isDark {
                    Image(systemName: "power")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: ledColor)
    }

    /// True when the LED is set to black — `led off` and a black color are the same
    /// thing to the firmware.
    private var isDark: Bool { ledColor.hex24 == 0 }

    private var ledFill: AnyShapeStyle {
        guard !effect.usesColor else { return AnyShapeStyle(ledColor) }
        // Fire builds its own reds; everything else in this group runs the hue wheel.
        let hues: [Color] = effect == .fire
            ? [Color(hex: 0xFF3B00), Color(hex: 0xFFC400), Color(hex: 0xFF6A00), Color(hex: 0xFF3B00)]
            : [.red, .yellow, .green, .cyan, .blue, .purple, .red]
        return AnyShapeStyle(AngularGradient(colors: hues, center: .center))
    }

    private var glowColor: Color {
        effect.usesColor ? ledColor : BruceColor.lilac
    }

    /// A stand-in for the device's own menu: a title bar and two rows, which is
    /// what `priColor` actually paints.
    private var screenTile: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(screenColor).frame(height: 7)
                RoundedRectangle(cornerRadius: 2).fill(screenColor.opacity(0.55)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(screenColor.opacity(0.55)).frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 66, height: 58)
            .background(.black, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(screenColor.opacity(0.6), lineWidth: 1.5))
            // The backlight, as a whole-panel dimming.
            .opacity(0.35 + 0.65 * screenBrightness / 100)
            .animation(.easeInOut(duration: 0.2), value: screenColor)

            Text("Interface")
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            (Text("brilho") + Text(verbatim: " \(Int(screenBrightness))%"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(BruceColor.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Lendo a configuração do Bruce…")
            } else if !isReady {
                Image(systemName: "bolt.horizontal.circle")
                Text("Conecte-se para ler e alterar.")
            } else if didRead {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(BruceColor.lilac)
                Text("Lido do dispositivo. Arraste para reler.")
            } else {
                Image(systemName: "questionmark.circle")
                Text("Sem leitura — arraste para baixo.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Templates

    private var templatesSection: some View {
        let templates = LightingPalette.templates
        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(templates) { template in
                        templateCard(template)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Templates")
        } footer: {
            Text("Um toque define a cor e o efeito dos LEDs e a cor da interface. O brilho fica como está.")
                .font(.caption)
        }
        .disabled(isBlocked)
    }

    private func templateCard(_ template: LightingTemplate) -> some View {
        Button {
            Task { await apply(template) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [template.led, template.screen],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
                    if applying == template.id {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: template.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                }
                Text(template.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.name)
    }

    // MARK: - LEDs

    private var ledSection: some View {
        Section {
            swatchGrid(isSelected: { $0.hex == ledColor.hex24 }) { swatch in
                setLEDColor(swatch.color)
            }

            ColorPicker("Cor personalizada", selection: $ledColor, supportsOpacity: false)

            DisclosureGroup("Ajuste fino (R/G/B)", isExpanded: $showFineTune) {
                channelSlider("R", .red)
                channelSlider("G", .green)
                channelSlider("B", .blue)
            }

            VStack(spacing: 2) {
                HStack {
                    Text("Brilho")
                    Spacer()
                    Text(verbatim: "\(Int(ledBrightness))%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $ledBrightness, in: 0...100, step: 1) { editing in
                        if !editing { applyLEDBrightness() }
                    }
                    .tint(BruceColor.purple)
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                setLEDColor(.black)
            } label: {
                Label("Desligar LEDs", systemImage: "power")
            }
        } header: {
            Text("LEDs")
        } footer: {
            Text(hasNoLED
                 ? "Esta placa não tem LED RGB: o firmware nem registra os comandos `led`."
                 : "Cor, brilho e efeito são gravados na configuração do Bruce e voltam assim depois de reiniciar.")
                .font(.caption)
        }
        .listRowBackground(BruceColor.surface)
        .disabled(isBlocked || hasNoLED)
    }

    /// One channel, on the firmware's own 0–255 scale.
    ///
    /// Moving a channel rebuilds the whole color and goes out as a single
    /// `led rgb` — the firmware's per-channel form exists for a caller that does
    /// not know the other two, which is not this one.
    private func channelSlider(_ label: String, _ channel: RGBChannel) -> some View {
        let value = channel.value(of: ledColor)
        return HStack(spacing: 10) {
            Text(label)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(channel.tint)
                .frame(width: 14)
            Slider(value: channelBinding(channel), in: 0...255, step: 1)
                .tint(channel.tint)
            Text(verbatim: "\(value)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func channelBinding(_ channel: RGBChannel) -> Binding<Double> {
        Binding(
            get: { Double(channel.value(of: ledColor)) },
            set: { ledColor = channel.replacing(in: ledColor, with: Int($0)) }
        )
    }

    // MARK: - Effects

    private var effectSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(LEDEffect.allCases) { item in
                    effectChip(item)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Efeito")
        } footer: {
            Text("“cores próprias”: o efeito gera as próprias cores e ignora a cor escolhida. “vários LEDs”: só anima em placas com mais de um LED.")
                .font(.caption)
        }
        .listRowBackground(BruceColor.surface)
        .disabled(isBlocked || hasNoLED)
    }

    private func effectChip(_ item: LEDEffect) -> some View {
        let selected = item == effect
        return Button {
            applyEffect(item)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? BruceColor.lilac : .secondary)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BruceColor.lilac)
                    }
                }
                Text(item.name)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                // `reservesSpace` keeps every chip the same height whether or not
                // the effect has a caveat to show.
                Text(item.caveat ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? BruceColor.purple.opacity(0.22) : BruceColor.surfaceHi.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? BruceColor.lilac : .white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Screen

    private var screenSection: some View {
        Section {
            swatchGrid(isSelected: { $0.color.rgb565 == screenColor.rgb565 }) { swatch in
                setScreenColor(swatch.color)
            }

            ColorPicker("Cor personalizada", selection: $screenColor, supportsOpacity: false)

            VStack(spacing: 2) {
                HStack {
                    Text("Brilho da tela")
                    Spacer()
                    Text(verbatim: "\(Int(screenBrightness))%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $screenBrightness, in: 1...100, step: 1) { editing in
                        if !editing { applyScreenBrightness() }
                    }
                    .tint(BruceColor.azure)
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await readClock() }
            } label: {
                HStack {
                    Label("Hora do dispositivo", systemImage: "clock")
                    Spacer()
                    if let clockReply {
                        Text(clockReply)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Tela")
        } footer: {
            Text("A cor da interface não é gravada: vale até reiniciar o Bruce, e é arredondada para as cores de 16 bits do display. O brilho também não é salvo.")
                .font(.caption)
        }
        .listRowBackground(BruceColor.surface)
        .disabled(isBlocked)
    }

    // MARK: - Swatches

    private func swatchGrid(
        isSelected: @escaping (ColorSwatch) -> Bool,
        action: @escaping (ColorSwatch) -> Void
    ) -> some View {
        let swatches = LightingPalette.swatches
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 12)], spacing: 12) {
            ForEach(swatches) { swatch in
                let selected = isSelected(swatch)
                Button {
                    action(swatch)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                        .overlay {
                            if selected {
                                Circle().stroke(.white, lineWidth: 2).padding(-4)
                            }
                        }
                        .shadow(color: swatch.color.opacity(selected ? 0.6 : 0), radius: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Applying

    /// Swatches and the off button set the color and send it at once — there is no
    /// drag to wait out.
    private func setLEDColor(_ color: Color) {
        ledColorApply?.cancel()
        ledColor = color
        applyLEDColor()
    }

    private func setScreenColor(_ color: Color) {
        screenColorApply?.cancel()
        screenColor = color
        applyScreenColor()
    }

    private func scheduleLEDColorApply() {
        ledColorApply?.cancel()
        ledColorApply = Task {
            try? await Task.sleep(for: colorDebounce)
            guard !Task.isCancelled else { return }
            applyLEDColor()
        }
    }

    private func scheduleScreenColorApply() {
        screenColorApply?.cancel()
        screenColorApply = Task {
            try? await Task.sleep(for: colorDebounce)
            guard !Task.isCancelled else { return }
            applyScreenColor()
        }
    }

    private func applyLEDColor() {
        let hex = ledColor.hex24
        guard isReady, hex != sentLED else { return }
        // Recorded before the write, not after: a pending debounce fires on its own
        // schedule and must see the value as already sent.
        sentLED = hex
        // Black is what `led off` writes, and the named command reads better in the
        // Terminal than `led rgb 0 0 0`.
        if hex == 0 {
            ble.send(LEDCommand.off)
        } else {
            let (r, g, b) = ledColor.rgb255
            ble.send(LEDCommand.rgb(r: r, g: g, b: b))
        }
    }

    private func applyLEDBrightness() {
        let value = Int(ledBrightness)
        guard isReady, value != sentLEDBrightness else { return }
        sentLEDBrightness = value
        ble.send(LEDCommand.brightness(value))
    }

    private func applyEffect(_ item: LEDEffect) {
        effect = item
        guard isReady, item != sentEffect else { return }
        sentEffect = item
        ble.send(LEDCommand.effect(item))
    }

    private func applyScreenColor() {
        let packed = screenColor.rgb565
        guard isReady, packed != sentScreen else { return }
        sentScreen = packed
        let (r, g, b) = screenColor.rgb255
        ble.send(ScreenCommand.color(r: r, g: g, b: b))
    }

    private func applyScreenBrightness() {
        let value = Int(screenBrightness)
        guard isReady, value != sentScreenBrightness else { return }
        sentScreenBrightness = value
        ble.send(ScreenCommand.brightness(percent: value))
    }

    /// One template, one command at a time.
    ///
    /// Each LED command writes the config file and forces a menu repaint on the
    /// device, so the three go out in sequence, waiting for each acknowledgement —
    /// `request` also keeps them from overlapping the read collector.
    private func apply(_ template: LightingTemplate) async {
        guard isReady else { return }
        ledColorApply?.cancel()
        screenColorApply?.cancel()
        applying = template.id
        defer { applying = nil }

        ledColor = template.led
        effect = template.effect
        screenColor = template.screen

        // A board with no RGB LED would only answer "Unknown command" twice.
        if !hasNoLED {
            sentLED = template.led.hex24
            let (r, g, b) = template.led.rgb255
            _ = await ble.request(sentLED == 0 ? LEDCommand.off : LEDCommand.rgb(r: r, g: g, b: b),
                                  quiet: 0.25, timeout: 5)

            sentEffect = template.effect
            _ = await ble.request(LEDCommand.effect(template.effect), quiet: 0.25, timeout: 5)
        }

        sentScreen = template.screen.rgb565
        let screen = template.screen.rgb255
        _ = await ble.request(ScreenCommand.color(r: screen.r, g: screen.g, b: screen.b),
                              quiet: 0.25, timeout: 5)
    }

    // MARK: - Reading the device

    private func readIfNeeded() async {
        guard isReady else {
            // A new session will have its own values — possibly from another board,
            // so the LED capability goes back to unknown too.
            if ble.state == .disconnected {
                didRead = false
                hasRGBLED = nil
            }
            return
        }
        guard !didRead else { return }
        await read()
    }

    /// Five `settings` reads — the firmware answers one field per command, and its
    /// full-config dump goes to USB `Serial` rather than to the BLE link.
    private func read() async {
        guard isReady, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            didRead = true
        }

        // The LED fields double as the capability check: a board built without
        // `HAS_RGB_LED` has no such config keys and rejects the name, so there is no
        // point asking for the other two — or offering the controls at all.
        let ledLines = await lines(for: .ledColor)
        if DeviceSetting.ledColor.isRejected(in: ledLines) {
            hasRGBLED = false
        } else if let hex = DeviceSetting.ledColor.hexValue(in: ledLines) {
            hasRGBLED = true
            let rgb = hex & 0xFFFFFF
            ledColor = Color(hex: rgb)
            sentLED = rgb
        }

        if hasRGBLED != false {
            if let percent = await intValue(of: .ledBright) {
                ledBrightness = Double(min(max(percent, 0), 100))
                sentLEDBrightness = percent
            }
            if let raw = await intValue(of: .ledEffect), let item = LEDEffect(rawValue: raw) {
                effect = item
                sentEffect = item
            }
        }
        if let hex = await value(of: .priColor) {
            let packed = UInt16(truncatingIfNeeded: hex)
            screenColor = Color(rgb565: packed)
            sentScreen = packed
        }
        if let percent = await intValue(of: .bright) {
            screenBrightness = Double(min(max(percent, 1), 100))
            sentScreenBrightness = percent
        }
    }

    /// Kept out of the Terminal: five `field = value` lines on opening a screen
    /// would bury whatever the user was reading there.
    private func lines(for field: DeviceSetting) async -> [String] {
        await ble.request(SettingsCommand.get(name: field.rawValue),
                          quiet: 0.35, timeout: 6, echo: false)
    }

    private func value(of field: DeviceSetting) async -> UInt32? {
        field.hexValue(in: await lines(for: field))
    }

    private func intValue(of field: DeviceSetting) async -> Int? {
        field.intValue(in: await lines(for: field))
    }

    private func readClock() async {
        guard isReady else { return }
        clockReply = nil
        let reply = await ble.request(ScreenCommand.clock, quiet: 0.3, timeout: 6, echo: false)
        clockReply = DeviceStatus.parseClock(reply) ?? L10n.t("sem resposta")
    }
}

/// One channel of an RGB color, with the arithmetic that goes with it.
private enum RGBChannel {
    case red, green, blue

    func value(of color: Color) -> Int {
        let (r, g, b) = color.rgb255
        switch self {
        case .red:   return r
        case .green: return g
        case .blue:  return b
        }
    }

    func replacing(in color: Color, with value: Int) -> Color {
        var (r, g, b) = color.rgb255
        let clamped = min(max(value, 0), 255)
        switch self {
        case .red:   r = clamped
        case .green: g = clamped
        case .blue:  b = clamped
        }
        return Color(hex: UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    var tint: Color {
        switch self {
        case .red:   return Color(hex: 0xFF5A5A)
        case .green: return Color(hex: 0x4ADE80)
        case .blue:  return Color(hex: 0x60A5FA)
        }
    }
}

#Preview {
    NavigationStack { LEDView() }
        .environmentObject(BLEManager())
        .preferredColorScheme(.dark)
}
