import SwiftUI

/// Speaker module: text-to-speech, tones, and audio file playback.
struct AudioView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var text = ""
    @State private var frequency = "1000"
    @State private var duration = "200"
    @State private var musicPath = ""
    @State private var showFilePicker = false

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        Form {
            Section("Falar (TTS)") {
                TextField("texto", text: $text, axis: .vertical)
                Button {
                    ble.send(AudioCommand.say(text.trimmed))
                } label: {
                    Label("Falar", systemImage: "speaker.wave.2.fill")
                }
                .disabled(!isReady || text.trimmed.isEmpty)
            }

            Section("Tom") {
                TextField("frequência (Hz)", text: $frequency)
                    .keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                TextField("duração (ms)", text: $duration)
                    .keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                Button {
                    ble.send(AudioCommand.tone(frequency: Int(frequency.trimmed) ?? 0,
                                               duration: Int(duration.trimmed) ?? 0))
                } label: {
                    Label("Tocar tom", systemImage: "waveform")
                }
                .disabled(!isReady || Int(frequency.trimmed) == nil)
            }

            Section {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Escolher do dispositivo", systemImage: "folder")
                }
                .disabled(!isReady)

                TextField("caminho (ex: /audio/x.mp3)", text: $musicPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    ble.send(AudioCommand.music(path: musicPath.trimmed))
                } label: {
                    Label("Tocar", systemImage: "play.fill")
                }
                .disabled(!isReady || musicPath.trimmed.isEmpty)
            } header: {
                Text("Tocar arquivo")
            } footer: {
                Text("Escolha um .mp3/.wav do armazenamento do Bruce, ou digite o caminho. A reprodução de MP3 depende do firmware.")
                    .font(.caption)
            }
        }
        .navigationTitle("Áudio")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isReady)
        .sheet(isPresented: $showFilePicker) {
            DeviceFilePickerView(
                title: "Escolher áudio",
                allowedExtensions: ["mp3", "wav"]
            ) { file in
                musicPath = file.path
                // Load-and-play: picking from a folder runs the file, which is the
                // point of the picker.
                ble.send(AudioCommand.music(path: file.path))
            }
            .environmentObject(ble)
        }
    }
}

#Preview {
    NavigationStack { AudioView() }.environmentObject(BLEManager())
}
