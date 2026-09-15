import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import WispCore

/// Per-app state kept between calls.
final class AppSession {
    let app: NSRunningApplication
    let ax: AXEl
    var info: AppInfo
    let revisions = RevisionStore()
    var lastScreenshot: ScreenshotResult?
    var instructionsShown = false
    var needsSettle = false
    var background: Bool
    var chromiumEnabled = false
    var lastWindow: WindowInfo?
    var lastActionAt: Date?

    init(app: NSRunningApplication, background: Bool) {
        self.app = app
        self.ax = AXEl.app(pid: app.processIdentifier)
        self.info = AppResolver.info(for: app)
        self.background = background
    }

    var pid: pid_t { app.processIdentifier }
    var displayName: String { info.name }
}

enum ResolvedTarget {
    case app(AppSession, WindowInfo)
    case tab(ChromeTab)
}

/// Serializes all work on the daemon; cancellation and ping bypass the actor.
actor Daemon {
    static let shared = Daemon()

    nonisolated let cancelToken = CancelToken()
    private(set) var policy = Policy.load()
    /// Per-app approvals the user granted from the prompt (`~/.config/wisp/approvals.json`).
    private let approvals = ApprovalStore(url: URL(fileURLWithPath: WispPaths.approvalsPath))
    /// App the approval prompt is currently up for, reported by `session.status`.
    private var approvalPending: String?
    private var sessions: [pid_t: AppSession] = [:]
    private var chrome: ChromeBackend
    private var activeLabel: String?
    private var powerAssertion: IOPMAssertionID = 0
    private var interventionAt: Date?
    private var lastInterventionType: String?
    private var busy = false
    private var catalogCache: InstructionCatalog?

    /// Per-app instruction catalog (built-in texts plus `~/.config/wisp/instructions`), built on first use and again
    /// whenever the policy changes so `instructionsMode` is picked up.
    private var catalog: InstructionCatalog {
        if let c = catalogCache { return c }
        let c = InstructionCatalog(userDir: WispPaths.instructionsDir, mode: InstructionCatalog.Mode(rawValue: policy.instructionsMode) ?? .merge)
        catalogCache = c
        return c
    }

    private init() {
        chrome = ChromeBackend(port: Policy.load().chromePort)
        approvals.onError = { Log.error($0) }
    }

    // MARK: Lifecycle

    func start() async {
        let p = policy
        await MainActor.run {
            StatusUI.shared.bannerEnabled = p.bannerEnabled
            StatusUI.shared.install()
            StatusUI.shared.onStop = { Daemon.shared.cancelNow(reason: .userStoppedSession, message: "stopped from the menu bar") }
            StatusUI.shared.onQuit = { Daemon.shared.shutdown() }
            CursorOverlay.shared.enabled = p.cursorEnabled
            CursorOverlay.shared.setAccent(hex: p.cursorAccent)
            CursorOverlay.shared.lensEnabled = p.lensEnabled
            CursorOverlay.shared.onActivityChanged = { StatusUI.shared.setActivity($0) }
            StatusUI.shared.bannerText = p.bannerText
            StatusUI.shared.bannerHint = p.bannerHint
        }
        await MainActor.run {
            // Screen lock: abort whatever is in flight and take every overlay off screen; the pre-action guard
            // (`checkScreenLock`) refuses new work until the unlock. Unlock: cached trees may be stale.
            LockScreenMonitor.shared.onLock = {
                Daemon.shared.cancelNow(reason: .screenLocked, message: "the screen was locked")
                CursorOverlay.shared.hideNow()
                StatusUI.shared.hideBanner()
                Task { await Daemon.shared.screenDidLock() }
            }
            LockScreenMonitor.shared.onUnlock = {
                Log.info("screen unlocked; forgetting cached revisions")
                Task { await Daemon.shared.resetAllRevisions() }
            }
            LockScreenMonitor.shared.start()
        }
        await MainActor.run {
            PermissionsMonitor.shared.onGranted = { p in
                Log.info("permission granted: \(p.title)")
                if p == .accessibility, !EventTapMonitor.shared.isRunning { _ = EventTapMonitor.shared.start() }
            }
            PermissionsMonitor.shared.start()
            UpdaterHost.shared.start()
            StatusUI.shared.onCheckForUpdates = { UpdaterHost.shared.checkForUpdates() }
            StatusUI.shared.setUpdatesAvailable(UpdaterHost.shared.isAvailable)
        }
        EventTapMonitor.shared.onEscape = { Daemon.shared.cancelNow(reason: .userStoppedSession, message: "Esc pressed by the user") }
        EventTapMonitor.shared.onUserInput = { type in
            Daemon.shared.cancelNow(reason: .userIntervened, message: "user input detected (\(type.rawValue)) while an action was running; re-run `state` before continuing")
            Task { await Daemon.shared.noteIntervention(type: "\(type.rawValue)") }
        }
        if !EventTapMonitor.shared.start() { Log.warn("Esc/intervention monitoring disabled") }
        Log.info("wispd started; socket=\(WispPaths.socketPath) ax=\(AXIsProcessTrusted()) screen=\(ScreenshotService.hasPermission)")
    }

    nonisolated func cancelNow(reason: WispErrorCode, message: String) {
        cancelToken.cancel(WispError(reason, message))
    }

    nonisolated func shutdown() {
        Log.info("wispd shutting down")
        try? FileManager.default.removeItem(atPath: WispPaths.socketPath)
        try? FileManager.default.removeItem(atPath: WispPaths.pidPath)
        exit(0)
    }

    private func noteIntervention(type: String) {
        interventionAt = Date()
        lastInterventionType = type
        resetAllRevisions()
        Task { @MainActor in CursorOverlay.shared.pauseNow() }
    }

    /// Forgets every cached revision (app sessions and Chrome tabs) so the next `state` returns a full tree instead
    /// of a diff against something the user, or the lock screen, may have changed behind our back.
    func resetAllRevisions() {
        for s in sessions.values { s.revisions.reset() }
        chrome.resetRevisions()
    }

    /// The screen locked while (or after) we were controlling an app: drop the active label and the power assertion.
    func screenDidLock() {
        setActive(nil)
    }

    /// Sets the lens activity (the menu bar follows through `onActivityChanged`). `anchor` is the target window
    /// frame (CG coordinates) the lens attaches to while the cursor is hidden.
    private func setActivity(_ a: WispActivity, anchor: CGRect?) async {
        await MainActor.run { CursorOverlay.shared.setActivity(a, anchor: anchor) }
    }

    /// Same as `setActivity` for `defer` blocks, which cannot await; the main actor runs jobs in order, so an idle
    /// posted here lands after the observing/acting transition that preceded it.
    private func postActivity(_ a: WispActivity) {
        Task { @MainActor in
            // An intervention has already switched the lens to `.paused`; the cancelled call's idle must not cut
            // that second short (the pause resolves to idle on its own).
            if a == .idle, CursorOverlay.shared.activity == .paused { return }
            CursorOverlay.shared.setActivity(a, anchor: nil)
        }
    }

    // MARK: Dispatch

    func dispatch(method: String, params: JSON) async -> JSON {
        do {
            return try await handle(method: method, params: params)
        } catch let e as WispError {
            Log.warn("\(method) failed: \(e)")
            return ["error": e.json]
        } catch {
            Log.error("\(method) crashed: \(error)")
            return ["error": WispError(.internalError, "\(error)").json]
        }
    }

    private func handle(method: String, params: JSON) async throws -> JSON {
        switch method {
        case Proto.Method.ping: return ["result": pingInfo()]
        case Proto.Method.appsList:
            return ["result": .array(AppResolver.listApps(runningOnly: params["running"].bool ?? false).map { $0.json })]
        case Proto.Method.appLaunch:
            let spec = try TargetSpec.parse(params)
            guard case .app(let name, _) = spec else { throw WispError(.invalidParams, "launch needs an app") }
            // A locked screen cannot show a window: refuse before starting a process that would then hang around.
            try checkScreenLock()
            let s = try await session(for: name, launch: true, activate: params["activate"].bool ?? true)
            return ["result": ["app": s.info.json, "windows": .array(AppResolver.windows(of: s.app).map { $0.json })]]
        case Proto.Method.appActivate:
            let spec = try TargetSpec.parse(params)
            guard case .app(let name, let win) = spec else { throw WispError(.invalidParams, "activate needs an app") }
            let s = try await session(for: name, launch: true, activate: true)
            let w = try selectWindow(s, spec: win)
            await EventSynth.bringToFront(s.app, window: w.element)
            return ["result": ["app": s.info.json, "window": w.json]]
        case Proto.Method.appWindows:
            let spec = try TargetSpec.parse(params)
            guard case .app(let name, _) = spec else { throw WispError(.invalidParams, "windows needs an app") }
            let s = try await session(for: name, launch: false, activate: false)
            return ["result": ["app": s.info.json, "windows": .array(AppResolver.windows(of: s.app).map { $0.json })]]
        case Proto.Method.appState:
            let target = try await resolve(TargetSpec.parse(params), launch: true)
            let opts = StateOptions.parse(params)
            return ["result": try await captureState(target, options: opts)]
        case Proto.Method.appScreenshot:
            if let d = params["display"].int {
                return ["result": try await ScreenshotService.captureDisplay(index: d).json]
            }
            let target = try await resolve(TargetSpec.parse(params), launch: true)
            return ["result": try await screenshot(target).json]
        case Proto.Method.appPerform:
            let target = try await resolve(TargetSpec.parse(params), launch: true)
            let action = try UIAction.parse(params["action"])
            let observe = params["observe"].bool ?? true
            let opts = StateOptions.parse(params["state"].isNull ? params : params["state"])
            return ["result": try await perform(target, action: action, params: params, observe: observe, stateOptions: opts)]
        case Proto.Method.appBatch:
            let target = try await resolve(TargetSpec.parse(params), launch: true)
            let steps = params["steps"].array ?? []
            var results: [JSON] = []
            var finalState: JSON = .null
            let opts = StateOptions.parse(params["state"].isNull ? params : params["state"])
            for (i, step) in steps.enumerated() {
                try checkScreenLock()
                let kind = step["kind"].string ?? step["cmd"].string ?? ""
                if kind == "state" {
                    finalState = try await captureState(target, options: StateOptions.parse(step))
                    results.append(["step": .int(i), "kind": "state", "ok": true])
                    continue
                }
                if kind == "sleep" {
                    await EventSynth.sleep(min(10, step["seconds"].double ?? 0.5))
                    results.append(["step": .int(i), "kind": "sleep", "ok": true])
                    continue
                }
                let action = try UIAction.parse(step)
                let last = i == steps.count - 1
                let observe = (step["observe"].bool ?? (last && (params["observe"].bool ?? true)))
                do {
                    let r = try await perform(target, action: action, params: step, observe: observe, stateOptions: opts)
                    results.append(["step": .int(i), "kind": .string(action.kind), "ok": true])
                    if !r["state"].isNull { finalState = r["state"] }
                } catch let e as WispError {
                    results.append(["step": .int(i), "kind": .string(action.kind), "ok": false, "error": e.json])
                    if finalState.isNull, let st = try? await captureState(target, options: opts) { finalState = st }
                    return ["result": ["ok": false, "steps": .array(results), "state": finalState, "failedStep": .int(i), "error": e.json]]
                }
            }
            if finalState.isNull, params["observe"].bool ?? true { finalState = try await captureState(target, options: opts) }
            return ["result": ["ok": true, "steps": .array(results), "state": finalState]]
        case Proto.Method.appInstructions:
            let spec = try TargetSpec.parse(params)
            guard case .app(let name, _) = spec else { throw WispError(.invalidParams, "instructions needs an app") }
            let info = try appInfoForInstructions(name)
            let candidates = instructionCandidates(for: info)
            let c = catalog.compose(candidates: candidates, isBrowser: info.isBrowser)
            return ["result": ["app": info.json, "candidates": .array(candidates.map { .string($0) }),
                               "matched": .array(c.pieces.map { $0.json }), "text": c.text.map { .string($0) } ?? .null,
                               "isBrowser": .bool(info.isBrowser), "mode": .string(catalog.mode.rawValue)]]
        case Proto.Method.sessionCancel:
            cancelNow(reason: .cancelled, message: "cancelled by client")
            return ["result": ["ok": true]]
        case Proto.Method.sessionEnd:
            if let name = params["app"].string, let app = try? AppResolver.findRunning(name), let s = sessions.removeValue(forKey: app.processIdentifier) {
                endSession(s)
            } else if params["app"].isNull {
                for s in sessions.values { endSession(s) }
                sessions.removeAll()
            }
            if let t = params["tab"].string {
                // Ending a tab closes it: a tab the agent is done with has no reason to stay open.
                if let tab = try? await chrome.tab(t) { try? await chrome.closeTab(id: tab.id) }
                chrome.dropTab(t)
            } else if params["app"].isNull {
                // A bare `wisp end` is the end of the turn: unmarked agent tabs are scratch and go away, marks reset.
                await chrome.endTurn()
            }
            setActive(nil)
            return ["result": ["ok": true]]
        case Proto.Method.sessionStatus:
            let activity = await MainActor.run { CursorOverlay.shared.activity }
            return ["result": ["active": activeLabel.map { .string($0) } ?? .null, "busy": .bool(busy),
                               "approvalPending": approvalPending.map { .string($0) } ?? .null,
                               "activity": .string(activity.rawValue), "screenLocked": .bool(LockScreenMonitor.shared.isLocked),
                               "sessions": .array(sessions.values.map { $0.info.json }),
                               "intervention": interventionAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                               "interventionType": lastInterventionType.map { .string($0) } ?? .null]]
        case Proto.Method.policyGet:
            return ["result": policy.json]
        case Proto.Method.policySet:
            policy = Policy.from(json: params)
            try policy.save()
            catalogCache = nil
            chrome.port = policy.chromePort
            let p = policy
            await MainActor.run {
                CursorOverlay.shared.enabled = p.cursorEnabled
                CursorOverlay.shared.setAccent(hex: p.cursorAccent)
                CursorOverlay.shared.lensEnabled = p.lensEnabled
                StatusUI.shared.bannerEnabled = p.bannerEnabled
                StatusUI.shared.bannerText = p.bannerText
                StatusUI.shared.bannerHint = p.bannerHint
            }
            return ["result": policy.json]
        case Proto.Method.approvalsList:
            approvals.reload()
            let pid = getpid()
            let grants: [JSON] = approvals.list().map { g in
                let active = g.grant == .always || approvals.grant(for: g.bundleId, daemonPid: pid) == .session
                return [String: JSON].compact([("app", .string(g.bundleId)), ("grant", .string(g.grant.rawValue)), ("active", .bool(active)),
                                               ("grantedAt", approvals.grantedAt(g.bundleId).map { .string(ISO8601DateFormatter().string(from: $0)) })])
            }
            return ["result": ["path": .string(WispPaths.approvalsPath), "daemonPid": .int(Int(pid)), "grants": .array(grants)]]
        case Proto.Method.approvalsClear:
            let ok: Bool
            if let app = params["app"].string, !app.isEmpty {
                Log.info("approvals: revoking \(app)")
                ok = approvals.revoke(app)
            } else {
                Log.info("approvals: clearing all grants")
                ok = approvals.clear()
            }
            guard ok else { throw WispError(.internalError, "could not write \(WispPaths.approvalsPath); see `wisp daemon log`") }
            return ["result": ["ok": true, "grants": .array(approvals.list().map { ["app": .string($0.bundleId), "grant": .string($0.grant.rawValue)] })]]
        case Proto.Method.chromeStatus:
            let v = try? await chrome.version()
            let tabs = (try? await chrome.listTabs()) ?? []
            return ["result": ["reachable": .bool(v != nil), "port": .int(chrome.port), "version": v ?? .null, "tabs": .array(tabs.map { $0.json })]]
        case Proto.Method.chromeLaunch:
            let requested = params["port"].int ?? policy.chromePort
            let profile = params["profile"].string.map { URL(fileURLWithPath: $0) } ?? WispPaths.chromeProfileDir
            if let u = params["url"].string { try checkBlockedURL(u) }
            let launched = try await ChromeBackend.launch(port: requested, profile: profile, url: params["url"].string, app: params["app"].string ?? "Google Chrome",
                                                          visible: params["visible"].bool ?? false)
            // Keep the backend (and this turn's tab marks) when the running Wisp Chrome was reused.
            if launched.port != chrome.port { chrome = ChromeBackend(port: launched.port) }
            chrome.registerAgentTabs(launched.tabs)
            let tabs = try await chrome.listTabs()
            return ["result": ["ok": true, "port": .int(launched.port), "profile": .string(profile.path), "hidden": .bool(chrome.isHidden), "tabs": .array(tabs.map { $0.json })]]
        case Proto.Method.chromeTabs:
            return ["result": .array(try await chrome.listTabs().map { $0.json })]
        case Proto.Method.chromeTabNew:
            if let u = params["url"].string { try checkBlockedURL(u) }
            let t = try await chrome.newTab(url: params["url"].string)
            if params["url"].string != nil {
                if let tab = try? await chrome.tab(t.id) { await tab.waitForQuiet(min: 0.3, quiet: policy.settleQuiet, max: policy.settleMax) }
            }
            return ["result": t.json]
        case Proto.Method.chromeTabGoto:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            guard let url = params["url"].string else { throw WispError(.invalidParams, "goto needs `url`") }
            try checkBlockedURL(url)
            try await tab.navigate(url)
            await tab.waitForQuiet(min: 0.3, quiet: policy.settleQuiet, max: policy.settleMax)
            let state = (params["observe"].bool ?? true) ? try await captureState(.tab(tab), options: StateOptions.parse(params)) : .null
            return ["result": ["ok": true, "tab": tab.info.json, "state": state]]
        case Proto.Method.chromeTabEval:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            guard let expr = params["expression"].string else { throw WispError(.invalidParams, "eval needs `expression`") }
            return ["result": ["value": try await tab.evaluate(expr)]]
        case Proto.Method.chromeTabClose:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            try await chrome.closeTab(id: tab.id)
            return ["result": ["ok": true]]
        case Proto.Method.chromeTabBack, Proto.Method.chromeTabForward, Proto.Method.chromeTabReload:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            if method == Proto.Method.chromeTabReload { try await tab.reload() } else { try await tab.history(method == Proto.Method.chromeTabBack ? -1 : 1) }
            await tab.waitForQuiet(min: 0.3, quiet: policy.settleQuiet, max: policy.settleMax)
            let state = (params["observe"].bool ?? true) ? try await captureState(.tab(tab), options: StateOptions.parse(params)) : .null
            return ["result": ["ok": true, "tab": tab.info.json, "state": state]]
        case Proto.Method.chromeTabUpload:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            let files = (params["files"].array ?? []).compactMap { $0.string }
            guard !files.isEmpty else { throw WispError(.invalidParams, "upload needs `files` (absolute paths)") }
            for f in files {
                guard f.hasPrefix("/") else { throw WispError(.invalidParams, "file path must be absolute: \(f)") }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: f, isDirectory: &isDir), !isDir.boolValue else { throw WispError(.invalidParams, "file not found: \(f)") }
            }
            var node: Int? = nil
            if let el = params["el"].int {
                let n = try self.node(el, in: tab.revisions)
                guard let bid = n.handle as? Int else { throw WispError(.invalidElement, "element [\(el)] has no DOM node") }
                node = bid
            }
            return ["result": try await tabAction(tab, kind: "upload", params: params) { try await tab.setFiles(backendNodeId: node, files: files) }]
        case Proto.Method.chromeTabDialog:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            guard let accept = params["accept"].bool else { throw WispError(.invalidParams, "dialog needs `accept` (true to accept, false to dismiss)") }
            guard tab.dialog != nil else { throw WispError(.actionNotAvailable, "no JavaScript dialog is open in tab \(tab.id.prefix(8))") }
            return ["result": try await tabAction(tab, kind: "dialog", params: params) { try await tab.handleDialog(accept: accept, text: params["text"].string) }]
        case Proto.Method.chromeTabMark:
            let tab = try await chrome.tab(params["tab"].string ?? "active")
            guard let m = ChromeBackend.Mark(rawValue: params["mark"].string ?? "") else { throw WispError(.invalidParams, "mark must be deliverable, handoff or none") }
            chrome.mark(tab: tab.id, m)
            return ["result": ["ok": true, "tab": .string(tab.id), "mark": .string(m.label)]]
        case Proto.Method.chromeShow:
            try await chrome.show(tab: params["tab"].string)
            return ["result": ["ok": true, "hidden": .bool(chrome.isHidden)]]
        case Proto.Method.chromeHide:
            await chrome.hide()
            return ["result": ["ok": true, "hidden": .bool(chrome.isHidden)]]
        case Proto.Method.daemonShutdown:
            Task { try? await Task.sleep(nanoseconds: 100_000_000); Daemon.shared.shutdown() }
            return ["result": ["ok": true]]
        case Proto.Method.daemonLog:
            return ["result": ["log": .string(Log.tail(lines: params["lines"].int ?? 100))]]
        default:
            throw WispError(.unknownMethod, "unknown method \(method)")
        }
    }

    nonisolated func pingInfo() -> JSON {
        ["serverApiVersion": .string(Proto.apiVersion), "pid": .int(Int(getpid())),
         "permissions": ["accessibility": .bool(AXIsProcessTrusted()), "screenRecording": .bool(ScreenshotService.hasPermission)],
         "version": .string(WispVersion.string)]
    }

    // MARK: Sessions

    private func session(for spec: String, launch: Bool, activate: Bool) async throws -> AppSession {
        if let app = try AppResolver.findRunning(spec) {
            let s = try await makeSession(app)
            // A running app with no window (a document app whose last document was closed) would fail every action.
            // Since Wisp no longer activates apps, nothing would make it open an untitled window: send it a reopen
            // through Launch Services (no activation) and give it a moment to show one.
            if launch, !AppResolver.windows(of: app).contains(where: { $0.id != nil }), let url = app.bundleURL {
                _ = try? await AppResolver.launch(url: url, activate: activate)
                let deadline = Date().addingTimeInterval(5)
                while !AppResolver.windows(of: app).contains(where: { $0.id != nil }), Date() < deadline { await EventSynth.sleep(0.1) }
            }
            return s
        }
        guard launch else { throw WispError(.appNotFound, "app `\(spec)` is not running") }
        guard let url = try AppResolver.findInstalled(spec) else {
            throw WispError(.appNotFound, "no running or installed app matches `\(spec)`; try `wisp apps`")
        }
        let bundle = Bundle(url: url)
        let bid = bundle?.bundleIdentifier
        let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String ?? bundle?.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        // Ask before launching: a denied or declined app must not be started at all.
        try await authorize(bundleId: bid, name: name, path: url.path)
        Log.info("launching \(url.path)")
        let app = try await AppResolver.launch(url: url, activate: activate && !policy.usesBackground(bundleId: bid, name: name))
        // Wait for the app to finish launching and then for a real (on-screen, CG-backed) window: a state read or
        // an action right after the launch would otherwise find nothing to target. The session is created only
        // once a window exists, so a launch that never shows one leaves nothing behind.
        let deadline = Date().addingTimeInterval(15)
        while !app.isFinishedLaunching, !app.isTerminated, Date() < deadline { await EventSynth.sleep(0.1) }
        while !AppResolver.windows(of: app).contains(where: { $0.id != nil }) {
            guard Date() < deadline else { throw WispError(.launchFailed, "\(name) launched but showed no window within 15 s") }
            await EventSynth.sleep(0.1)
        }
        return try await makeSession(app, authorized: true)
    }

    /// Returns the session for a running app, creating it after the approval check. `authorized` skips the check
    /// when the caller already ran it for this launch. A session that survived (until `wisp end` or the daemon
    /// exits) is reused without asking again, which is what "Allow Once" grants.
    private func makeSession(_ app: NSRunningApplication, authorized: Bool = false) async throws -> AppSession {
        if let s = sessions[app.processIdentifier], !app.isTerminated { return s }
        let info = AppResolver.info(for: app)
        if !authorized { try await authorize(bundleId: info.bundleId, name: info.name, path: info.path) }
        // Another request may have created the session while the prompt was up.
        if let s = sessions[app.processIdentifier], !app.isTerminated { return s }
        let s = AppSession(app: app, background: policy.usesBackground(bundleId: info.bundleId, name: info.name))
        sessions[app.processIdentifier] = s
        AXNotificationHub.shared.observe(pid: app.processIdentifier)
        if ChromiumSupport.isChromiumLike(bundleId: info.bundleId, path: info.path) {
            s.chromiumEnabled = ChromiumSupport.enable(app: s.ax, bundleId: info.bundleId)
        }
        return s
    }

    // MARK: Approval

    /// Applies the policy's approval rules to an app, prompting the user when required. Throws `appNotAllowed` for
    /// forbidden, denied and declined apps; records `session`/`always` grants in the approval store. The daemon
    /// actor stays free while the prompt is up (the alert runs on the main thread), so status and cancel calls keep
    /// working; `busy` is untouched because no action is in flight yet.
    private func authorize(bundleId: String?, name: String, path: String?) async throws {
        let key = bundleId ?? name
        let pid = getpid()
        let label = bundleId.map { "\(name) (\($0))" } ?? name
        approvals.reload() // pick up edits made by `wisp approvals` from another daemon or by hand
        let decision = policy.approvalRules.decide(bundleId: bundleId, name: name, grant: approvals.grant(for: key, daemonPid: pid))
        switch decision {
        case .allowed:
            Log.debug("approval: \(label) allowed")
        case .forbidden(let reason):
            Log.warn("approval: refused \(label): \(reason)")
            throw WispError(.appNotAllowed, "Wisp will not control \(name): it is on the forbidden list for safety")
        case .denied(let reason):
            Log.warn("approval: refused \(label): \(reason)")
            throw WispError(.appNotAllowed, "policy denies controlling \(label); to allow it run `wisp policy set --allow <pattern>` (allow entries beat deny) or edit the deny list in \(WispPaths.policyPath)")
        case .needsApproval(let risk, let subtitle):
            Log.info("approval: asking the user about \(label) (risk \(risk.rawValue))")
            let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
            approvalPending = label
            let choice = await ApprovalUI.ask(appName: name, bundleId: bundleId, icon: icon, risk: risk, subtitle: subtitle)
            approvalPending = nil
            Log.info("approval: user chose \(choice) for \(label)")
            switch choice {
            case .deny:
                throw WispError(.appNotAllowed, "the user declined to let Wisp control \(name)")
            case .once:
                break
            case .session:
                if !approvals.grant(.session, for: key, daemonPid: pid) { Log.warn("approval: session grant for \(label) is not persisted") }
            case .always:
                if !approvals.grant(.always, for: key, daemonPid: pid) { Log.warn("approval: always grant for \(label) is not persisted") }
            }
        }
    }

    /// Throws `blockedURL` when the URL's host is on the policy's blocked list.
    private func checkBlockedURL(_ url: String) throws {
        if ApprovalRules.isBlocked(url: url, hosts: policy.blockedURLs) {
            let host = ApprovalRules.host(of: url) ?? url
            Log.warn("blocked URL \(url) (host \(host))")
            throw WispError(.blockedURL, "\(host) is blocked by policy")
        }
    }

    /// The window's web content node when its URL is blocked: the root itself if it carries a URL, otherwise the
    /// first `web` descendant. Returns the node and the blocked host.
    private func blockedWebNode(in root: UINode) -> (node: UINode, host: String)? {
        guard !policy.blockedURLs.isEmpty else { return nil }
        var web: UINode? = root.url.map { _ in root }
        if web == nil {
            root.walk { n, _ in if web == nil, n.role == "web", let u = n.url, !u.isEmpty { web = n } }
        }
        guard let node = web, let url = node.url, ApprovalRules.isBlocked(url: url, hosts: policy.blockedURLs) else { return nil }
        return (node, ApprovalRules.host(of: url) ?? url)
    }

    static let blockedPageNote = "# This page's host is blocked by policy; actions inside it are refused."

    private func endSession(_ s: AppSession) {
        AXNotificationHub.shared.stop(pid: s.pid)
        s.revisions.reset()
        if s.chromiumEnabled { _ = s.ax.set("AXManualAccessibility", false) }
    }

    private func resolve(_ spec: TargetSpec, launch: Bool) async throws -> ResolvedTarget {
        try checkScreenLock()
        switch spec {
        case .app(let name, let window):
            let s = try await session(for: name, launch: launch, activate: false)
            let w = try selectWindow(s, spec: window)
            return .app(s, w)
        case .tab(let id):
            return .tab(try await chrome.tab(id))
        }
    }

    private func selectWindow(_ s: AppSession, spec: String?) throws -> WindowInfo {
        var windows = AppResolver.windows(of: s.app)
        if windows.isEmpty {
            // Some apps need a moment after launch/activation.
            usleep(300_000)
            windows = AppResolver.windows(of: s.app)
        }
        guard !windows.isEmpty else {
            throw WispError(.windowNotFound, "\(s.displayName) has no windows (is it showing a window on this space?)")
        }
        if let spec = spec, !spec.isEmpty {
            if let id = UInt32(spec), let w = windows.first(where: { $0.id == id }) { s.lastWindow = w; return w }
            if let idx = Int(spec), idx >= 0, idx < windows.count, !spec.hasPrefix("0x") { s.lastWindow = windows[idx]; return windows[idx] }
            let lower = spec.lowercased()
            if let w = windows.first(where: { ($0.title ?? "").lowercased().contains(lower) }) { s.lastWindow = w; return w }
            throw WispError(.windowNotFound, "no window of \(s.displayName) matches `\(spec)`", data: .array(windows.map { $0.json }))
        }
        let visible = windows.filter { !$0.isMinimized }
        let w = visible.first(where: { $0.isFocused }) ?? visible.first(where: { $0.isMain }) ?? visible.first ?? windows[0]
        s.lastWindow = w
        return w
    }

    private func checkScreenLock() throws {
        if LockScreenMonitor.shared.isLocked || LockScreenMonitor.currentlyLocked() {
            throw WispError(.screenLocked, "the screen is locked")
        }
    }

    private func setActive(_ label: String?) {
        if activeLabel == label {
            if label != nil { Task { @MainActor in StatusUI.shared.touch() } }
            return
        }
        activeLabel = label
        Task { @MainActor in StatusUI.shared.setActive(app: label) }
        if label != nil, powerAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Wisp is controlling an application" as CFString, &powerAssertion)
        } else if label == nil, powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }

    // MARK: State

    private var screenBounds: CGRect {
        NSScreen.screens.map { s -> CGRect in
            let h = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: s.frame.origin.x, y: h - s.frame.origin.y - s.frame.height, width: s.frame.width, height: s.frame.height)
        }.reduce(CGRect.null) { $0.union($1) }
    }

    func captureState(_ target: ResolvedTarget, options: StateOptions) async throws -> JSON {
        switch target {
        case .app(let s, let w): return try await captureAppState(s, window: w, options: options)
        case .tab(let t): return try await captureTabState(t, options: options)
        }
    }

    private func captureAppState(_ s: AppSession, window w0: WindowInfo, options: StateOptions) async throws -> JSON {
        setActive(s.displayName)
        await setActivity(.observing, anchor: w0.frame)
        defer { postActivity(.idle) }
        var w = w0
        var settled = true
        var busyIndicator = false
        if s.needsSettle {
            let outcome = await settle(s)
            settled = outcome == .settled
            busyIndicator = outcome == .busyIndicator
            w = (try? selectWindow(s, spec: nil)) ?? w
        }
        let clip = w.frame.intersection(screenBounds)
        var snapOpts = AXSnapshotter.Options()
        snapOpts.includeMenus = options.includeMenus
        var extras: [AXEl] = s.ax.children.filter { $0.role == "AXMenu" }
        if options.includeMenus, let mb = s.ax.value(kAXMenuBarAttribute) as? AXEl { extras.append(mb) }
        let snapper = AXSnapshotter(options: snapOpts)
        snapper.focusedElement = s.ax.focusedElement
        var root = snapper.snapshot(window: w.element, windowFrame: w.frame, app: s.ax, extraRoots: extras)
        if root.descendantCount < 3, !s.chromiumEnabled, ChromiumSupport.isChromiumLike(bundleId: s.info.bundleId, path: s.info.path) || root.descendantCount == 0 {
            if ChromiumSupport.enable(app: s.ax, bundleId: s.info.bundleId) {
                s.chromiumEnabled = true
                await EventSynth.sleep(0.4)
                root = snapper.snapshot(window: w.element, windowFrame: w.frame, app: s.ax, extraRoots: extras)
            }
        }
        var tOpts = TreeTransform.Options()
        tOpts.clip = clip.isNull ? nil : clip.uiRect
        tOpts.maxChildren = policy.maxChildren
        root = TreeTransform.apply(root, options: tOpts)
        let title = w.title ?? root.name ?? ""
        let header = "# \(s.displayName) — \"\(title)\" (window \(w.id.map { String($0) } ?? "?"), \(Int(w.frame.width))x\(Int(w.frame.height)) at \(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)); pid \(s.pid))"
        var instructions: String? = nil
        if options.instructions ?? !s.instructionsShown {
            instructions = catalog.compose(candidates: instructionCandidates(for: s.info), isBrowser: s.info.isBrowser).text
            s.instructionsShown = true
        }
        var result = try await finishState(root: root, header: header, revisions: s.revisions, options: options, settled: settled,
                                           targetJSON: ["kind": "app", "app": s.info.json, "window": w.json],
                                           instructions: instructions, screenshot: {
                                               guard let id = w.id else { throw WispError(.windowNotFound, "window has no CGWindow id (not on screen?)") }
                                               let shot = try await ScreenshotService.captureWindow(id: id, frame: w.frame)
                                               s.lastScreenshot = shot
                                               return shot
                                           })
        if busyIndicator { result["text"] = .string((result["text"].string ?? "") + "\n# not settled (busy indicator visible)") }
        if let blocked = blockedWebNode(in: root) {
            Log.warn("\(s.displayName) shows blocked host \(blocked.host)")
            result["text"] = .string(Daemon.blockedPageNote + "\n" + (result["text"].string ?? ""))
            result["blockedHost"] = .string(blocked.host)
        }
        return result
    }

    /// A DevTools-only action (file upload, dialog answer) that is not a `UIAction`: runs it with the acting lens,
    /// then returns the same `{ok, action, state}` shape as `perform`.
    private func tabAction(_ t: ChromeTab, kind: String, params: JSON, _ body: () async throws -> Void) async throws -> JSON {
        try checkScreenLock()
        cancelToken.reset()
        busy = true
        defer { busy = false }
        setActive("Chrome tab")
        await setActivity(.acting, anchor: await t.windowFrame())
        defer { postActivity(.idle) }
        try await body()
        t.needsSettle = true
        t.lastActionAt = Date()
        var out: [String: JSON] = ["ok": true, "action": .string(kind), "tab": t.info.json]
        if params["observe"].bool ?? true { out["state"] = try await captureState(.tab(t), options: StateOptions.parse(params)) }
        return .object(out)
    }

    private func captureTabState(_ t: ChromeTab, options: StateOptions) async throws -> JSON {
        setActive("Chrome tab")
        await setActivity(.observing, anchor: await t.windowFrame())
        defer { postActivity(.idle) }
        if let d = t.dialog {
            // The renderer is blocked by the dialog: no tree, no evaluate. Report the dialog and how to answer it.
            let header = "# Chrome tab \(t.id.prefix(8)) — \"\(t.info.title)\" \(t.info.url)"
            let note = "# JavaScript \(d.type) dialog is open: \"\(d.message)\" — use `wisp chrome dialog --tab \(t.id.prefix(8)) accept|dismiss [--text S]`"
            return ["target": ["kind": "tab", "tab": t.info.json], "revision": .int(t.revisions.latest?.id ?? 0), "mode": "dialog",
                    "text": .string(header + "\n" + note), "settled": true, "elements": 0, "lines": 2,
                    "dialog": ["type": .string(d.type), "message": .string(d.message)]]
        }
        var settled = true
        if t.needsSettle {
            await t.waitForQuiet(min: policy.settleMin, quiet: policy.settleQuiet, max: policy.settleMax)
            settled = true
        }
        var snap = try await t.snapshot()
        // A busy root means the page is still loading; give it a little more time.
        var waited = 0.0
        while snap.root.states.contains(.busy), waited < policy.settleMax {
            await EventSynth.sleep(0.3)
            waited += 0.3
            snap = try await t.snapshot()
        }
        var tOpts = TreeTransform.Options()
        tOpts.clip = UIRect(x: 0, y: 0, w: snap.viewport.width, h: snap.viewport.height)
        tOpts.maxChildren = policy.maxChildren
        // A web page is one scrollable document: keep controls below the fold (marked offscreen) so they can be
        // targeted; clicking one scrolls it into view first. Dropping them would hide most of a long form.
        tOpts.dropOffscreen = false
        let root = TreeTransform.apply(snap.root, options: tOpts)
        var header = "# Chrome tab \(t.id.prefix(8)) — \"\(snap.title)\" \(snap.url) (viewport \(Int(snap.viewport.width))x\(Int(snap.viewport.height)))"
        if ApprovalRules.isBlocked(url: snap.url, hosts: policy.blockedURLs) {
            Log.warn("Chrome tab \(t.id.prefix(8)) is on blocked host \(ApprovalRules.host(of: snap.url) ?? snap.url)")
            header = Daemon.blockedPageNote + "\n" + header
        }
        var instructions: String? = nil
        if options.instructions ?? !t.instructionsShown {
            // A DevTools tab is a browser surface: the `_browser` block comes first, then the tab-specific text.
            instructions = catalog.compose(candidates: ["chrome-tab"], isBrowser: true).text
            t.instructionsShown = true
        }
        return try await finishState(root: root, header: header, revisions: t.revisions, options: options, settled: settled,
                                     targetJSON: ["kind": "tab", "tab": t.info.json], instructions: instructions, screenshot: {
                                         let shot = try await t.screenshot()
                                         t.lastScreenshot = shot
                                         return shot
                                     })
    }

    private func finishState(root: UINode, header: String, revisions: RevisionStore, options: StateOptions, settled: Bool,
                             targetJSON: JSON, instructions: String?, screenshot: () async throws -> ScreenshotResult) async throws -> JSON {
        var rOpts = RenderOptions()
        rOpts.showBounds = options.bounds
        let previous = revisions.latest
        let rendered = TreeRenderer.render(root, previousIndices: revisions.previousIndices, options: rOpts)
        let rev = revisions.commit(root: root, rendered: rendered, header: header)
        var mode = "full"
        var text: String
        if let q = options.query, !q.isEmpty {
            let filtered = TreeTransform.filter(root, query: q)
            var ids = Set<String>()
            filtered.walk { n, _ in ids.insert(n.identity) }
            let lines = rendered.lines.filter { ids.contains($0.identity) }
            text = header + "\n# query \"\(q)\": \(lines.count) of \(rendered.lines.count) lines\n" + lines.map { $0.text }.joined(separator: "\n")
            mode = "query"
        } else if !options.full, let prev = previous, let d = TreeDiff.diff(old: prev, new: rev, maxLines: options.maxLines) {
            text = header + "\n" + d.text
            mode = d.isEmpty ? "unchanged" : "diff"
        } else {
            text = TreeDiff.budget(rev.fullText, maxLines: options.maxLines)
        }
        var out: [String: JSON] = [
            "target": targetJSON, "revision": .int(rev.id), "mode": .string(mode), "text": .string(text),
            "settled": .bool(settled), "elements": .int(rendered.nodesByIndex.count), "lines": .int(rendered.lines.count),
        ]
        if let i = instructions { out["instructions"] = .string(i); out["text"] = .string("<app_specific_instructions>\n\(i)\n</app_specific_instructions>\n" + text) }
        // Screenshot fallback: when the accessibility tree exposes nothing actionable (custom-drawn apps, canvases,
        // games, an app that has not populated its tree), attach a window screenshot so the caller can look and click
        // by pixel coordinates. Only on a full read (not diffs), and only the first time for a given sparse tree.
        var actionable = 0
        root.walk { n, _ in if TreeTransform.interactiveRoles.contains(n.role) { actionable += 1 } }
        let sparse = actionable == 0 && rendered.nodesByIndex.count < 4
        let autoShot = sparse && mode == "full" && !options.screenshot
        if options.screenshot || (autoShot && ScreenshotService.hasPermission) {
            do {
                out["screenshot"] = try await screenshot().json
                if autoShot {
                    let note = "\n# The accessibility tree is empty or has no actionable elements, so a screenshot of the window is attached. Read it, then click by pixel coordinates: `--at x,y --space screenshot` (coordinates are pixels of this screenshot)."
                    out["text"] = .string((out["text"]?.string ?? text) + note)
                }
            } catch let e as WispError { out["screenshotError"] = e.json }
        } else if autoShot, !ScreenshotService.hasPermission {
            let note = "\n# The accessibility tree is empty or has no actionable elements. Grant Screen Recording and pass `--screenshot` to see the window and click by pixel coordinates (`--at x,y --space screenshot`)."
            out["text"] = .string((out["text"]?.string ?? text) + note)
        }
        return .object(out)
    }

    // MARK: Instructions

    /// Catalog stems for an app, most specific first (see `InstructionCatalog.candidates`).
    private func instructionCandidates(for info: AppInfo) -> [String] {
        catalog.candidates(bundleId: info.bundleId, bundleName: info.bundleName, localizedName: info.name,
                           folderName: info.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
    }

    /// App metadata for `app.instructions`: the running app when there is one, else the installed bundle. Never
    /// launches anything and does not open a session, so the policy deny list does not apply to this read-only query.
    private func appInfoForInstructions(_ spec: String) throws -> AppInfo {
        if let app = try AppResolver.findRunning(spec) { return AppResolver.info(for: app) }
        guard let url = try AppResolver.findInstalled(spec) else {
            throw WispError(.appNotFound, "no running or installed app matches `\(spec)`; try `wisp apps`")
        }
        let bundle = Bundle(url: url)
        let bid = bundle?.bundleIdentifier
        let meta = AppResolver.bundleMeta(for: url, bundleId: bid)
        let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String ?? meta.bundleName ?? url.deletingPathExtension().lastPathComponent
        return AppInfo(bundleId: bid, bundleName: meta.bundleName, name: name, path: url.path, pid: nil, isRunning: false,
                       lastUsed: nil, useCount: nil, isBrowser: meta.isBrowser)
    }

    private func screenshot(_ target: ResolvedTarget) async throws -> ScreenshotResult {
        switch target {
        case .app(let s, let w):
            guard let id = w.id else { throw WispError(.windowNotFound, "window has no CGWindow id") }
            let shot = try await ScreenshotService.captureWindow(id: id, frame: w.frame)
            s.lastScreenshot = shot
            return shot
        case .tab(let t):
            let shot = try await t.screenshot()
            t.lastScreenshot = shot
            return shot
        }
    }

    // MARK: Settle

    private enum SettleOutcome { case settled, timedOut, busyIndicator, cancelled, screenLocked }

    /// Waits for the app to go quiet after an action: a minimum delay, then no AX notifications for `settleQuiet`
    /// and no visible progress/busy indicator in the window, all bounded by `settleMax`.
    private func settle(_ s: AppSession) async -> SettleOutcome {
        let start = s.lastActionAt ?? Date()
        let before = AXNotificationHub.shared.stats(pid: s.pid)?.count ?? 0
        await EventSynth.sleep(policy.settleMin)
        var outcome = SettleOutcome.timedOut
        var busyVisible = false
        while Date().timeIntervalSince(start) < policy.settleMax {
            if cancelToken.isCancelled { outcome = .cancelled; break }
            if LockScreenMonitor.shared.isLocked { outcome = .screenLocked; break }
            let stats = AXNotificationHub.shared.stats(pid: s.pid)
            let quietSince = max(stats?.lastEvent ?? .distantPast, start)
            if Date().timeIntervalSince(quietSince) >= policy.settleQuiet {
                busyVisible = s.lastWindow.map { Daemon.busyIndicatorVisible(in: $0) } ?? false
                if !busyVisible { outcome = .settled; break }
            }
            await EventSynth.sleep(busyVisible ? 0.15 : 0.05)
        }
        if outcome == .timedOut, busyVisible { outcome = .busyIndicator }
        let after = AXNotificationHub.shared.stats(pid: s.pid)?.count ?? 0
        Log.debug("settle \(s.displayName): \(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(after - before) AX notifications, outcome=\(outcome)")
        s.needsSettle = false
        return outcome
    }

    /// Cheap scan for something still in progress: `AXElementBusy` on the window, or a visible progress/busy
    /// indicator among its descendants (depth <= 6, at most 300 elements). A determinate indicator that has reached
    /// its maximum does not count.
    private static func busyIndicatorVisible(in w: WindowInfo) -> Bool {
        if (w.element.value("AXElementBusy") as? Bool) == true { return true }
        let indicatorRoles: Set<String> = ["AXProgressIndicator", "AXBusyIndicator"]
        var visited = 0
        func scan(_ el: AXEl, depth: Int) -> Bool {
            for c in el.children {
                visited += 1
                if visited > 300 { return false }
                if let role = c.role, indicatorRoles.contains(role) {
                    guard let f = c.frame, !f.isEmpty, f.intersects(w.frame) else { continue }
                    if let v = (c.value(kAXValueAttribute) as? NSNumber)?.doubleValue,
                       let m = (c.value(kAXMaxValueAttribute) as? NSNumber)?.doubleValue, m > 0, v >= m { continue }
                    return true
                }
                if depth < 6, scan(c, depth: depth + 1) { return true }
            }
            return false
        }
        return scan(w.element, depth: 1)
    }

    // MARK: Actions

    private func resolvePoint(_ at: (Double, Double), session s: AppSession, window w: WindowInfo, space: String?) -> CGPoint {
        switch space ?? (s.lastScreenshot != nil ? "screenshot" : "window") {
        case "screen": return CGPoint(x: at.0, y: at.1)
        case "screenshot":
            if let shot = s.lastScreenshot { return CGPoint(x: shot.originX + at.0 / shot.scale, y: shot.originY + at.1 / shot.scale) }
            return CGPoint(x: w.frame.origin.x + at.0, y: w.frame.origin.y + at.1)
        default: return CGPoint(x: w.frame.origin.x + at.0, y: w.frame.origin.y + at.1)
        }
    }

    private func node(_ index: Int, in revisions: RevisionStore) throws -> UINode {
        guard let rev = revisions.latest else {
            throw WispError(.staleElement, "no state captured yet for this target (or it was invalidated by user input); run `state` first")
        }
        guard let n = rev.node(at: index) else {
            throw WispError(.invalidElement, "element [\(index)] does not exist in revision \(rev.id); run `state` again")
        }
        return n
    }

    /// Fresh on-screen frame of an element, scrolling it into view if needed.
    private func elementFrame(_ node: UINode, session s: AppSession, window w: WindowInfo) async throws -> CGRect {
        guard let el = node.handle as? AXEl else { throw WispError(.invalidElement, "element has no accessibility handle") }
        guard el.isValid else { throw WispError(.staleElement, "element [\(node.index ?? -1)] no longer exists; run `state` again") }
        var frame = el.frame ?? node.frame?.cgRect
        guard var f = frame, !f.isEmpty else { throw WispError(.elementOffscreen, "element [\(node.index ?? -1)] has no on-screen frame") }
        let visibleArea = w.frame.intersection(screenBounds)
        if !f.intersects(visibleArea) || f.intersection(visibleArea).height < min(8, f.height) {
            if el.perform("AXScrollToVisible") != .success {
                // Scroll the nearest scroll area.
                var p = el.parent
                var hops = 0
                while let cur = p, hops < 14 {
                    if cur.role == "AXScrollArea", let sf = cur.frame {
                        let dy = f.midY - sf.midY
                        let dx = f.midX - sf.midX
                        try await EventSynth.scroll(at: CGPoint(x: sf.midX, y: sf.midY), dx: Int(-dx), dy: Int(-dy), delivery: .pid(s.pid), windowID: w.id, cancel: cancelToken)
                        await EventSynth.sleep(0.15)
                        break
                    }
                    p = cur.parent
                    hops += 1
                }
            } else { await EventSynth.sleep(0.15) }
            frame = el.frame
            guard let nf = frame, nf.intersects(visibleArea) else {
                throw WispError(.elementOffscreen, "element [\(node.index ?? -1)] is off-screen and could not be scrolled into view")
            }
            f = nf
        }
        return f
    }

    private func clampedCenter(_ f: CGRect, in w: WindowInfo) -> CGPoint {
        let vis = f.intersection(w.frame.intersection(screenBounds))
        let r = vis.isNull || vis.isEmpty ? f : vis
        return CGPoint(x: r.midX, y: r.midY)
    }

    func perform(_ target: ResolvedTarget, action: UIAction, params: JSON, observe: Bool, stateOptions: StateOptions) async throws -> JSON {
        cancelToken.reset()
        busy = true
        defer { busy = false; EventTapMonitor.shared.armed = false }
        switch target {
        case .app(let s, let w):
            await setActivity(.acting, anchor: w.frame)
            defer { postActivity(.idle) }
            try await performApp(s, window: w, action: action, params: params)
            var out: [String: JSON] = ["ok": true, "action": .string(action.kind)]
            if observe { out["state"] = try await captureState(target, options: stateOptions) }
            Task { @MainActor in CursorOverlay.shared.hide(after: 1.2) }
            return .object(out)
        case .tab(let t):
            await setActivity(.acting, anchor: await t.windowFrame())
            defer { postActivity(.idle) }
            try await performTab(t, action: action, params: params)
            var out: [String: JSON] = ["ok": true, "action": .string(action.kind)]
            if observe { out["state"] = try await captureState(target, options: stateOptions) }
            Task { @MainActor in CursorOverlay.shared.hide(after: 1.2) }
            return .object(out)
        }
    }

    private func performApp(_ s: AppSession, window w: WindowInfo, action: UIAction, params: JSON) async throws {
        setActive(s.displayName)
        if let el = action.elementIndex, let rev = s.revisions.latest, let blocked = blockedWebNode(in: rev.root), let n = rev.node(at: el) {
            var inside = Set<String>()
            blocked.node.walk { node, _ in inside.insert(node.identity) }
            if inside.contains(n.identity) {
                Log.warn("refusing \(action.kind) on element [\(el)] of \(s.displayName): inside blocked host \(blocked.host)")
                throw WispError(.blockedURL, "\(blocked.host) is blocked by policy; element [\(el)] is inside that page")
            }
        }
        let delivery: Delivery = params["delivery"].string == "hid" ? .hid : .pid(s.pid)
        let space = params["space"].string
        // Operate in place by default: never raise the window or steal the user's focus. A synthetic app-activation
        // event makes the target believe it is active so it accepts our events while staying in the background.
        // `--activate` (activate=true) opts into actually bringing the app forward for the rare app that needs it.
        if params["activate"].bool == true { await EventSynth.bringToFront(s.app, window: w.element) }
        else { await MainActor.run { EventSynth.syntheticActivate(pid: s.pid, windowID: w.id) } }
        let cursor = await MainActor.run { CursorOverlay.shared }
        let useCursor = policy.cursorEnabled && (params["cursor"].bool ?? true)

        func pointFor(el: Int?, at: (Double, Double)?) async throws -> (CGPoint, UINode?) {
            if let el = el {
                let n = try node(el, in: s.revisions)
                let f = try await elementFrame(n, session: s, window: w)
                return (clampedCenter(f, in: w), n)
            }
            if let at = at { return (resolvePoint(at, session: s, window: w, space: space), nil) }
            throw WispError(.invalidParams, "action needs `el` or `at`")
        }
        /// Sheets, popovers and menus are separate CGWindows; address whichever of the app's windows (or of a panel
        /// helper drawing for it) is under the point, falling back to the session window. Unrelated windows on top
        /// are ignored so the click still reaches the target.
        func windowID(at p: CGPoint) -> CGWindowID? { AppResolver.pointerTarget(at: p, pid: s.pid)?.id ?? w.id }
        func deliveryFor(point p: CGPoint, element: UINode?) -> Delivery {
            if case .hid = delivery { return .hid }
            if let ax = element?.handle as? AXEl, ax.pid > 0, ax.pid != s.pid { return .pid(ax.pid) }
            if let hit = AppResolver.pointerTarget(at: p, pid: s.pid), hit.pid != s.pid {
                Log.debug("pointer target at \(p) is an out-of-process panel: \(hit.owner) pid \(hit.pid)")
                return .pid(hit.pid)
            }
            return delivery
        }

        func guardSecure(_ n: UINode?) throws {
            if let n = n, n.states.contains(.secure), !policy.allowSecureFields {
                throw WispError(.secureFieldBlocked, "element [\(n.index ?? -1)] is a secure (password) field; set allowSecureFields in policy or hand off to the user")
            }
        }

        switch action {
        case .click(let el, let at, let button, let count):
            let (p, n) = try await pointFor(el: el, at: at)
            if let n = n, let ax = n.handle as? AXEl, (n.role == "menuitem" || n.role == "menubaritem"), button == .left, count == 1 {
                if useCursor { await cursor.move(to: p) }
                EventTapMonitor.shared.armed = true
                await cursor.pressBegin()
                if ax.perform(kAXPressAction) != .success {
                    try await EventSynth.click(at: p, button: button, count: count, delivery: deliveryFor(point: p, element: n), windowID: windowID(at: p), clickInterval: policy.clickInterval, cancel: cancelToken)
                }
                await EventSynth.sleep(policy.clickInterval)
                await cursor.pressEnd()
            } else {
                if useCursor { await cursor.move(to: p) }
                EventTapMonitor.shared.armed = true
                try await EventSynth.click(at: p, button: button, count: count, delivery: deliveryFor(point: p, element: n), windowID: windowID(at: p), clickInterval: policy.clickInterval,
                                           cancel: cancelToken, beforeDown: { await cursor.pressBegin() }, afterUp: { await cursor.pressEnd() })
            }
        case .move(let el, let at):
            let (p, n) = try await pointFor(el: el, at: at)
            if useCursor { await cursor.move(to: p) }
            EventSynth.move(to: p, delivery: deliveryFor(point: p, element: n), windowID: windowID(at: p))
        case .mouseDown(let el, let at):
            let (p, n) = try await pointFor(el: el, at: at)
            if useCursor { await cursor.move(to: p); await cursor.pressBegin() }
            EventTapMonitor.shared.armed = true
            EventSynth.mouseDown(at: p, button: .left, delivery: deliveryFor(point: p, element: n), windowID: windowID(at: p))
        case .mouseUp(let el, let at):
            let p: CGPoint = (el != nil || at != nil) ? try await pointFor(el: el, at: at).0 : await cursor.currentPoint
            EventSynth.mouseUp(at: p, button: .left, delivery: deliveryFor(point: p, element: nil), windowID: windowID(at: p))
            if useCursor { await cursor.pressEnd() }
        case .drag(let from, let to):
            let a = resolvePoint(from, session: s, window: w, space: space)
            let b = resolvePoint(to, session: s, window: w, space: space)
            if useCursor { await cursor.move(to: a); await cursor.pressBegin() }
            EventTapMonitor.shared.armed = true
            async let follow: Void = useCursor ? cursor.move(to: b, gateOnFinish: true) : ()
            try await EventSynth.drag(from: a, to: b, delivery: deliveryFor(point: a, element: nil), windowID: windowID(at: a), cancel: cancelToken)
            _ = await follow
            if useCursor { await cursor.pressEnd() }
        case .type(let text):
            let focused = s.ax.focusedElement
            if let focused = focused, focused.role == "AXSecureTextField", !policy.allowSecureFields {
                throw WispError(.secureFieldBlocked, "the focused element is a secure (password) field")
            }
            let delivery = keyboardDelivery(delivery, focused: focused, pid: s.pid)
            EventTapMonitor.shared.armed = true
            if text.count > 400 || (text.contains("\n") && text.count > 120) {
                try await EventSynth.paste(text: text, format: .text, delivery: delivery, cancel: cancelToken)
            } else {
                try await EventSynth.typeText(text, delivery: delivery, cancel: cancelToken)
            }
        case .key(let chord):
            let chords = try KeyParser.parse(chord)
            let delivery = keyboardDelivery(delivery, focused: s.ax.focusedElement, pid: s.pid)
            EventTapMonitor.shared.armed = true
            for c in chords {
                try await EventSynth.pressChord(c, delivery: delivery, cancel: cancelToken)
                await EventSynth.sleep(0.04)
            }
        case .setValue(let el, let value):
            let n = try node(el, in: s.revisions)
            try guardSecure(n)
            guard let ax = n.handle as? AXEl else { throw WispError(.invalidElement, "element has no accessibility handle") }
            let f = try await elementFrame(n, session: s, window: w)
            let p = clampedCenter(f, in: w)
            if useCursor { await cursor.move(to: p) }
            EventTapMonitor.shared.armed = true
            _ = ax.set(kAXFocusedAttribute, true)
            var ok = false
            if ax.isSettable(kAXValueAttribute) {
                ok = ax.set(kAXValueAttribute, value) == .success
                if ok { await EventSynth.sleep(0.05); ok = (ax.stringValue ?? "") == value || value.isEmpty }
            }
            if !ok {
                let d = deliveryFor(point: p, element: n)
                try await EventSynth.click(at: p, button: .left, count: 1, delivery: d, windowID: windowID(at: p), clickInterval: policy.clickInterval, cancel: cancelToken,
                                           beforeDown: { await cursor.pressBegin() }, afterUp: { await cursor.pressEnd() })
                try await EventSynth.pressChord(KeyChord(modifiers: [.command], key: .character("a")), delivery: d, cancel: cancelToken)
                if value.isEmpty {
                    try await EventSynth.pressChord(KeyChord(modifiers: [], key: .named("backspace")), delivery: delivery, cancel: cancelToken)
                } else if value.count > 200 || value.contains("\n") {
                    try await EventSynth.paste(text: value, format: .text, delivery: delivery, cancel: cancelToken)
                } else {
                    try await EventSynth.typeText(value, delivery: delivery, cancel: cancelToken)
                }
            }
        case .scroll(let el, let at, let direction, let pages):
            var origin = CGPoint(x: w.frame.midX, y: w.frame.midY)
            var extent = w.frame.size
            if el != nil || at != nil {
                let (p, n) = try await pointFor(el: el, at: at)
                origin = p
                if let n = n, let ax = n.handle as? AXEl, let f = ax.frame { extent = f.size }
            }
            let amount = Double(direction == .up || direction == .down ? extent.height : extent.width) * 0.9 * pages
            var dx = 0, dy = 0
            switch direction {
            case .up: dy = Int(amount)
            case .down: dy = -Int(amount)
            case .left: dx = Int(amount)
            case .right: dx = -Int(amount)
            }
            if useCursor { await cursor.move(to: origin) }
            EventTapMonitor.shared.armed = true
            try await EventSynth.scroll(at: origin, dx: dx, dy: dy, delivery: deliveryFor(point: origin, element: nil), windowID: windowID(at: origin), cancel: cancelToken)
        case .secondaryAction(let el, let name):
            let n = try node(el, in: s.revisions)
            guard let ax = n.handle as? AXEl else { throw WispError(.invalidElement, "element has no accessibility handle") }
            let available = ax.actionNames
            let raw: String
            if available.contains(name) { raw = name }
            else if let r = AXSnapshotter.secondaryActionNames.first(where: { $0.value.lowercased() == name.lowercased() })?.key, available.contains(r) { raw = r }
            else if available.contains("AX" + name) { raw = "AX" + name }
            else if let r = available.first(where: { $0.lowercased() == ("ax" + name).lowercased() }) { raw = r }
            else {
                throw WispError(.actionNotAvailable, "element [\(el)] does not expose action `\(name)`; available: \(n.actions.joined(separator: ", "))")
            }
            if let f = try? await elementFrame(n, session: s, window: w), useCursor { await cursor.move(to: clampedCenter(f, in: w)) }
            EventTapMonitor.shared.armed = true
            await cursor.pressBegin()
            let err = ax.perform(raw)
            await EventSynth.sleep(policy.clickInterval)
            await cursor.pressEnd()
            if err != .success { throw WispError(.accessibilityError, "action `\(name)` failed (AXError \(err.rawValue))") }
        case .selectText(let el, let text, let prefix, let suffix, let selection):
            let n = try node(el, in: s.revisions)
            guard let ax = n.handle as? AXEl else { throw WispError(.invalidElement, "element has no accessibility handle") }
            guard let value = ax.stringValue else { throw WispError(.actionNotAvailable, "element [\(el)] has no text value") }
            let needle = (prefix ?? "") + text + (suffix ?? "")
            guard let r = value.range(of: needle) else { throw WispError(.actionNotAvailable, "text `\(needle)` not found in element [\(el)]") }
            let startOffset = value.distance(from: value.startIndex, to: r.lowerBound) + (prefix ?? "").count
            let utf16Start = value.utf16.distance(from: value.utf16.startIndex, to: value.index(value.startIndex, offsetBy: startOffset).samePosition(in: value.utf16) ?? value.utf16.startIndex)
            let utf16Len = text.utf16.count
            var range: NSRange
            switch selection {
            case .text: range = NSRange(location: utf16Start, length: utf16Len)
            case .cursorBefore: range = NSRange(location: utf16Start, length: 0)
            case .cursorAfter: range = NSRange(location: utf16Start + utf16Len, length: 0)
            }
            if let f = try? await elementFrame(n, session: s, window: w), useCursor { await cursor.move(to: clampedCenter(f, in: w)) }
            EventTapMonitor.shared.armed = true
            _ = ax.set(kAXFocusedAttribute, true)
            let err = ax.setRange(kAXSelectedTextRangeAttribute, range)
            if err != .success { throw WispError(.actionNotAvailable, "could not set selection on element [\(el)] (AXError \(err.rawValue))") }
        case .paste(let text, let format):
            EventTapMonitor.shared.armed = true
            try await EventSynth.paste(text: text, format: format, delivery: delivery, cancel: cancelToken)
        }
        s.needsSettle = true
        s.lastActionAt = Date()
        try cancelToken.check()
    }

    /// Keyboard events go to the process that owns the focused element (Open/Save panels are out-of-process).
    private func keyboardDelivery(_ base: Delivery, focused: AXEl?, pid: pid_t) -> Delivery {
        if case .hid = base { return base }
        if let f = focused, f.pid > 0, f.pid != pid { return .pid(f.pid) }
        return base
    }

    private func performTab(_ t: ChromeTab, action: UIAction, params: JSON) async throws {
        setActive("Chrome tab")
        if ApprovalRules.isBlocked(url: t.info.url, hosts: policy.blockedURLs) {
            let host = ApprovalRules.host(of: t.info.url) ?? t.info.url
            Log.warn("refusing \(action.kind) in Chrome tab \(t.id.prefix(8)): blocked host \(host)")
            throw WispError(.blockedURL, "\(host) is blocked by policy; the tab is on that host")
        }
        let cursor = await MainActor.run { CursorOverlay.shared }
        // A hidden Chrome has nothing on screen to point at; CDP input works regardless.
        let useCursor = policy.cursorEnabled && (params["cursor"].bool ?? true) && !chrome.isHidden
        let space = params["space"].string

        func viewportPoint(_ at: (Double, Double)) -> CGPoint {
            if space == "viewport" || space == "window" { return CGPoint(x: at.0, y: at.1) }
            if let shot = t.lastScreenshot, space != "viewport" { return CGPoint(x: at.0 / shot.scale, y: at.1 / shot.scale) }
            return CGPoint(x: at.0, y: at.1)
        }
        func pointFor(el: Int?, at: (Double, Double)?) async throws -> (CGPoint, UINode?) {
            if let el = el {
                let n = try node(el, in: t.revisions)
                guard let bid = n.handle as? Int else { throw WispError(.invalidElement, "element [\(el)] has no DOM node") }
                return (try await t.center(ofBackendNode: bid), n)
            }
            if let at = at { return (viewportPoint(at), nil) }
            throw WispError(.invalidParams, "action needs `el` or `at`")
        }
        func showCursor(_ p: CGPoint) async {
            guard useCursor, let sp = await t.screenPoint(for: p) else { return }
            await cursor.move(to: sp)
        }

        // Tab input goes through DevTools inside Chrome and never competes with the user's mouse or keyboard, so
        // browser work keeps running while the user works (Esc still cancels; it is handled before the armed check).
        EventTapMonitor.shared.armed = false
        switch action {
        case .click(let el, let at, let button, let count):
            let (p, _) = try await pointFor(el: el, at: at)
            await showCursor(p)
            try await t.click(at: p, button: button, count: count, clickInterval: policy.clickInterval,
                              beforeDown: { await cursor.pressBegin() }, afterUp: { await cursor.pressEnd() })
        case .move(let el, let at):
            let (p, _) = try await pointFor(el: el, at: at)
            await showCursor(p)
            try await t.mouse("mouseMoved", at: p)
        case .mouseDown(let el, let at):
            let (p, _) = try await pointFor(el: el, at: at)
            await showCursor(p); await cursor.pressBegin()
            try await t.mouse("mousePressed", at: p)
        case .mouseUp(let el, let at):
            let (p, _) = try await pointFor(el: el, at: at ?? (0, 0))
            try await t.mouse("mouseReleased", at: p)
            await cursor.pressEnd()
        case .drag(let from, let to):
            let a = viewportPoint(from), b = viewportPoint(to)
            await showCursor(a); await cursor.pressBegin()
            try await t.drag(from: a, to: b)
            await showCursor(b); await cursor.pressEnd()
        case .type(let text):
            try await t.insertText(text)
        case .key(let chord):
            for c in try KeyParser.parse(chord) { try await t.pressChord(c); try? await Task.sleep(nanoseconds: 30_000_000) }
        case .setValue(let el, let value):
            let n = try node(el, in: t.revisions)
            guard let bid = n.handle as? Int else { throw WispError(.invalidElement, "element [\(el)] has no DOM node") }
            if let p = try? await t.center(ofBackendNode: bid) { await showCursor(p) }
            try await t.setValue(backendNodeId: bid, value: value)
        case .scroll(let el, let at, let direction, let pages):
            let vp = try await t.viewport()
            var p = CGPoint(x: vp.width / 2, y: vp.height / 2)
            var extent = CGSize(width: vp.width, height: vp.height)
            if el != nil || at != nil {
                let (pp, n) = try await pointFor(el: el, at: at)
                p = pp
                if let f = n?.frame { extent = CGSize(width: f.w, height: f.h) }
            }
            let amount = (direction == .up || direction == .down ? extent.height : extent.width) * 0.9 * pages
            var dx = 0.0, dy = 0.0
            switch direction {
            case .up: dy = -amount
            case .down: dy = amount
            case .left: dx = -amount
            case .right: dx = amount
            }
            await showCursor(p)
            try await t.scroll(at: p, dx: dx, dy: dy)
        case .secondaryAction(let el, let name):
            let n = try node(el, in: t.revisions)
            guard let bid = n.handle as? Int else { throw WispError(.invalidElement, "element [\(el)] has no DOM node") }
            guard n.actions.contains(where: { $0.lowercased() == name.lowercased() }) else {
                throw WispError(.actionNotAvailable, "element [\(el)] does not expose action `\(name)`; available: \(n.actions.joined(separator: ", "))")
            }
            let p = try await t.center(ofBackendNode: bid)
            await showCursor(p)
            try await t.click(at: p, button: .left, count: 1, clickInterval: policy.clickInterval, beforeDown: { await cursor.pressBegin() }, afterUp: { await cursor.pressEnd() })
        case .selectText(let el, let text, let prefix, let suffix, let selection):
            let n = try node(el, in: t.revisions)
            guard let bid = n.handle as? Int else { throw WispError(.invalidElement, "element [\(el)] has no DOM node") }
            try await t.selectText(backendNodeId: bid, text: text, prefix: prefix, suffix: suffix, selection: selection)
        case .paste(let text, let format):
            var payload = text
            if format == .html { payload = EventSynth.stripTags(text) }
            try await t.insertText(payload)
        }
        t.needsSettle = true
        t.lastActionAt = Date()
        try cancelToken.check()
    }
}
