import AppKit
import RiftwayCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            VStack(spacing: 6) {
                Text("Arrastra aquí un instalador de Windows")
                    .font(.title3.weight(.semibold))
                Text("Archivos .exe o .msi. También puedes darles doble clic en Finder.")
                    .foregroundStyle(.secondary)
            }
            Button("Elegir archivo…") { model.chooseFiles() }
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open([url]) }
                }
            }
            return true
        }
        .sheet(item: Binding(get: { model.current }, set: { if $0 == nil { model.dismissCurrent() } })) { file in
            AnalysisView(file: file, remaining: model.remaining) { model.dismissCurrent() }
        }
        .sheet(isPresented: $model.showsAssociationOffer) {
            AssociationOfferView { model.associationOfferAnswered(accept: $0) }
        }
    }
}

struct AnalysisView: View {
    let file: PendingFile
    let remaining: Int
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = file.report {
                ReportContent(report: report)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Analizando \(file.url.lastPathComponent)…")
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
            Divider()
            HStack {
                if file.report != nil, case .installer = file.report!.kind {
                    Text("La instalación llega en el siguiente hito.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                Button(remaining > 0 ? "Siguiente (\(remaining))" : "Cerrar", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Instalar") {}
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
            }
            .padding(16)
        }
        .frame(width: 560)
    }
}

struct ReportContent: View {
    let report: InstallerReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                icon
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                    let subtitle = [report.company, report.version.map { "versión \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                    Text(ReportText.kind(report.kind))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .padding(.top, 2)
                }
            }

            if case .unsupported(let reason) = report.kind {
                Notice(text: ReportText.unsupported(reason), tone: .problem)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                Fact("Archivo", "\(report.file.lastPathComponent) · \(ReportText.size(report.fileSize))")
                if let arch = report.architecture { Fact("Arquitectura", arch) }
                if let origin = ReportText.origin(report.origin) { Fact("Descargado de", origin) }
                if let level = ReportText.executionLevel(report.executionLevel) { Fact("Permisos", level) }
                if report.isDotNet { Fact("Requiere", ".NET (se instalará en la botella)") }
                if !report.companions.isEmpty {
                    Fact("Archivos adicionales", report.companions.map(\.lastPathComponent).joined(separator: ", "))
                }
            }

            let signature = ReportText.signature(report.signature)
            Notice(text: signature.text, tone: signature.tone, symbol: "signature")
        }
        .padding(20)
    }

    @ViewBuilder private var icon: some View {
        if let data = report.icon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Notice: View {
    let text: String
    let tone: ReportText.Tone
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol ?? (tone == .problem ? "exclamationmark.octagon" : "exclamationmark.triangle"))
                .foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(tone == .neutral ? 0.08 : 0.12)))
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .caution: .orange
        case .problem: .red
        }
    }
}

struct AssociationOfferView: View {
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("¿Abrir los archivos de Windows con Riftway?")
                .font(.title3.weight(.semibold))
            Text("Así, al darle doble clic a un instalador .exe o .msi en Finder, Riftway lo revisa y te ayuda a instalarlo. macOS te pedirá confirmarlo. Puedes cambiarlo cuando quieras en Ajustes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Ahora no") { answer(false) }.keyboardShortcut(.cancelAction)
                Button("Usar Riftway") { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct SettingsView: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Archivos de Windows") {
                row("Programas (.exe)", FileAssociation.executable)
                row("Instaladores (.msi)", FileAssociation.installer)
                if !FileAssociation.isRiftwayDefaultForAll {
                    Button("Abrir ambos con Riftway") {
                        Task { await FileAssociation.makeRiftwayDefault(); refresh += 1 }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .frame(width: 460)
        .fixedSize()
    }

    private func row(_ title: String, _ type: UTType) -> some View {
        LabeledContent(title) {
            if FileAssociation.isRiftwayDefault(for: type) {
                Label("Riftway", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(FileAssociation.handlerName(for: type) ?? "Ninguna app").foregroundStyle(.secondary)
            }
        }
    }
}
