import SwiftUI

/// Welcome, then two short steps to reach the workspace the Mac uses.
struct MobileSignIn: View {
    let session: BackendSession
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Page.welcome
    @State private var movingForward = true
    @State private var arrived = false
    @State private var serverURL: String
    /// Held only while the person picks between workspaces, to finish signing in.
    @State private var pendingSecret: String?
    @State private var email = ""
    @State private var password = ""
    @State private var issue: (field: Field, message: String)?
    @FocusState private var focused: Field?

    private enum Page: Int { case welcome, workspace, identity }
    private enum Field: Hashable { case server, email, password }

    init(session: BackendSession) {
        self.session = session
        _serverURL = State(initialValue: session.baseURL)
    }

    var body: some View {
        ZStack {
            switch page {
            case .welcome: welcome.transition(transition)
            case .workspace, .identity: step.transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { canvas }
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.1)) { arrived = true }
        }
        .onChange(of: serverURL) { if issue?.field == .server { issue = nil } }
        // A message left from signing out, or a failed attempt, clears once they type again.
        .onChange(of: email) { clearSessionMessage() }
        .onChange(of: password) { if !password.isEmpty { clearSessionMessage() } }
        .onDisappear { password = ""; pendingSecret = nil }
    }

    // MARK: Pages

    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                welcomeContent
                    .frame(maxWidth: 480, minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryButton("Get started") { go(to: .workspace) }
                .padding(.horizontal, 24)
                .frame(maxWidth: 480)
                .padding(.bottom, 12)
        }
        .opacity(arrived || reduceMotion ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : 10)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            OnboardingPostage(compact: false, arrived: arrived)
                .frame(width: 280, height: 194)
                .padding(.bottom, 28)
                .accessibilityHidden(true)
            VStack(spacing: -6) {
                Text("A home for")
                Text("your mail.").italic().foregroundStyle(palette.accentInk)
            }
            .font(.system(size: 46, weight: .regular, design: .serif))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A home for your mail.")
            .accessibilityAddTraits(.isHeader)
            Text("Your Postmere workspace, now in your pocket. The same inboxes, rules and drafts as your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 18)
            Spacer(minLength: 24)
        }
    }

    private var step: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                progress
                if page == .workspace {
                    workspaceFields
                } else if let choices = session.workspaceChoices, pendingSecret != nil {
                    workspaceChoices(choices).transition(transition)
                } else {
                    identityFields
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Group {
                if page == .workspace {
                    primaryButton("Continue", action: continueFromWorkspace)
                } else if session.workspaceChoices != nil, pendingSecret != nil {
                    Button("Use a different account") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                            pendingSecret = nil
                            session.cancelWorkspaceChoice()
                        }
                        focused = .email
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.accentInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(session.isBusy)
                } else {
                    primaryButton(session.isBusy ? "Signing in…" : "Sign in",
                                  enabled: !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty,
                                  action: signIn)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background { bottomBarFade }
        }
        .task(id: page) {
            await Task.yield()
            focused = page == .workspace ? .server : .email
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            Button {
                go(to: page == .identity ? .workspace : .welcome)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 5) {
                ForEach(1...2, id: \.self) { index in
                    Capsule()
                        .fill(index <= page.rawValue ? palette.accentInk : PostmereTheme.rule)
                        .frame(width: index == page.rawValue ? 22 : 7, height: 5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page.rawValue) of 2")
            Spacer()
            OnboardingPostage(compact: true, arrived: true)
                .frame(width: 58, height: 40)
                .accessibilityHidden(true)
        }
    }

    private var workspaceFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Connect to your server",
                    "The Postmere server address you use on your Mac. Your administrator has it.")
            field("Server URL", id: .server) {
                TextField("Server URL", text: $serverURL, prompt: Text(verbatim: "https://mail.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .submitLabel(.continue)
                    .onSubmit(continueFromWorkspace)
            }
        }
    }

    /// Shown when the password was right and the person belongs to several workspaces.
    private func workspaceChoices(_ choices: [BackendSession.WorkspaceChoice]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Choose a workspace",
                    "You belong to \(choices.count) workspaces. You can switch any time in Settings.")
            VStack(spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    Button { finishSignIn(secret: pendingSecret, workspaceID: choice.id) } label: {
                        HStack(spacing: 14) {
                            WorkspaceMonogram(name: choice.name, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(choice.roleTitle).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 66)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.name), \(choice.roleTitle)")
                    .transition(MobileMotion.staggered(index))
                }
            }
            if let error = session.errorMessage { feedback(error) }
        }
        .disabled(session.isBusy)
        .sensoryFeedback(.selection, trigger: session.isBusy) { _, busy in busy }
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Sign in", "Use your workspace credentials for \(host).")
            field("Email address", id: .email) {
                TextField("Email address", text: $email, prompt: Text(verbatim: "you@example.com"))
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
            field("Password", id: .password) {
                SecureField("Password", text: $password, prompt: Text("Workspace password"))
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }
            if let error = session.errorMessage { feedback(error) }
        }
        .disabled(session.isBusy)
    }

    // MARK: Pieces

    private var canvas: some View {
        GeometryReader { proxy in
            PostmereTheme.paper.overlay {
                RadialGradient(colors: [palette.swatch.opacity(0.14), .clear],
                               center: UnitPoint(x: 0.5, y: page == .welcome ? 0.3 : 0.05),
                               startRadius: 0, endRadius: max(320, proxy.size.width * 0.9))
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.5), value: page)
    }

    /// The page's paper behind the bottom button, fading in above it, so fields and
    /// messages scroll away beneath it instead of showing through.
    private var bottomBarFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [PostmereTheme.paper.opacity(0), PostmereTheme.paper],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
            PostmereTheme.paper
        }
        .padding(.top, -20)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    private var host: String {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "this server"
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .medium, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Control: View>(_ title: String, id: Field, @ViewBuilder control: () -> Control) -> some View {
        let active = focused == id
        let invalid = issue?.field == id
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            control()
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: id)
                .accessibilityLabel(title)
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(invalid ? PostmereTheme.destructiveInk : active ? palette.accentInk : PostmereTheme.rule,
                                      lineWidth: active || invalid ? 1.5 : 1)
                }
                .animation(.easeOut(duration: 0.15), value: active)
            if let issue, issue.field == id { feedback(issue.message) }
        }
    }

    private func feedback(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(PostmereTheme.destructiveInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if session.isBusy { ProgressView().tint(.white) }
                Text(title)
                if !session.isBusy { Image(systemName: "arrow.right").accessibilityHidden(true) }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(OnboardingActionStyle())
        .disabled(!enabled || session.isBusy)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = movingForward ? 24 : -24
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)),
                           removal: .opacity.combined(with: .offset(x: -offset)))
    }

    // MARK: Actions

    private func go(to destination: Page) {
        issue = nil
        if page == .identity {
            password = ""
            pendingSecret = nil
            session.cancelWorkspaceChoice()
        }
        movingForward = destination.rawValue > page.rawValue
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { page = destination }
    }

    private func clearSessionMessage() {
        guard !session.isBusy, session.errorMessage != nil else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { session.errorMessage = nil }
    }

    private func validateServer() -> Bool {
        do {
            _ = try BackendHTTPClient.validatedBaseURL(serverURL)
            return true
        } catch {
            issue = (.server, error.localizedDescription)
            focused = .server
            return false
        }
    }

    private func continueFromWorkspace() {
        guard validateServer() else { return }
        go(to: .identity)
    }

    private func signIn() {
        guard !session.isBusy, !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        let secret = password
        password = ""
        focused = nil
        finishSignIn(secret: secret, workspaceID: nil)
    }

    private func finishSignIn(secret: String?, workspaceID: UUID?) {
        guard let secret, !session.isBusy else { return }
        Task {
            await session.login(email: email, password: secret, workspaceID: workspaceID, serverURL: serverURL)
            let choosing = session.workspaceChoices != nil && !session.canAccessWorkspace
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { pendingSecret = choosing ? secret : nil }
            if !choosing, !session.canAccessWorkspace { focused = .password }
        }
    }
}
