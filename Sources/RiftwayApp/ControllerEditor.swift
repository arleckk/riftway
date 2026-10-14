import AppKit
import RiftwayCore
import SwiftUI
import UniformTypeIdentifiers

/// "Configurar control…": per program of a game, how the controller reaches
/// it (PRD-08), and in keyboard and desktop modes, what each button sends.
struct ControllerEditorView: View {
    let entry: LibraryEntry
    let library: LibraryModel
    @State private var monitor = ControllerMonitor()
    @Environment(\.dismiss) private var dismiss

    @State private var layout: ControllerLayout
    @State private var program: String?
    @State private var layer: String?
    @State private var selected: ControllerButton?
    @State private var capturing: ControllerButton?
    @State private var keyMonitor: Any?
    @State private var labelsFamily: ControllerFamily = .playStation4
    @State private var suggestions: [String] = []
    @State private var newProgram = ""
    @State private var newLayer = ""
    @State private var addingProgram = false
    @State private var addingLayer = false
    @State private var renamingLayer = false
    @State private var layerName = ""
    @State private var notice: String?

    static let otherPrograms = "\u{0}other"

    init(entry: LibraryEntry, library: LibraryModel) {
        self.entry = entry
        self.library = library
        let layout = ControllerLayout.read(bottle: entry.root) ?? ControllerLayout()
        _layout = State(initialValue: layout)
        _program = State(initialValue: layout.programs.keys.sorted().first ?? Self.otherPrograms)
    }

    var family: ControllerFamily { monitor.family ?? labelsFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                programList.frame(width: 230)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 900, height: 640)
        .onAppear {
            monitor.start()
            suggestions = ControllerLayout.programSuggestions(for: entry)
        }
        .onDisappear {
            monitor.stop()
            stopCapture()
        }
        .onChange(of: monitor.lastPressed?.at) {
            // Pressing a button on the controller selects it.
            guard capturing == nil, let button = monitor.lastPressed?.button, editable else { return }
            selected = button
        }
    }

    // MARK: Header: the controllers

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control de \(entry.game.name)").font(.title3.weight(.semibold))
            if monitor.controllers.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                    Text("Conecta un control por Bluetooth o USB para probarlo aquí.").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Mostrar botones de", selection: $labelsFamily) {
                        ForEach([ControllerFamily.playStation4, .playStation5, .xbox, .switchPro], id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(width: 280)
                }
                .font(.callout)
            } else {
                ForEach(monitor.controllers) { controller in
                    HStack(spacing: 8) {
                        Image(systemName: controller.supported ? "gamecontroller.fill" : "gamecontroller")
                            .foregroundStyle(controller.supported ? Color.accentColor : .secondary)
                        Text(controller.name).fontWeight(.medium)
                        Text(controller.family.displayName).foregroundStyle(.secondary)
                        if let battery = controller.battery, battery > 0 {
                            Text("· batería \(Int(battery * 100)) %").foregroundStyle(.secondary)
                        }
                        if !controller.supported {
                            Text("· llega a los juegos con soporte de control; macOS no lo deja traducir a teclado")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Programs

    private var programList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $program) {
                Section("Programas") {
                    ForEach(layout.programs.keys.sorted(), id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).lineLimit(1).truncationMode(.middle)
                            Text(Self.modeName(layout.programs[name]?.mode ?? .native)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Optional(name))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Otros programas")
                        Text(Self.modeName(layout.otherPrograms)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(Optional(Self.otherPrograms))
                }
            }
            .listStyle(.sidebar)
            HStack {
                Menu("Agregar programa") {
                    let unused = suggestions.filter { name in !layout.programs.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                    ForEach(unused, id: \.self) { name in Button(name) { addProgram(name) } }
                    if !unused.isEmpty { Divider() }
                    Button("Otro…") { addingProgram = true }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if let name = program, name != Self.otherPrograms {
                    Button {
                        layout.programs[name] = nil
                        program = Self.otherPrograms
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .help("Quitar \(name)")
                }
            }
            .padding(10)
        }
        .alert("Agregar programa", isPresented: $addingProgram) {
            TextField("Juego.exe", text: $newProgram)
            Button("Agregar") { addProgram(newProgram); newProgram = "" }
            Button("Cancelar", role: .cancel) { newProgram = "" }
        } message: {
            Text("El nombre del archivo .exe, como aparece en la carpeta del juego.")
        }
    }

    private func addProgram(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasSuffix(".exe") else { return }
        if layout.programs[trimmed] == nil { layout.programs[trimmed] = ProgramControls(mode: .keyboard) }
        program = trimmed
        layer = nil
    }

    static func modeName(_ mode: InputMode) -> String {
        switch mode {
        case .native: "Control nativo"
        case .desktop: "Escritorio (mouse)"
        case .keyboard: "Teclado y mouse"
        case .off: "Apagado"
        }
    }

    // MARK: The selected program

    private var mode: InputMode {
        guard let program else { return .native }
        return program == Self.otherPrograms ? layout.otherPrograms : layout.controls(for: program).mode
    }

    private var editable: Bool { program != Self.otherPrograms && (mode == .keyboard || mode == .desktop) }

    private var modeBinding: Binding<InputMode> {
        Binding(get: { mode }, set: { newMode in
            guard let program else { return }
            if program == Self.otherPrograms {
                layout.otherPrograms = newMode == .keyboard ? .native : newMode
            } else {
                var controls = layout.programs[program] ?? ProgramControls(mode: newMode)
                controls.mode = newMode
                layout.programs[program] = controls
            }
            layer = nil
        })
    }

    /// The bindings being edited: the program's, or the built-in desktop set.
    private var actionSet: ActionSet {
        guard let program, let controls = layout.programs[program] else { return ActionSet() }
        return controls.actionSet ?? (controls.mode == .desktop ? .desktop : ActionSet())
    }

    private func update(_ change: (inout ActionSet) -> Void) {
        guard let program, program != Self.otherPrograms else { return }
        var set = actionSet
        change(&set)
        var controls = layout.programs[program] ?? ProgramControls(mode: .keyboard)
        controls.actionSet = set
        layout.programs[program] = controls
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Modo", selection: modeBinding) {
                Text("Nativo").tag(InputMode.native)
                Text("Escritorio").tag(InputMode.desktop)
                if program != Self.otherPrograms { Text("Teclado y mouse").tag(InputMode.keyboard) }
                Text("Apagado").tag(InputMode.off)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            Text(modeHelp).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if editable {
                layerBar
                bindingsList
            } else {
                Spacer()
            }
        }
        .padding(16)
    }

    private var modeHelp: String {
        switch mode {
        case .native: "El programa recibe el control como un control de Xbox. Para juegos que ya traen soporte de control."
        case .desktop: "El stick derecho y el touchpad mueven el puntero y los botones hacen clic. Para launchers y menús; puedes cambiar cualquier botón."
        case .keyboard: "Cada botón es una tecla o un botón del mouse, solo mientras este programa está al frente. Un botón, una tecla: sin macros ni repeticiones."
        case .off: "Riftway no envía nada a este programa."
        }
    }

    // MARK: Layers and pointer

    @ViewBuilder private var layerBar: some View {
        HStack(spacing: 10) {
            Picker("Capa", selection: $layer) {
                Text("Base").tag(String?.none)
                ForEach(actionSet.layers.keys.sorted(), id: \.self) { Text("Capa \($0)").tag(Optional($0)) }
            }
            .frame(width: 170)
            Button("Nueva capa…") { addingLayer = true }.fixedSize()
            if let current = layer {
                Button("Renombrar…") { layerName = current; renamingLayer = true }.fixedSize()
                Button("Quitar capa") {
                    update { set in
                        set.layers[current] = nil
                        for (button, output) in set.base.bindings where output == .holdLayer(current) { set.base.bindings[button] = ControllerOutput.none }
                    }
                    layer = nil
                }
                .fixedSize()
            }
            Spacer()
        }
        .font(.callout)
        HStack(spacing: 12) {
            Text("Mueven el mouse:").foregroundStyle(.secondary).fixedSize()
            ForEach(pointerSources, id: \.self) { source in
                Toggle(Self.pointerName(source), isOn: Binding(
                    get: { actionSet.pointer.contains(source) },
                    set: { on in update { set in
                        set.pointer.removeAll { $0 == source }
                        if on { set.pointer.append(source) }
                    } }))
                .toggleStyle(.checkbox)
                .fixedSize()
            }
            Spacer()
        }
        .font(.callout)
        .alert("Nueva capa", isPresented: $addingLayer) {
            TextField("Nombre (por ejemplo L1)", text: $newLayer)
            Button("Crear") {
                let name = newLayer.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { update { $0.layers[name] = $0.layers[name] ?? InputLayer() }; layer = name }
                newLayer = ""
            }
            Button("Cancelar", role: .cancel) { newLayer = "" }
        } message: {
            Text("Una capa cambia los botones mientras mantienes presionado el botón que asignes a \"Mantener capa\", como las de Steam Input.")
        }
        .alert("Renombrar capa", isPresented: $renamingLayer) {
            TextField("Nombre", text: $layerName)
            Button("Renombrar") {
                guard let current = layer else { return }
                var set = actionSet
                do {
                    try set.renameLayer(current, to: layerName)
                    update { $0 = set }
                    layer = layerName.trimmingCharacters(in: .whitespaces)
                } catch ActionSet.LayerError.exists(let name) {
                    notice = "Ya hay una capa \(name)."
                } catch {
                    notice = "Una capa necesita un nombre."
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los botones que la mantienen se actualizan.")
        }
    }

    private var pointerSources: [PointerSource] {
        family.hasTouchpad ? PointerSource.allCases : [.leftStick, .rightStick]
    }

    static func pointerName(_ source: PointerSource) -> String {
        switch source {
        case .leftStick: "Stick izq."
        case .rightStick: "Stick der."
        case .touchpad: "Touchpad"
        }
    }

    // MARK: Bindings

    private var groups: [(String, [ControllerButton])] {
        var list: [(String, [ControllerButton])] = [
            ("Botones", [.a, .b, .x, .y]),
            ("Bumpers y gatillos", [.l1, .r1, .l2, .r2]),
            ("Cruceta", [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
            ("Stick izquierdo", [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight, .l3]),
            ("Stick derecho", [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight, .r3]),
            ("Centro", [.start, .select]),
        ]
        if family.hasTouchpad { list.append(("Touchpad", [.touchpadLeft, .touchpadRight])) }
        return list
    }

    private var bindingsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.1, id: \.self) { button in row(button).id(button) }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .onChange(of: selected) { if let selected { withAnimation { proxy.scrollTo(selected, anchor: .center) } } }
        }
    }

    private func row(_ button: ControllerButton) -> some View {
        let output = layer.flatMap { actionSet.layers[$0]?.bindings[button] }
        let inherited = layer != nil && output == nil
        let shown = output ?? actionSet.base.bindings[button] ?? ControllerOutput.none
        let held = monitor.pressed.contains(button)
        return HStack(spacing: 8) {
            Text(family.label(button))
                .font(.callout.weight(.medium))
                .frame(width: 110, alignment: .leading)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(held ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1)))
            if capturing == button {
                Text("Presiona una tecla…").foregroundStyle(Color.accentColor)
                Spacer()
                Button("Cancelar") { stopCapture() }.controlSize(.small)
            } else {
                Menu {
                    Button("Asignar tecla…") { startCapture(button) }
                    Section("Mouse") {
                        Button("Clic izquierdo") { set(button, .mouse(.left)) }
                        Button("Clic derecho") { set(button, .mouse(.right)) }
                        Button("Clic central") { set(button, .mouse(.middle)) }
                    }
                    if layer == nil, !actionSet.layers.isEmpty {
                        Section("Mantener capa") {
                            ForEach(actionSet.layers.keys.sorted(), id: \.self) { name in Button("Capa \(name)") { set(button, .holdLayer(name)) } }
                        }
                    }
                    Divider()
                    Button("Nada") { set(button, ControllerOutput.none) }
                    if layer != nil, !inherited { Button("Usar el de la base") { set(button, nil) } }
                } label: {
                    Text(Self.outputName(shown) + (inherited ? " (base)" : ""))
                        .foregroundStyle(inherited || shown == .none ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(selected == button ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { selected = button }
    }

    static func outputName(_ output: ControllerOutput) -> String {
        switch output {
        case .key(let name): "Tecla " + KeyCodes.displayName(name)
        case .mouse(.left): "Clic izquierdo"
        case .mouse(.right): "Clic derecho"
        case .mouse(.middle): "Clic central"
        case .holdLayer(let name): "Mantener capa \(name)"
        case .none: "Nada"
        }
    }

    /// `nil` removes a layer's override.
    private func set(_ button: ControllerButton, _ output: ControllerOutput?) {
        selected = button
        update { set in
            if let layer {
                set.layers[layer, default: InputLayer()].bindings[button] = output
            } else {
                set.base.bindings[button] = output ?? ControllerOutput.none
            }
        }
    }

    private func startCapture(_ button: ControllerButton) {
        stopCapture()
        capturing = button
        selected = button
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifiers arrive as flag changes; take the press, not the release.
            if event.type == .flagsChanged, event.modifierFlags.intersection([.shift, .control, .option]).isEmpty { return nil }
            guard let name = KeyCodes.name(for: event.keyCode) else { NSSound.beep(); return nil }
            set(button, .key(name))
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        capturing = nil
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Importar…", action: importFile)
            Button("Exportar…", action: exportFile)
            if editable {
                Button("Restablecer") {
                    update { $0 = mode == .desktop ? .desktop : ActionSet() }
                    layer = nil
                }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Guardar") {
                do {
                    try library.saveController(layout, for: entry)
                    dismiss()
                } catch {
                    notice = "No se pudo guardar: \(error)"
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// A Riftway controller file (every program, merged by name) or a Steam
    /// Input configuration (the selected program's bindings).
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "vdf") ?? .data]
        panel.message = "Elige una configuración de control de Riftway (.json) o de Steam Input (controller_*.vdf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "json" {
            do {
                let file = try ControllerExport.read(try Data(contentsOf: url))
                layout.merge(file.layout)
                program = file.layout.programs.keys.sorted().first ?? program
                layer = nil
                notice = "Importado de \(url.lastPathComponent)" + (file.game.map { " (hecho para \($0))" } ?? "") + ". Revisa y guarda."
            } catch {
                notice = "\(url.lastPathComponent) no es una configuración de control de Riftway."
            }
            return
        }
        guard program != nil, program != Self.otherPrograms else {
            notice = "Elige primero el programa al que va la configuración de Steam."
            return
        }
        do {
            let result = try SteamInputImport.parse(try String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
            update { $0 = result.actionSet }
            if let program, var controls = layout.programs[program] {
                controls.mode = .keyboard
                layout.programs[program] = controls
            }
            layer = nil
            notice = "Importado de \(url.lastPathComponent)" + (result.skipped.isEmpty ? "." : "; se omitió lo que solo hace Steam (\(result.skipped.count)).")
        } catch {
            notice = "\(error)"
        }
    }

    /// The whole game's setup, every program, as a file to keep or share.
    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(entry.game.name) - control.json"
        panel.message = "Guarda la configuración de control de \(entry.game.name) (todos sus programas)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ControllerExport(game: entry.game.name, layout: layout).data().write(to: url, options: .atomic)
            notice = "Exportado a \(url.lastPathComponent)."
        } catch {
            notice = "No se pudo exportar: \(error)"
        }
    }
}
