import SwiftUI

/// Full remote control: the device screen mirrored, with a D-pad that drives the
/// real firmware menus.
///
/// Both halves ride the same serial bridge the rest of the app uses — `nav` pushes
/// presses into the device's input queue, `display` streams back the draw calls it
/// makes in response. Nothing here is a parallel UI: what you see and touch is the
/// Bruce's own interface.
struct RemoteControlView: View {

    @EnvironmentObject private var ble: BLEManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var screenshot: Screenshot?
    /// Set when the mirror was asked for a frame repeatedly and none arrived, so
    /// the placeholder can offer a retry instead of spinning forever.
    @State private var stalled = false
    /// Guards against two arming runs overlapping — the connection task and the
    /// foreground handler can both fire for the same event.
    @State private var isArming = false

    private var isReady: Bool { ble.state == .ready }

    /// A captured frame, held while the share sheet is up.
    private struct Screenshot: Identifiable {
        let id = UUID()
        let image: Image
    }

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()

            GeometryReader { geometry in
                let size = geometry.size
                if size.width > size.height {
                    landscape(in: size)
                } else {
                    portrait
                }
            }
        }
        .navigationTitle("Controle remoto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        // Keyed on the connection so the mirror is re-armed whenever the link comes
        // back. Without this a device reset — or any dropout — leaves the view alive
        // with an empty screen and no way back short of navigating out and in.
        .task(id: ble.state) {
            guard isReady else { return }
            await armMirror()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Leaving the device streaming into a connection nobody is reading
                // is what fills its log queue and wedges the mirror for good.
                ble.stopScreenMirror()
            case .active:
                Task { await armMirror() }
            default:
                break
            }
        }
        .onDisappear {
            ble.stopScreenMirror()
        }
        .sheet(item: $screenshot) { shot in
            shareSheet(shot)
        }
        .disabled(!isReady)
    }

    // MARK: - Layouts

    private var portrait: some View {
        VStack(spacing: 0) {
            actionRow
            Spacer(minLength: 12)
            devicePanel(showsWordmark: true)
                .padding(.horizontal, 20)
            Spacer(minLength: 12)
            controls(diameter: 220)
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    /// Screen on the left, controls on the right — the shape a two-handed grip
    /// wants, and the only way the 320×170 panel gets to use the width it has.
    private func landscape(in size: CGSize) -> some View {
        // Three columns: the mirrored screen, the pad, and the action rail. The pad
        // is not a fixed size — it is solved for the diameter that makes it exactly
        // as tall as the panel beside it, since the panel's own height follows from
        // whatever width is left over:
        //
        //     panelWidth = W - rail - spacings - insets - diameter
        //     panelHeight = panelWidth / aspect  =  diameter
        //     ⇒ diameter = (W - rail - spacings - insets) / (aspect + 1)
        //
        // Equal heights, both centred, is what makes the two read as one instrument.
        let spacing: CGFloat = 16
        let inset: CGFloat = 16
        let fixed = Self.railWidth + spacing * 2 + inset * 2
        let aspect = ble.screen.size.width / max(ble.screen.size.height, 1)
        let ceiling = min(size.height - 16, 280)
        let diameter = max(150, min((size.width - fixed) / (aspect + 1), ceiling))

        return HStack(spacing: spacing) {
            devicePanel(showsWordmark: false)
                .frame(maxWidth: .infinity)
            dPad(diameter: diameter)
            actionRail
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, inset)
        .padding(.vertical, 8)
    }

    private func devicePanel(showsWordmark: Bool) -> some View {
        DevicePanel(
            screen: ble.screen,
            showsWordmark: showsWordmark,
            stalled: stalled,
            retry: { Task { await armMirror(force: true) } }
        )
    }

    // MARK: - Screen mirror lifecycle

    /// Turn the stream on and wait for the first frame, retrying before giving up.
    ///
    /// A single `display start` is not enough to trust: the device only emits draw
    /// calls when something repaints, the repaint nudge can land while the firmware
    /// is busy, and the logger drops packets when its queue is full. Rather than
    /// leave a spinner on screen forever, ask again a couple of times and then say
    /// so.
    private func armMirror(force: Bool = false) async {
        guard isReady, !isArming else { return }
        // Already mirroring and painting: nothing to do (foregrounding re-enters here).
        if !force, !ble.screen.ops.isEmpty, ble.screen.isStreaming { return }

        isArming = true
        stalled = false
        defer { isArming = false }

        // Start the stream once, then only nudge it. Every `startScreenMirror()` is
        // a `display stop` / `display start` pair, and each pair makes the device
        // tear a logger task down and stand a new one up — the retry loop used to
        // do that three times in nine seconds. What a missing first frame actually
        // needs is a repaint, not another restart.
        for attempt in 0..<3 {
            if attempt == 0 {
                await ble.startScreenMirror()
            } else {
                await ble.forceRepaint()
            }

            // ~3 s for the first packets to land before trying again.
            for _ in 0..<12 {
                if Task.isCancelled { return }
                if !ble.screen.ops.isEmpty { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if Task.isCancelled || !isReady { return }
        }

        stalled = ble.screen.ops.isEmpty
    }

    // MARK: - Top actions

    private var actionRow: some View {
        HStack {
            circleAction("Captura", systemImage: "camera.fill") {
                screenshot = capture()
            }
            Spacer()
            circleAction("Repintar", systemImage: "arrow.clockwise") {
                Task { await ble.forceRepaint() }
            }
        }
        .padding(.horizontal, 24)
    }

    /// The landscape rail: capture, repaint and back stacked beside the pad,
    /// captions dropped because the height they cost comes out of the D-pad. Back
    /// is drawn larger than the other two — it is the one press used constantly,
    /// and the only one that acts on the device rather than on the mirror.
    private var actionRail: some View {
        VStack(spacing: 18) {
            railAction("Captura", systemImage: "camera.fill") {
                screenshot = capture()
            }
            railAction("Repintar", systemImage: "arrow.clockwise") {
                Task { await ble.forceRepaint() }
            }
            escButton(size: 64)
        }
        .frame(width: Self.railWidth)
    }

    /// Width of the landscape action rail, wide enough for its largest button.
    private static let railWidth: CGFloat = 68

    private func railAction(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(BruceColor.purple.opacity(0.22))
                    .frame(width: 52, height: 52)
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(BruceColor.lilac)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func circleAction(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(BruceColor.purple.opacity(0.22))
                        .frame(width: 56, height: 56)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BruceColor.lilac)
                }
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(BruceColor.lilac)
            }
        }
        .buttonStyle(.plain)
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                Task { await ble.forceRepaint() }
            } label: {
                Label("Forçar repintura", systemImage: "arrow.clockwise")
            }

            Button {
                Task { await armMirror(force: true) }
            } label: {
                Label("Reiniciar espelho", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                // Mirrors the app's own accent onto the device, so the mirrored
                // screen really is in the Bruce palette rather than being recolored
                // on this side — which would misrepresent what the device shows.
                let (r, g, b) = BruceColor.purple.rgb255
                ble.send(ScreenCommand.color(r: r, g: g, b: b))
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    await ble.forceRepaint()
                }
            } label: {
                Label("Pintar interface de roxo", systemImage: "paintpalette.fill")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Controls

    /// Portrait keeps the escape button tucked into the corner beside the pad;
    /// landscape moves it into `actionRail` instead.
    private func controls(diameter: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            dPad(diameter: diameter)
                .frame(maxWidth: .infinity)
            escButton(size: 62)
        }
    }

    private func dPad(diameter: CGFloat) -> some View {
        // Proportions of the original 220 pt pad, so it keeps its shape at any size.
        let offset = diameter * 0.336
        let hit = diameter * 0.273
        let arrow = diameter * 0.118
        let select = diameter * 0.264

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [BruceColor.violet, BruceColor.purple, BruceColor.deep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().stroke(BruceColor.lilac.opacity(0.55), lineWidth: 2))
                .shadow(color: BruceColor.purple.opacity(0.45), radius: 16)

            navButton(.up, rotation: 0, label: L10n.t("Cima"), hit: hit, arrow: arrow)
                .offset(y: -offset)
            navButton(.down, rotation: 180, label: L10n.t("Baixo"), hit: hit, arrow: arrow)
                .offset(y: offset)
            navButton(.previous, rotation: -90, label: L10n.t("Anterior"), hit: hit, arrow: arrow)
                .offset(x: -offset)
            navButton(.next, rotation: 90, label: L10n.t("Próximo"), hit: hit, arrow: arrow)
                .offset(x: offset)

            selectButton(size: select)
        }
        .frame(width: diameter, height: diameter)
    }

    private func navButton(
        _ nav: NavCommand,
        rotation: Double,
        label: String,
        hit: CGFloat,
        arrow: CGFloat
    ) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: arrow, weight: .bold))
            .rotationEffect(.degrees(rotation))
            .foregroundStyle(BruceColor.grape)
            .frame(width: hit, height: hit)
            .contentShape(Circle())
            .pressAction(nav, label: label, on: ble)
    }

    private func selectButton(size: CGFloat) -> some View {
        Circle()
            .stroke(BruceColor.grape, lineWidth: 4)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .pressAction(.select, label: L10n.t("Selecionar"), on: ble)
    }

    private func escButton(size: CGFloat) -> some View {
        Image(systemName: "arrow.uturn.left")
            .font(.system(size: size * 0.39, weight: .bold))
            .foregroundStyle(BruceColor.grape)
            .frame(width: size, height: size)
            .background(Circle().fill(BruceColor.purple))
            .overlay(Circle().stroke(BruceColor.lilac.opacity(0.5), lineWidth: 2))
            .contentShape(Circle())
            .pressAction(.escape, label: L10n.t("Voltar"), on: ble)
    }

    // MARK: - Screenshot

    /// Renders the current frame at 4× so the shared image is legible.
    @MainActor
    private func capture() -> Screenshot? {
        let ops = ble.screen.ops
        let size = ble.screen.size
        guard !ops.isEmpty, size.width > 0, size.height > 0 else { return nil }

        let renderer = ImageRenderer(
            content: TFTCanvas(ops: ops, deviceSize: size)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 4
        guard let image = renderer.uiImage else { return nil }
        return Screenshot(image: Image(uiImage: image))
    }

    private func shareSheet(_ shot: Screenshot) -> some View {
        NavigationStack {
            VStack(spacing: 24) {
                shot.image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(BruceColor.purple, lineWidth: 2)
                    )
                    .padding()

                ShareLink(
                    item: shot.image,
                    preview: SharePreview("Tela do Bruce", image: shot.image)
                ) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .navigationTitle("Captura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { screenshot = nil }
                }
            }
        }
    }
}

// MARK: - Device panel

/// The mirrored screen in its chassis.
///
/// Split out so that the flood of draw calls only invalidates this subtree; the
/// surrounding controls are bound to the connection, not to the screen.
private struct DevicePanel: View {
    @ObservedObject var screen: TFTScreen
    /// Hidden in landscape, where the vertical space belongs to the panel.
    var showsWordmark: Bool
    /// No frame arrived after repeated attempts.
    var stalled: Bool
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(BruceColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(BruceColor.purple, lineWidth: 3)
                    )
                    .shadow(color: BruceColor.purple.opacity(0.35), radius: 20)

                if screen.ops.isEmpty {
                    placeholder
                        .padding(16)
                } else {
                    TFTCanvas(ops: screen.ops, deviceSize: screen.size)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            }
            .aspectRatio(screen.size.width / screen.size.height, contentMode: .fit)

            if showsWordmark {
                Text("BRUCE")
                    .font(.system(size: 28, weight: .heavy, design: .monospaced))
                    .kerning(8)
                    .foregroundStyle(BruceColor.purple)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if stalled {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(BruceColor.lilac)
                Text("O Bruce não enviou a tela.")
                    .font(.footnote)
                Text("Se ele reiniciou, reative a BLE API em Config → Advanced.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Tentar de novo", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(BruceColor.lilac)
                Text("Aguardando a tela do Bruce…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Press handling

private extension View {
    /// Wires a view up as a device button: tap sends a press, holding sends a long
    /// press, and both nudge the haptic engine so the control feels physical even
    /// though the button being pressed is on the other end of a radio link.
    func pressAction(_ nav: NavCommand, label: String, on ble: BLEManager) -> some View {
        self
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                ble.press(nav)
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                ble.press(nav, longPress: true)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}

#Preview {
    NavigationStack { RemoteControlView() }
        .environmentObject(BLEManager())
}
