import SwiftUI

/// The toolbar tag button. Labels open in a popover anchored to it.
struct MessageLabelButton: View {
    let runtime: MailRuntime
    let message: MailMessage?
    @Environment(\.postmereAccent) private var palette
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            PostmereLabel("Label", symbol: "tag", size: 17)
                .labelStyle(.iconOnly)
                .toolbarIcon(active: isPresented ? palette.accentInk : nil)
        }
        .help("Edit labels or categories for this message")
        .accessibilityLabel("Label message")
        .accessibilityValue(isPresented ? "Shown" : "Hidden")
        .disabled(message?.mailAccount.isConnected != true)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let message {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.mailAccount.remote?.provider == "microsoft" ? "Categories" : "Labels")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 14)
                    ScrollView {
                        // Room for the search field's focus ring, which draws
                        // outside the field and would be clipped by the scroll view.
                        MessageLabelsView(runtime: runtime, message: message)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 360)
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.vertical, 14)
                .frame(width: 300)
            }
        }
        // A different message closes the popover rather than relabelling it.
        .onChange(of: message?.id) { isPresented = false }
    }
}

struct MessageLabelsView: View {
    let runtime: MailRuntime
    let message: MailMessage
    @State private var editor: MessageLabelEditor
    @State private var refreshRevision = 0

    init(runtime: MailRuntime, message: MailMessage) {
        self.runtime = runtime
        self.message = message
        _editor = State(initialValue: MessageLabelEditor(runtime: runtime, message: message))
    }

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(editor.outlook ? "Find or create a category" : "Find or create a label", text: $editor.search)
                    .textFieldStyle(.roundedBorder)
                if editor.busy, editor.selection != nil { ProgressView().controlSize(.small).accessibilityLabel("Updating labels") }
            }
            if editor.selection != nil {
                let labels = editor.visibleLabels
                if !labels.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(labels) { label in
                            Toggle(label.name, isOn: Binding(get: { editor.isApplied(label) },
                                set: { applied in Task { await editor.update(label: label, applied: applied) } }))
                                .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                    .disabled(editor.busy || !editor.confirmed)
                } else if editor.name.isEmpty {
                    Text(editor.outlook ? "Enter a name to create your first category." : "Enter a name to create your first label.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if editor.canCreate {
                    Button("Create and apply “\(editor.name)”") { Task { await editor.createAndApply() } }
                        .disabled(editor.busy || !editor.confirmed)
                }
            } else if editor.error == nil {
                ProgressView(editor.outlook ? "Loading categories…" : "Loading labels…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            if let error = editor.error {
                Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if editor.needsReconnect { AccountSettingsButton(title: "Open Accounts Settings…") }
                else { Button("Refresh") { refreshRevision += 1 }.disabled(editor.busy) }
            }
        }
        .task(id: refreshRevision) { await editor.refresh() }
        .onChange(of: message.id) {
            editor = MessageLabelEditor(runtime: runtime, message: message)
            refreshRevision += 1
        }
    }
}
