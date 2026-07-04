import AppKit

@MainActor
final class MixerScanWindowController: NSWindowController {
    private let textView = NSTextView()
    private var endpoints: [MixerIOEndpoint] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mixer Inputs and Outputs"
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(endpoints: [MixerIOEndpoint], host: String) {
        self.endpoints = endpoints
        window?.title = "Mixer Inputs and Outputs - \(host)"
        textView.string = formattedText(for: endpoints)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let copyButton = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(copyButton)

        let hintLabel = NSTextField(labelWithString: "Use the listed paths to fill channel Name, Volume, Level, and Mute endpoint fields.")
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)
        buttonRow.addArrangedSubview(hintLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView

        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(scrollView)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 460)
        ])
    }

    private func formattedText(for endpoints: [MixerIOEndpoint]) -> String {
        guard !endpoints.isEmpty else {
            return "No named inputs or outputs were found.\n\nCheck that the IP is correct and that the MOTU web app is reachable from this Mac."
        }

        return [
            section("Inputs", endpoints.filter { $0.kind == .input }),
            section("Outputs", endpoints.filter { $0.kind == .output }),
            section("Other Named Endpoints", endpoints.filter { $0.kind == .other })
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private func section(_ title: String, _ endpoints: [MixerIOEndpoint]) -> String {
        guard !endpoints.isEmpty else {
            return ""
        }

        let rows = endpoints.map { endpoint in
            """
            \(endpoint.name)
              Base:   \(endpoint.baseEndpoint)
              Name:   \(endpoint.nameEndpoint)
              Volume: \(endpoint.volumeEndpoint.isEmpty ? "-" : endpoint.volumeEndpoint)
              Level:  \(endpoint.levelEndpoint.isEmpty ? "-" : endpoint.levelEndpoint)
              Mute:   \(endpoint.muteEndpoint.isEmpty ? "-" : endpoint.muteEndpoint)
            """
        }

        return ([title, String(repeating: "=", count: title.count)] + rows).joined(separator: "\n")
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
}
