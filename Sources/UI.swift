import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Model

final class CleanerModel: ObservableObject {
    @Published var input = NSAttributedString()
    @Published var markdownMode: Bool {
        didSet { UserDefaults.standard.set(markdownMode, forKey: "markdownMode") }
    }
    @Published var closeAfterCopy: Bool {
        didSet { UserDefaults.standard.set(closeAfterCopy, forKey: "closeAfterCopy") }
    }
    @Published var copied = false
    @Published var launchAtLogin: Bool = {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }() {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("CleanPaste: could not change login item: \(error)")
                launchAtLogin = oldValue
            }
        }
    }

    weak var inputView: NSTextView?
    var onCopied: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        markdownMode = defaults.bool(forKey: "markdownMode")
        closeAfterCopy = defaults.object(forKey: "closeAfterCopy") as? Bool ?? true
    }

    var output: String {
        markdownMode ? TextCleaner.markdown(input) : TextCleaner.plain(input)
    }

    func copy() {
        let text = output
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)   // plain string only: no RTF/HTML
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
        if closeAfterCopy { onCopied?() }
    }

    func clear() {
        guard let view = inputView else { return }
        view.string = ""
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
        view.undoManager?.removeAllActions()
        input = NSAttributedString()
        view.window?.makeFirstResponder(view)
    }

    /// Puts the cursor in the paste area. Selecting everything means the next ⌘V replaces the old text.
    func focusInput() {
        guard let view = inputView else { return }
        view.window?.makeFirstResponder(view)
        view.selectAll(nil)
    }
}

// MARK: - Rich text paste area

struct RichInput: NSViewRepresentable {
    let model: CleanerModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = scroll.documentView as! NSTextView
        view.isRichText = true            // keep formatting so it can be analysed
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.delegate = context.coordinator
        model.inputView = view
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: CleanerModel
        init(_ model: CleanerModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            // Colours are irrelevant for the conversion; normalise them so pasted text stays readable in dark mode.
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            Coordinator.flattenLists(in: storage)
            storage.endEditing()
            model.input = NSAttributedString(attributedString: storage)
        }

        /// The HTML importer leaves the marker as text ("\t•\t") *and* attaches an NSTextList, so the
        /// text view would draw two bullets. Drop the NSTextList but remember its depth for the converter.
        static func flattenLists(in storage: NSTextStorage) {
            var edits: [(NSRange, NSParagraphStyle, Int)] = []
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let style = value as? NSParagraphStyle, !style.textLists.isEmpty else { return }
                let flat = style.mutableCopy() as! NSMutableParagraphStyle
                flat.textLists = []
                edits.append((range, flat, style.textLists.count - 1))
            }
            for (range, style, level) in edits {
                storage.addAttribute(.paragraphStyle, value: style, range: range)
                storage.addAttribute(.listLevel, value: level, range: range)
            }
        }
    }
}

// MARK: - Popover content

struct ContentView: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CleanPaste").font(.headline)
                Spacer()
                Menu {
                    Toggle("Close window after copying", isOn: $model.closeAfterCopy)
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                    Text("Global shortcut: ⌃⌥V")
                    Divider()
                    Button("Quit CleanPaste") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            ZStack(alignment: .topLeading) {
                RichInput(model: model)
                if model.input.length == 0 {
                    Text("Paste your text here (⌘V)")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            Toggle("Convert to Markdown", isOn: $model.markdownMode)
                .toggleStyle(.switch)

            Text(model.markdownMode ? "Result (Markdown)" : "Result (plain text)")
                .font(.caption)
                .foregroundStyle(.secondary)

            let output = model.output
            ScrollView {
                Group {
                    if output.isEmpty {
                        Text("The cleaned text appears here").foregroundStyle(.secondary)
                    } else {
                        Text(output)
                            .font(.system(size: 13, design: model.markdownMode ? .monospaced : .default))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            HStack {
                Button("Clear") { model.clear() }
                Spacer()
                Button(model.copied ? "Copied ✓" : "Copy") { model.copy() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(output.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 460, height: 560)
    }
}
