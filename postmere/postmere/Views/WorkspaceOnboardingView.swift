import Accessibility
import AppKit
import SwiftUI

struct WorkspaceOnboardingView: View {
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: BackendSession
    let notifications: MailNotificationService
    let offersInboxSetup: Bool
    let onHoldSetup: (Bool) -> Void
    let onOpenMailbox: () -> Void
    let onSync: @MainActor @Sendable () async -> Void

    @AppStorage("didReviewOnboardingNotifications") private var reviewedNotifications = false
    @AppStorage("didReviewOnboardingDefaultMailApp") private var reviewedDefaultApp = false
    @State private var defaultMail: DefaultMailAppService
    @State private var page = Page.welcome
    @State private var steps: [Page] = []
    @State private var movingForward = true
    @State private var arrived = false
    @State private var serverURL: String
    @State private var workspaceID = ""
    @State private var email = ""
    @State private var password = ""
    @State private var inputIssue: (field: Field, message: String)?
    @FocusState private var focusedField: Field?

    private enum Page: Int { case welcome, workspace, identity, inbox, notifications, defaultMail }
    private enum Field: Hashable { case server, workspace, email, password }

    init(session: BackendSession, notifications: MailNotificationService, defaultMail: DefaultMailAppService? = nil,
         offersInboxSetup: Bool = true,
         onHoldSetup: @escaping (Bool) -> Void = { _ in }, onOpenMailbox: @escaping () -> Void = {},
         onSync: @escaping @MainActor @Sendable () async -> Void = {}) {
        self.session = session
        self.notifications = notifications
        self.offersInboxSetup = offersInboxSetup
        self.onHoldSetup = onHoldSetup
        self.onOpenMailbox = onOpenMailbox
        self.onSync = onSync
        _defaultMail = State(initialValue: defaultMail ?? DefaultMailAppService())
        _serverURL = State(initialValue: session.baseURL)
    }

    private func beginSetup() {
        steps = [.workspace, .identity]
        if offersInboxSetup {
            steps.append(.inbox)
            if !reviewedNotifications { steps.append(.notifications) }
            if !reviewedDefaultApp { steps.append(.defaultMail) }
        }
        go(to: .workspace)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 560 || geometry.size.height < 570
            VStack(spacing: 0) {
                masthead
                    .padding(.horizontal, compact ? 22 : 38)
                    .padding(.top, compact ? 12 : 22)
                GeometryReader { area in
                    ScrollView {
                        Group {
                            if session.isRestoring {
                                ProgressView("Checking your workspace…").controlSize(.small)
                            } else if session.isWaitingForSavedSession {
                                savedSignInRetry
                            } else if page == .welcome {
                                welcome(compact: compact)
                                    .transition(pageTransition)
                            } else {
                                setup(compact: compact)
                                    .transition(pageTransition)
                            }
                        }
                        .padding(.horizontal, compact ? 24 : 40)
                        .padding(.vertical, compact ? 22 : 36)
                        .frame(maxWidth: .infinity, minHeight: area.size.height)
                    }
                }
            }
        }
        .containerBackground(for: .window) {
            GeometryReader { window in
                let canvas = theme == .native ? PostmereTheme.paper : theme.colors(for: scheme).canvas
                canvas.overlay {
                    RadialGradient(colors: [palette.swatch.opacity(0.10), .clear],
                                   center: UnitPoint(x: 0.50, y: 0.24), startRadius: 0,
                                   endRadius: max(320, window.size.width * 0.45))
                }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(id: session.isRestoring) {
            guard !session.isRestoring else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.48)) { arrived = true }
        }
        .task(id: page) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            switch page {
            case .workspace: focusedField = serverURL.isEmpty ? .server : .workspace
            case .identity: focusedField = .email
            default: focusedField = nil
            }
        }
        .onChange(of: serverURL) { if inputIssue?.field == .server { inputIssue = nil } }
        .onChange(of: workspaceID) { if inputIssue?.field == .workspace { inputIssue = nil } }
        .onChange(of: session.errorMessage) {
            if let error = session.errorMessage { AccessibilityNotification.Announcement(error).post() }
        }
        .onChange(of: session.canAccessWorkspace) {
            if !session.canAccessWorkspace, page.rawValue >= Page.inbox.rawValue {
                page = .welcome
            }
        }
        .onChange(of: session.accounts.isEmpty) {
            if page == .inbox, session.canAccessWorkspace, !session.accounts.isEmpty { finishInbox() }
        }
        .onDisappear { password = "" }
    }

    private var masthead: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 31, height: 31)
                .accessibilityHidden(true)
            Text("Postmere")
                .font(.system(size: 21, weight: .medium, design: .serif))
            Spacer()
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let offset: CGFloat = movingForward ? 18 : -18
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)),
                           removal: .opacity.combined(with: .offset(x: -offset)))
    }

    private func welcome(compact: Bool) -> some View {
        VStack(spacing: 0) {
            OnboardingPostage(compact: false, arrived: arrived)
                .frame(width: compact ? 234 : 320, height: compact ? 162 : 222)
                .padding(.bottom, compact ? 12 : 20)
            VStack(spacing: compact ? 14 : 20) {
                VStack(spacing: -4) {
                    Text("A home for")
                    Text("your mail.").italic().foregroundStyle(palette.accentInk)
                }
                .font(.system(size: compact ? 44 : 62, weight: .regular, design: .serif))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A home for your mail.")
                .accessibilityAddTraits(.isHeader)

                Text("Bring your Gmail and Outlook inboxes together in one Postmere workspace.")
                    .font(.system(size: compact ? 15 : 17))
                    .foregroundStyle(.secondary).lineSpacing(3)
                    .frame(maxWidth: 350)

                if let error = session.errorMessage { feedback(error).frame(maxWidth: 360) }

                Button(action: beginSetup) {
                    HStack(spacing: 12) {
                        Text("Get started")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(OnboardingActionStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, compact ? 2 : 6)
            }
            .multilineTextAlignment(.center)
            .opacity(arrived || reduceMotion ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 8)
        }
        .padding(.bottom, compact ? 0 : 24)
    }

    private func setup(compact: Bool) -> some View {
        let currentStep = steps.firstIndex(of: page) ?? 0
        return VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    ForEach(steps.indices, id: \.self) { index in
                        Capsule()
                            .fill(index <= currentStep ? palette.accentInk : PostmereTheme.rule)
                            .frame(width: index == currentStep ? 24 : 7, height: 5)
                    }
                }.accessibilityHidden(true)
                Text("Step \(currentStep + 1) of \(steps.count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                OnboardingPostage(compact: true, arrived: arrived)
                    .frame(width: 86, height: 60)
            }

            Group {
                switch page {
                case .workspace: workspacePage
                case .identity: identityPage
                case .inbox:
                    if session.canAccessWorkspace { inboxPage }
                case .notifications:
                    if session.canAccessWorkspace { notificationPage }
                case .defaultMail:
                    if session.canAccessWorkspace { defaultMailPage }
                case .welcome: EmptyView()
                }
            }
            .id(page).transition(pageTransition)
        }
        .frame(maxWidth: 416, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 32, weight: .medium, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var workspacePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Find your workspace", "Enter the server address and workspace ID from your administrator.")
            field("Server URL", id: .server) {
                TextField("Server URL", text: $serverURL, prompt: Text(verbatim: "https://mail.example.com"))
                    .textContentType(.URL)
                    .onSubmit { if validateServer() { focusedField = .workspace } }
            }
            field("Workspace ID", id: .workspace) {
                TextField("Workspace ID", text: $workspaceID, prompt: Text("Paste your workspace ID"))
                    .onSubmit(continueFromWorkspace)
            }
            navigation(primary: "Continue", back: .welcome, action: continueFromWorkspace)
        }
    }

    private var identityPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Sign in to Postmere", "Use your workspace credentials for \(URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "this server").")
            field("Email address", id: .email) {
                TextField("Email address", text: $email, prompt: Text(verbatim: "you@example.com"))
                    .textContentType(.username)
                    .onSubmit { focusedField = .password }
            }
            field("Password", id: .password) {
                SecureField("Password", text: $password, prompt: Text("Workspace password"))
                    .textContentType(.password).onSubmit(signIn)
            }
            if let error = session.errorMessage { feedback(error) }
            navigation(primary: session.isBusy ? "Signing in…" : "Sign in", back: .workspace,
                       enabled: !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty,
                       action: signIn)
        }
        .disabled(session.isBusy)
    }

    private var inboxPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if session.accountCatalogState == .loaded {
                heading("Connect your first inbox", "Choose where you get your mail. You’ll finish connecting in your browser.")
            } else {
                Text("Your inboxes").font(.system(size: 32, weight: .medium, design: .serif))
                    .accessibilityAddTraits(.isHeader)
            }
            OnboardingInboxPicker(session: session) { await onSync() }
            Button("Set up later", action: finishInbox)
                .buttonStyle(.link).foregroundStyle(palette.accentInk)
        }
    }

    private var notificationPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Mail notifications", "Get notified about new mail, snoozed messages, and follow-up reminders.")
            OnboardingNotificationStep(notifications: notifications,
                                       finishTitle: steps.contains(.defaultMail) ? "Continue" : "Open Postmere") {
                reviewedNotifications = true
                finishNotifications()
            }
        }
    }

    private func finishInbox() {
        if steps.contains(.notifications) {
            go(to: .notifications)
        } else {
            finishNotifications()
        }
    }

    private func finishNotifications() {
        if steps.contains(.defaultMail) {
            go(to: .defaultMail)
        } else {
            onOpenMailbox()
        }
    }

    private var defaultMailPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Default mail app", "Open email links from websites and other apps in a new Postmere draft.")
            OnboardingDefaultMailStep(defaultMail: defaultMail) {
                reviewedDefaultApp = true
                onOpenMailbox()
            }
        }
    }

    private func navigation(primary: String, back: Page, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 20) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if session.isBusy { ProgressView().controlSize(.small) }
                    Text(primary)
                    if !session.isBusy { Image(systemName: "arrow.right").accessibilityHidden(true) }
                }
            }.buttonStyle(OnboardingActionStyle()).disabled(!enabled)
            Button("Back") { go(to: back) }
                .buttonStyle(.link)
                .foregroundStyle(palette.accentInk)
                .keyboardShortcut(.cancelAction)
        }.padding(.top, 3)
    }

    private func field<Control: View>(_ title: String, id: Field, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
            control()
                .textFieldStyle(.roundedBorder).controlSize(.extraLarge)
                .autocorrectionDisabled().focused($focusedField, equals: id)
                .labelsHidden().accessibilityLabel(title)
            if let issue = inputIssue, issue.field == id { feedback(issue.message) }
        }
    }

    private func feedback(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var savedSignInRetry: some View {
        VStack(spacing: 18) {
            OnboardingPostage(compact: true, arrived: true).frame(width: 112, height: 78)
            heading(session.isWaitingForSignOut ? "Finishing sign-out" : "Waiting to reconnect",
                    session.isWaitingForSignOut
                    ? "Your workspace is locked. Postmere will retry sign-out without reopening your saved session."
                    : "Your sign-in is saved securely. Postmere will reopen your workspace when the server can verify it.")
            HStack(spacing: 18) {
                Button("Try Again") { Task { await session.retrySavedSession(force: true) } }
                    .buttonStyle(OnboardingActionStyle())
                Button("Sign Out") { Task { await session.logout() } }.buttonStyle(.link)
            }
            .disabled(session.isBusy)
        }.frame(maxWidth: 390)
    }

    private func go(to destination: Page) {
        inputIssue = nil
        focusedField = nil
        if page == .identity { password = "" }
        movingForward = destination.rawValue > page.rawValue
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.30)) { page = destination }
    }

    private func showIssue(_ message: String, in field: Field) {
        inputIssue = (field, message)
        focusedField = field
        AccessibilityNotification.Announcement(message).post()
    }

    private func validateServer() -> Bool {
        do {
            _ = try BackendHTTPClient.validatedBaseURL(serverURL)
            return true
        } catch {
            showIssue(error.localizedDescription, in: .server)
            return false
        }
    }

    private func continueFromWorkspace() {
        guard validateServer() else { return }
        guard UUID(uuidString: workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            showIssue("Enter the full workspace ID supplied by your administrator.", in: .workspace)
            return
        }
        go(to: .identity)
    }

    private func signIn() {
        guard page == .identity, !session.isBusy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { return }
        let secret = password
        password = ""
        focusedField = nil
        onHoldSetup(true)
        Task {
            await session.login(email: email, password: secret, workspaceID: workspaceID, serverURL: serverURL)
            if !session.canAccessWorkspace {
                onHoldSetup(false)
                focusedField = .password
            } else if offersInboxSetup && session.accounts.isEmpty {
                go(to: .inbox)
            } else {
                finishInbox()
            }
        }
    }
}

struct OnboardingActionStyle: ButtonStyle {
    @Environment(\.postmereAccent) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 23).frame(minHeight: 40)
            .foregroundStyle(.white)
            .background(palette.accent.gradient, in: .capsule)
            .opacity(enabled ? (configuration.isPressed ? 0.86 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
