import SwiftUI

struct SettingsView: View {
    @State private var hotkey = Settings.shared.hotkey
    @State private var removeFillers = Settings.shared.removeFillers
    @State private var language = Settings.shared.language
    @State private var smartSpacing = Settings.shared.smartSpacing
    @State private var autoPunctuate = Settings.shared.autoPunctuate
    @State private var smartLists = Settings.shared.smartLists
    @State private var aiPolish = Settings.shared.aiPolishEnabled
    @State private var apiKey = Settings.shared.anthropicAPIKey
    @State private var model = Settings.shared.polishModel
    @State private var dictEntries: [(String, String)] = Settings.shared.dictionary.sorted { $0.key < $1.key }
    @State private var vocabText = Settings.shared.vocabulary.joined(separator: "\n")
    @State private var newSpoken = ""
    @State private var newReplacement = ""

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Hold to talk", selection: $hotkey) {
                    ForEach(HoldKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: hotkey) { Settings.shared.hotkey = hotkey; AppDelegate.shared?.rebuildMenu() }
                Text("Hold the key and speak; release to insert. Quick-tap to lock hands-free, tap again to finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("Spanish").tag("es-ES")
                    Text("French").tag("fr-FR")
                    Text("German").tag("de-DE")
                    Text("Italian").tag("it-IT")
                    Text("Portuguese (BR)").tag("pt-BR")
                }
                .onChange(of: language) { Settings.shared.language = language }
                Toggle("Remove filler words (um, uh, you know)", isOn: $removeFillers)
                    .onChange(of: removeFillers) { Settings.shared.removeFillers = removeFillers }
            }

            Section("Formatting") {
                Toggle("Smart spacing and sentence casing", isOn: $smartSpacing)
                    .onChange(of: smartSpacing) { Settings.shared.smartSpacing = smartSpacing }
                Text("Adds a space when you continue after existing text, capitalizes after a period, and keeps mid-sentence words lowercase.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("End sentences with punctuation", isOn: $autoPunctuate)
                    .onChange(of: autoPunctuate) { Settings.shared.autoPunctuate = autoPunctuate }

                Toggle("Turn spoken lists into bullets", isOn: $smartLists)
                    .onChange(of: smartLists) { Settings.shared.smartLists = smartLists }
                Text("\"I need eggs, milk, and bread\" becomes a bulleted list of three items.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                Text("Words and phrases Super Shout should expect to hear — acronyms, brands, product jargon. These bias recognition so they come out right the first time.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $vocabText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .onChange(of: vocabText) {
                        Settings.shared.vocabulary = vocabText
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                Button("Restore default vocabulary") {
                    Settings.shared.vocabulary = Settings.defaultVocabulary
                    vocabText = Settings.defaultVocabulary.joined(separator: "\n")
                }
            }

            Section("Personal Dictionary") {
                ForEach(dictEntries.indices, id: \.self) { i in
                    HStack {
                        Text(dictEntries[i].0)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(dictEntries[i].1)
                        Spacer()
                        Button(role: .destructive) {
                            var d = Settings.shared.dictionary
                            d.removeValue(forKey: dictEntries[i].0)
                            Settings.shared.dictionary = d
                            dictEntries.remove(at: i)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Heard as…", text: $newSpoken)
                    TextField("Replace with…", text: $newReplacement)
                    Button("Add") {
                        guard !newSpoken.isEmpty, !newReplacement.isEmpty else { return }
                        var d = Settings.shared.dictionary
                        d[newSpoken] = newReplacement
                        Settings.shared.dictionary = d
                        dictEntries = d.sorted { $0.key < $1.key }
                        newSpoken = ""; newReplacement = ""
                    }
                }
            }

            Section("AI Polish (optional, uses Claude API)") {
                Toggle("Polish transcripts with Claude", isOn: $aiPolish)
                    .onChange(of: aiPolish) { Settings.shared.aiPolishEnabled = aiPolish }
                if aiPolish {
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { Settings.shared.anthropicAPIKey = apiKey }
                    Picker("Model", selection: $model) {
                        Text("Claude Opus 5 (best)").tag("claude-opus-5")
                        Text("Claude Sonnet 5").tag("claude-sonnet-5")
                        Text("Claude Haiku 4.5 (fastest)").tag("claude-haiku-4-5")
                    }
                    .onChange(of: model) { Settings.shared.polishModel = model }
                    Text("When off, nothing ever leaves this Mac. Transcription is always on-device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}
