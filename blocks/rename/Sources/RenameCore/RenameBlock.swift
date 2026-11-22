import AppKit
import BlockKit
import Foundation
import os

/// Names new screenshots from their content, on device.
///
/// On a `screenshotCaptured` event it shows "Reading the screenshot…" in the
/// peek, reads the text with Vision, asks the on-device model for a name
/// (fallback: a tidy dated name), renames the file in place and shows the new
/// name with Undo. Screenshots that arrive together are handled one at a
/// time, in order. Runs in its own process; the app draws the trees it sends.
public struct RenameBlock: Block {
    nonisolated static let undoLastActionID = "undo-last-rename"
    nonisolated static let resultDuration = 6.0
    nonisolated static let failureDuration = 4.0

    let reader: any TextReading
    let namer: any ScreenshotNaming
    let timeLimit: Duration
    let frontmostAppName: @Sendable @MainActor () -> String?
    let timeZone: TimeZone

    public init() {
        self.init(reader: VisionTextReader(), namer: ModelNamer(), frontmostAppName: { RenameBlock.currentFrontmostAppName() })
    }

    /// For tests: every slow or system-bound part is injected.
    init(
        reader: any TextReading,
        namer: any ScreenshotNaming,
        // Measured on an M1 Pro in use: the on-device model takes 3.5 to 9 s
        // for one name, so 10 s fell back to a dated name most of the time.
        timeLimit: Duration = .seconds(20),
        frontmostAppName: @escaping @Sendable @MainActor () -> String? = { nil },
        timeZone: TimeZone = .current
    ) {
        self.reader = reader
        self.namer = namer
        self.timeLimit = timeLimit
        self.frontmostAppName = frontmostAppName
        self.timeZone = timeZone
    }

    public var id: String { "rename" }

    public func start(_ ctx: Context) {
        let pipeline = RenamePipeline(reader: reader, namer: namer, renamer: Renamer(), timeLimit: timeLimit, timeZone: timeZone)
        let session = RenameSession(ctx, pipeline: pipeline, frontmostAppName: frontmostAppName)
        ctx.on(.screenshotCaptured) { event in
            // A replay is a screenshot from before this process started; the
            // in-app block never saw one either, so it is not named again.
            guard !event.replay, let shot = event.screenshot else { return }
            session.captured(shot)
        }
        ctx.onInput { session.input($0) }
        ctx.onAction { session.action($0) }
        session.started()
    }

    /// The app in front when the screenshot arrived, unless it is Mantel,
    /// which started this process.
    static func currentFrontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getppid(),
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }
}

/// One run of the block: the queue, the job being named, the recent renames
/// and the views built from them.
@MainActor
final class RenameSession {
    private let ctx: Context
    private let pipeline: RenamePipeline
    private let renamer = Renamer()
    private let recentsStore: RecentsStore
    private let frontmostAppName: @MainActor () -> String?
    private let log = Logger(subsystem: "dev.mantel.Mantel", category: "rename")

    private var state = RenameState()
    private var queue: [RenameJob] = []
    private var current: RenameJob?
    private var worker: Task<Void, Never>?
    /// Files this block moved back by undo. The watcher may report them as
    /// new; they must not be renamed again.
    private var undonePaths: Set<String> = []
    /// The model status last sent as the settings note.
    private var sentStatus: ModelStatus?
    /// How long the presentation on screen was asked to stay; nil while naming.
    private var shownDuration: Double?

    init(_ ctx: Context, pipeline: RenamePipeline, frontmostAppName: @escaping @MainActor () -> String?) {
        self.ctx = ctx
        self.pipeline = pipeline
        self.frontmostAppName = frontmostAppName
        recentsStore = RecentsStore(dataFolder: ctx.dataFolder)
        state.recents = recentsStore.load()
    }

    /// After `welcome`: the model status note and the menu action.
    func started() {
        refreshModelStatus()
        sendActions()
    }

    // MARK: Queue

    func captured(_ shot: Screenshot) {
        let url = shot.url.standardizedFileURL
        if undonePaths.remove(url.path) != nil { return }
        guard current?.url != url, !queue.contains(where: { $0.url == url }) else { return }
        queue.append(RenameJob(url: url, createdAt: shot.date, appName: frontmostAppName()))
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else {
            state.waiting = queue.count
            if current != nil { update() }
            return
        }
        let job = queue.removeFirst()
        current = job
        state.waiting = queue.count
        state.thumbnail = nil
        state.currentName = job.url.lastPathComponent
        state.phase = .naming
        refreshModelStatus()
        present(duration: nil)

        let pipeline = self.pipeline
        let options = RenameSettings.options(from: ctx.settings)
        worker = Task { [weak self] in
            let thumbnail = await pipeline.thumbnail(for: job.url)
            if let self, let thumbnail, self.current?.id == job.id { self.show(thumbnail) }
            let outcome = await pipeline.run(job, options: options)
            self?.finish(job, outcome)
        }
    }

    private func show(_ thumbnail: Data) {
        state.thumbnail = ctx.image(thumbnail, size: RenameTrees.imageSize, cornerRadius: RenameTrees.imageRadius)
        update()
    }

    private func finish(_ job: RenameJob, _ outcome: RenameOutcome) {
        guard current?.id == job.id else { return }
        current = nil
        worker = nil
        let isLast = queue.isEmpty
        switch outcome {
        case let .renamed(from, to, usedFallback):
            let item = RecentRename(
                folderPath: to.deletingLastPathComponent().path,
                newName: to.lastPathComponent,
                originalName: Renamer.originalName(of: to) ?? from.lastPathComponent,
                renamedAt: Date(),
                usedFallback: usedFallback
            )
            state.recents.insert(item, at: 0)
            if state.recents.count > RecentsStore.limit {
                state.recents.removeLast(state.recents.count - RecentsStore.limit)
            }
            saveRecents()
            if isLast {
                state.phase = .renamed(item)
                present(duration: RenameBlock.resultDuration)
            }
        case .dropped:
            if isLast {
                state.phase = .idle
                ctx.dismiss()
            }
        case let .failed(reason):
            if isLast {
                state.phase = .failed(reason)
                present(duration: RenameBlock.failureDuration)
            }
        }
        startNextIfIdle()
    }

    // MARK: The view

    /// Naming, the result and a failure all show the same peek: which
    /// screenshot, what is happening to it, and Undo once it is renamed.
    private func present(duration: Double?) {
        shownDuration = duration
        ctx.present(
            peek: ViewSlot(width: RenameTrees.peekSize.width, height: RenameTrees.peekSize.height, root: peekTree()),
            expanded: ViewSlot(width: RenameTrees.expandedSize.width, height: RenameTrees.expandedSize.height, root: RenameTrees.recents(state)),
            priority: .standard,
            for: duration
        )
    }

    /// Sends both trees again after the state changed under a presentation.
    /// The app keeps a draining bar going when the same bar comes again.
    private func update() {
        ctx.update(peek: peekTree(), expanded: RenameTrees.recents(state))
    }

    private func peekTree() -> ViewNode {
        RenameTrees.peek(state, undoWindow: shownDuration ?? RenameBlock.resultDuration)
    }

    // MARK: Input

    func input(_ input: WireInput) {
        guard case let .button(id) = input else { return }
        if id == RenameTrees.undoID {
            undoShown()
        } else if id.hasPrefix(RenameTrees.revertPrefix),
                  let uuid = UUID(uuidString: String(id.dropFirst(RenameTrees.revertPrefix.count))),
                  let item = state.recents.first(where: { $0.id == uuid }) {
            revert(item)
        }
    }

    func action(_ id: String) {
        if id == RenameBlock.undoLastActionID { undoLast() }
    }

    /// "Undo Last Rename": on while the newest rename can be undone. Sent
    /// whenever the list changes; a file deleted meanwhile leaves it on, and
    /// choosing it then shows why it failed in the list.
    private func sendActions() {
        let last = state.recents.first
        let enabled = last.map { !$0.reverted && FileManager.default.fileExists(atPath: $0.renamedURL.path) } ?? false
        ctx.setActions([ActionItem(id: RenameBlock.undoLastActionID, title: "Undo Last Rename", enabled: enabled)])
    }

    // MARK: Undo

    private func undoShown() {
        guard case let .renamed(item) = state.phase else { return }
        revert(item)
    }

    private func undoLast() {
        guard let last = state.recents.first else { return }
        revert(last)
    }

    /// Move a renamed file back to its original name.
    private func revert(_ item: RecentRename) {
        guard let index = state.recents.firstIndex(where: { $0.id == item.id }), !state.recents[index].reverted else { return }
        var isShown = false
        if case let .renamed(shown) = state.phase, shown.id == item.id { isShown = true }
        do {
            let restored = try renamer.undo(item.renamedURL, originalName: item.originalName)
            undonePaths.insert(restored.standardizedFileURL.path)
            state.recents[index].reverted = true
            state.listMessage = nil
            saveRecents()
            log.info("reverted \(item.newName, privacy: .private) to \(item.originalName, privacy: .private)")
            if isShown {
                state.phase = .idle
                ctx.dismiss()
            } else {
                update()
            }
        } catch {
            let message = (error as? RenameError)?.message ?? RenameError.failed("").message
            log.error("revert failed: \(String(describing: error), privacy: .private)")
            if isShown {
                state.phase = .failed(message)
                present(duration: RenameBlock.failureDuration)
            } else {
                state.listMessage = message
                update()
            }
        }
    }

    // MARK: Helpers

    /// Sends the model status as the settings note when it changed.
    private func refreshModelStatus() {
        let status = pipeline.namer.status
        guard status != sentStatus else { return }
        sentStatus = status
        ctx.setNote(key: RenameSettings.Key.modelStatus, text: status.explanation)
    }

    /// Writes the list and offers Undo Last Rename for its newest entry.
    private func saveRecents() {
        do {
            try recentsStore.save(state.recents)
        } catch {
            log.error("saving recent renames failed: \(String(describing: error), privacy: .private)")
        }
        sendActions()
    }
}
