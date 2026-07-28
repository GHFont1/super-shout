import SwiftUI
import ServiceManagement
import Speech
import AVFoundation

struct SettingsView: View {
    /// Every locale the on-device recognizer supports, nicely named.
    private static let languageChoices: [(id: String, name: String)] = {
        let current = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { locale -> (String, String) in
                let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
                let name = current.localizedString(forIdentifier: locale.identifier) ?? id
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }()

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var handsFreeTap = Settings.shared.handsFreeTap
    @State private var spokenCommands = Settings.shared.spokenCommands
    @State private var soundCues = Settings.shared.soundCues
    @State private var hudPosition = Settings.shared.hudPosition
    @State private var smartEntities = Settings.shared.smartEntities
    /// Local mirror of the key mapping — SwiftUI needs @State to re-render;
    /// writes flow through to Settings on every change.
    @State private var keyActions: [HoldKey: KeyAction] = Dictionary(
        uniqueKeysWithValues: HoldKey.allCases.map { ($0, Settings.shared.action(for: $0)) }
    )

    @State private var keyEngines: [HoldKey: EngineChoice] = Dictionary(
        uniqueKeysWithValues: HoldKey.allCases.map { ($0, Settings.shared.engine(for: $0)) }
    )

    @ViewBuilder
    private func keyRow(_ key: HoldKey) -> some View {
        Picker(key.displayName, selection: Binding(
            get: { keyActions[key] ?? .off },
            set: { newValue in
                keyActions[key] = newValue
                Settings.shared.setAction(newValue, for: key)
                AppDelegate.shared?.rebuildMenu()
            }
        )) {
            ForEach(KeyAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        if (keyActions[key] ?? .off).needsAPIKey {
            Picker("        ↳ engine", selection: Binding(
                get: { keyEngines[key] ?? .auto },
                set: { newValue in
                    keyEngines[key] = newValue
                    Settings.shared.setEngine(newValue, for: key)
                }
            )) {
                ForEach(EngineChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.callout)
        }
    }
    @State private var removeFillers = Settings.shared.removeFillers
    @State private var language = Settings.shared.language
    @State private var audioInputUID = Settings.shared.audioInputUID
    @State private var enhanceQuietAudio = Settings.shared.enhanceQuietAudio
    @State private var speechEngine = Settings.shared.speechEngine
    @State private var smartSpacing = Settings.shared.smartSpacing
    @State private var autoPunctuate = Settings.shared.autoPunctuate
    @State private var smartLists = Settings.shared.smartLists
    @State private var aiPolish = Settings.shared.aiPolishEnabled
    @State private var personalStyle = Settings.shared.personalStyle
    @State private var businessContext = Settings.shared.businessContext
    @State private var voiceTutor = Settings.shared.voiceTutorEnabled
    @State private var tutorRunning = false
    @State private var tutorSummary = Settings.shared.tutorLastSummary
    @State private var apiKey = Settings.shared.anthropicAPIKey
    @State private var model = Settings.shared.polishModel
    @State private var provider = Settings.shared.aiProvider
    @State private var claudeCodeModel = Settings.shared.claudeCodeModel
    @State private var codexModel = Settings.shared.codexModel
    @State private var dictEntries: [(String, String)] = Settings.shared.dictionary.sorted { $0.key < $1.key }
    @State private var vocabText = Settings.shared.vocabulary.joined(separator: "\n")
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var snippets = Settings.shared.voiceSnippets
    @State private var newSnippetTrigger = ""
    @State private var newSnippetReplacement = ""
    @State private var appModes = Settings.shared.appModes
    @State private var historyRetention = Settings.shared.historyRetention
    @State private var dataMessage = ""

    var body: some View {
        Form {
            Section("Keys") {
                ForEach(HoldKey.primary, id: \.self) { key in
                    keyRow(key)
                }
                DisclosureGroup("More keys (Right ⇧, F1–F19)") {
                    ForEach(HoldKey.allCases.filter { !HoldKey.primary.contains($0) }, id: \.self) { key in
                        keyRow(key)
                    }
                    Text("A bound F-key is captured by Super Shout while the app runs (its normal function won't fire). On laptop keyboards, F1–F12 may need “Use F1, F2, etc. as standard function keys” in System Settings → Keyboard. F13–F19 on full-size keyboards are ideal — they do nothing else.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Dictate types your words. AI Rewrite retypes everything you said in your own voice, formatted for where you're typing (emails become emails). AI Edit rewrites the text you have selected per your spoken instruction. AI Compose writes finished text from a spoken request. AI Deep Research looks facts up first, then writes. AI Do carries out the request and reports back. Hold and speak; release to run; Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Quick-tap locks hands-free dictation", isOn: $handsFreeTap)
                    .onChange(of: handsFreeTap) { Settings.shared.handsFreeTap = handsFreeTap }
                Text("Off means keys only work while held — an accidental tap never starts dictation.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Start Super Shout at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("SuperShout: launch-at-login change failed — \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Transcription") {
                Picker("Speech engine", selection: $speechEngine) {
                    ForEach(SpeechEngineChoice.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: speechEngine) {
                    Settings.shared.speechEngine = speechEngine
                    if speechEngine != .legacy { Transcriber.prepareModernEngine() }
                }
                Picker("Microphone", selection: $audioInputUID) {
                    Text("System default (\(AudioInputDevice.systemDefaultName() ?? "current input"))").tag("")
                    ForEach(AudioInputDevice.available()) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: audioInputUID) { Settings.shared.audioInputUID = audioInputUID }
                Text("The selected microphone is used the next time listening starts. Choose the mic you physically hold a phone near.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    ForEach(Self.languageChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .onChange(of: language) { Settings.shared.language = language }
                Toggle("Boost quiet phone and speaker audio", isOn: $enhanceQuietAudio)
                    .onChange(of: enhanceQuietAudio) { Settings.shared.enhanceQuietAudio = enhanceQuietAudio }
                Toggle("Remove filler words (um, uh, you know)", isOn: $removeFillers)
                    .onChange(of: removeFillers) { Settings.shared.removeFillers = removeFillers }
                Toggle("Play a soft click when listening starts and stops", isOn: $soundCues)
                    .onChange(of: soundCues) { Settings.shared.soundCues = soundCues }
                Picker("Shout Bar position", selection: $hudPosition) {
                    ForEach(HUDPosition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: hudPosition) { Settings.shared.hudPosition = hudPosition }
                Button("Run microphone check…") { AppDelegate.shared?.openDiagnostic() }
            }

            Section("Voice snippets") {
                Text("Say a short trigger and Super Shout expands it before inserting, such as “my address” or “standard reply.”")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(snippets) { snippet in
                    HStack {
                        Text(snippet.trigger).fontWeight(.medium)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(snippet.replacement).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            snippets.removeAll { $0.id == snippet.id }; Settings.shared.voiceSnippets = snippets
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Spoken trigger", text: $newSnippetTrigger)
                    TextField("Expanded text", text: $newSnippetReplacement)
                    Button("Add") {
                        guard !newSnippetTrigger.isEmpty, !newSnippetReplacement.isEmpty else { return }
                        snippets.append(VoiceSnippet(trigger: newSnippetTrigger, replacement: newSnippetReplacement))
                        Settings.shared.voiceSnippets = snippets; newSnippetTrigger = ""; newSnippetReplacement = ""
                    }
                }
            }

            Section("Automatic app modes") {
                Text("Formatting switches automatically based on the app that was active when you started speaking.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($appModes) { $mode in
                    DisclosureGroup(mode.name) {
                        TextField("Mode name", text: $mode.name)
                        TextField("Bundle IDs, comma separated", text: Binding(
                            get: { mode.bundleIdentifiers.joined(separator: ", ") },
                            set: { mode.bundleIdentifiers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; Settings.shared.appModes = appModes }
                        ))
                        Toggle("Remove filler words", isOn: $mode.removeFillers)
                        Toggle("End sentences with punctuation", isOn: $mode.autoPunctuate)
                        Toggle("Turn spoken lists into bullets", isOn: $mode.smartLists)
                        Toggle("Polish with AI", isOn: $mode.aiPolish)
                        Button("Delete mode", role: .destructive) { appModes.removeAll { $0.id == mode.id }; Settings.shared.appModes = appModes }
                    }
                    .onChange(of: mode) { Settings.shared.appModes = appModes }
                }
                Button("Add mode") {
                    appModes.append(AppMode(name: "New Mode", bundleIdentifiers: [], removeFillers: true, autoPunctuate: true, smartLists: false, aiPolish: false))
                    Settings.shared.appModes = appModes
                }
            }

            Section("History and portability") {
                Picker("Keep transcript history", selection: $historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: historyRetention) {
                    Settings.shared.historyRetention = historyRetention
                    TranscriptHistory.shared.prune()
                }
                Text("History stays in this Mac's Application Support folder. AI recall sends recent history only when you click Ask History.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Export Settings and History…") { dataMessage = PortableBackup.export() }
                    Button("Import…") { dataMessage = PortableBackup.importBackup() }
                    Button("Open Library…") { AppDelegate.shared?.openHistory() }
                }
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

                Toggle("Spoken commands", isOn: $spokenCommands)
                    .onChange(of: spokenCommands) { Settings.shared.spokenCommands = spokenCommands }
                Text("Say \"new line\" or \"new paragraph\" for line breaks, \"scratch that\" to erase the last sentence and retake it, and \"press enter\" at the end to send the message.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Fix product and vehicle names", isOn: $smartEntities)
                    .onChange(of: smartEntities) { Settings.shared.smartEntities = smartEntities }
                Text("\"2019 Genesis G7\" becomes \"2019 Genesis G70\" — near-miss model names snap to the real one.")
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
                Toggle("Voice Tutor: learn from my dictation automatically", isOn: $voiceTutor)
                    .onChange(of: voiceTutor) { Settings.shared.voiceTutorEnabled = voiceTutor }
                HStack {
                    Button(tutorRunning ? "Studying…" : "Study now") {
                        tutorRunning = true
                        VoiceTutor.run { summary in
                            tutorRunning = false
                            tutorSummary = summary
                        }
                    }
                    .disabled(tutorRunning)
                    if !tutorSummary.isEmpty {
                        Text(tutorSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Text("Every few hours an AI pass reviews recent transcripts and fixes what the recognizer keeps getting wrong (\"Taylor for our business\" becomes \"tailored for our business\" forever). Uses your AI engine; add or remove anything it learns in the dictionary below.")
                    .font(.caption).foregroundStyle(.secondary)

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

            Section("AI provider (powers AI Edit, AI Compose, and polish)") {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: provider) { Settings.shared.aiProvider = provider }

                switch provider {
                case .claudeAPI:
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { Settings.shared.anthropicAPIKey = apiKey }
                    Picker("Model", selection: $model) {
                        Text("Claude Fable 5 (smartest)").tag("claude-fable-5")
                        Text("Claude Opus 5").tag("claude-opus-5")
                        Text("Claude Sonnet 5").tag("claude-sonnet-5")
                        Text("Claude Haiku 4.5 (fastest)").tag("claude-haiku-4-5")
                    }
                    .onChange(of: model) { Settings.shared.polishModel = model }
                    Text("The key is stored in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                case .claudeCode:
                    Picker("Model", selection: $claudeCodeModel) {
                        Text("Default (session model)").tag("")
                        Text("Fable 5").tag("claude-fable-5")
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                    }
                    .onChange(of: claudeCodeModel) { Settings.shared.claudeCodeModel = claudeCodeModel }
                    Text("Uses the Claude Code CLI and the Claude plan you're already signed into on this Mac. No API key, no extra cost.")
                        .font(.caption).foregroundStyle(.secondary)
                case .codexCLI:
                    Picker("Model", selection: $codexModel) {
                        Text("GPT-5.6-SOL").tag("gpt-5.6-sol")
                        Text("Default").tag("")
                    }
                    .onChange(of: codexModel) { Settings.shared.codexModel = codexModel }
                    Text("Uses the Codex CLI and the ChatGPT plan you're already signed into on this Mac. No API key, no extra cost.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle("Also polish plain dictation with AI", isOn: $aiPolish)
                    .onChange(of: aiPolish) { Settings.shared.aiPolishEnabled = aiPolish }
            }

            Section("Your voice (AI Rewrite style)") {
                Text("AI Rewrite retypes your dictation in this style. Describe how you write — tone, sentence length, sign-offs, anything.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $personalStyle)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .onChange(of: personalStyle) { Settings.shared.personalStyle = personalStyle }
                Button("Restore default style") {
                    Settings.shared.personalStyle = Settings.defaultPersonalStyle
                    personalStyle = Settings.defaultPersonalStyle
                }
            }

            Section("Business brain (AI context)") {
                Text("Facts the AI knows on every request — your company, vendors, mailboxes, rules. Say \"email Classic about the PO\" and it knows who Classic is. Edit freely; add anything it should always know.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $businessContext)
                    .font(.system(size: 12))
                    .frame(height: 120)
                    .onChange(of: businessContext) { Settings.shared.businessContext = businessContext }
                Button("Insert example template") {
                    Settings.shared.businessContext = Settings.defaultBusinessContext
                    businessContext = Settings.defaultBusinessContext
                }
                Text("Sent only with AI Rewrite, AI Edit, and AI Compose requests. Without a provider set up, dictation works fully on-device and nothing ever leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .alert("Super Shout", isPresented: Binding(get: { !dataMessage.isEmpty }, set: { if !$0 { dataMessage = "" } })) {
            Button("OK") { dataMessage = "" }
        } message: { Text(dataMessage) }
    }
}
