import Accessibility
import AppKit
import SwiftUI

/// This is the root of every window until the server verifies a workspace
/// session. Completion is session state, never a dismissible local preference.
struct WorkspaceOnboardingView: View {
    @Bindable var session: BackendSession
    @State private var workspaceID = ""
    @State private var email = ""
    @State private var password = ""
    @State private var inputIssue: (field: Field, message: String)?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case server, workspace, email, password }

    private var canSignIn: Bool {
        !session.isBusy && !session.isRestoring
            && !session.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820
            let layout = wide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))

            ScrollView {
                Group {
                    if session.isRestoring {
                        restoringWorkspace
                    } else if session.isWaitingForSavedSession {
                        savedSignInRetry
                    } else {
                        layout {
                            introduction.frame(maxWidth: wide ? 285 : 400, alignment: .leading)
                            signInForm.frame(maxWidth: 400, alignment: .leading)
                        }
                        .padding(wide ? 40 : 24)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(PostmereTheme.paper)
        .frame(minWidth: 360, minHeight: 360)
        .navigationTitle("Welcome to Postmere")
        .onChange(of: session.isRestoring, initial: true) {
            if !session.isRestoring { focusedField = session.baseURL.isEmpty ? .server : .workspace }
        }
        .onChange(of: session.baseURL) { if inputIssue?.field == .server { inputIssue = nil } }
        .onChange(of: workspaceID) { if inputIssue?.field == .workspace { inputIssue = nil } }
        .onChange(of: session.errorMessage) {
            if let error = session.errorMessage { AccessibilityNotification.Announcement(error).post() }
        }
        .onDisappear { password = "" }
    }

    private var wordmark: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            Text("Postmere")
                .font(.system(size: 22, weight: .semibold, design: .serif))
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            wordmark.padding(.bottom, 8)
            Text("Sign in to your workspace")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(PostmereTheme.accentInk)
                .accessibilityAddTraits(.isHeader)
            Text("Use the server URL and workspace ID from your administrator. After signing in, you can add a Google or Outlook account.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                field("Server URL", id: .server) {
                    TextField("Server URL", text: $session.baseURL, prompt: Text(verbatim: "https://mail.example.com"))
                        .textContentType(.URL)
                        .focused($focusedField, equals: .server)
                        .onSubmit { if validateServer() { focusedField = .workspace } }
                }
                field("Workspace ID", id: .workspace) {
                    TextField("Workspace ID", text: $workspaceID)
                        .focused($focusedField, equals: .workspace)
                        .onSubmit { if validateWorkspace() { focusedField = .email } }
                }
                field("Email address", id: .email) {
                    TextField("Email address", text: $email, prompt: Text(verbatim: "you@example.com"))
                        .textContentType(.username)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                }
                field("Password", id: .password) {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .onSubmit(signIn)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .autocorrectionDisabled()
            .disabled(session.isBusy)

            if inputIssue == nil {
                if let error = session.errorMessage {
                    feedback(error)
                } else if let status = session.statusMessage {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }

            Button(action: signIn) {
                HStack(spacing: 8) {
                    if session.isBusy { ProgressView().controlSize(.small).accessibilityHidden(true) }
                    Text(session.isBusy ? "Signing in…" : "Sign In")
                }
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSignIn)
        }
    }

    private func field<Control: View>(_ title: String, id: Field, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).accessibilityHidden(true)
            control().labelsHidden().accessibilityLabel(title)
            if let issue = inputIssue, issue.field == id { feedback(issue.message) }
        }
    }

    private func feedback(_ message: String) -> some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            PostmereIcon("exclamationmark.circle", size: 14)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var restoringWorkspace: some View {
        VStack(spacing: 16) {
            wordmark
            ProgressView("Checking your workspace…")
                .controlSize(.small)
        }
        .padding(24)
    }

    private func showIssue(_ message: String, in field: Field) {
        inputIssue = (field, message)
        focusedField = field
        AccessibilityNotification.Announcement(message).post()
    }

    private var savedSignInRetry: some View {
        VStack(spacing: 20) {
            wordmark
            VStack(spacing: 8) {
                Text(session.isWaitingForSignOut ? "Finishing sign-out" : "Waiting to reconnect").font(.headline)
                Text(session.isWaitingForSignOut
                     ? "Your workspace is locked. Postmere will retry sign-out without reopening your saved session."
                     : "Your sign-in is saved securely. Postmere will reopen your workspace when the server can verify it.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Try Again") { Task { await session.retrySavedSession(force: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Sign Out") { Task { await session.logout() } }
            }
            .disabled(session.isBusy)
        }
        .frame(maxWidth: 380)
        .padding(24)
    }

    private func validateServer() -> Bool {
        do {
            _ = try BackendHTTPClient.validatedBaseURL(session.baseURL)
            return true
        } catch {
            showIssue(error.localizedDescription, in: .server)
            return false
        }
    }

    private func validateWorkspace() -> Bool {
        guard UUID(uuidString: workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            showIssue("Enter the full workspace ID supplied by your administrator.", in: .workspace)
            return false
        }
        return true
    }

    private func signIn() {
        guard canSignIn, validateServer(), validateWorkspace() else { return }
        inputIssue = nil
        let secret = password
        password = ""
        focusedField = nil
        Task {
            await session.login(email: email, password: secret, workspaceID: workspaceID)
            if !session.canAccessWorkspace { focusedField = .password }
        }
    }
}
