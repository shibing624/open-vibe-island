import AppKit
import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class OverlayUICoordinator {

    private static let notificationSurfaceAutoCollapseDelay: TimeInterval = 10

    var notchStatus: NotchStatus = .closed
    var notchOpenReason: NotchOpenReason?
    var islandSurface: IslandSurface = .sessionList()
    var isOverlayVisible: Bool { notchStatus != .closed }

    var overlayDisplayOptions: [OverlayDisplayOption] = []
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics?

    var overlayDisplaySelectionID = OverlayDisplayOption.automaticID {
        didSet {
            guard overlayDisplaySelectionID != oldValue else {
                return
            }
            persistOverlayDisplayPreference()
            refreshOverlayPlacement()
        }
    }

    @ObservationIgnored
    weak var appModel: AppModel?

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var activeIslandCardSessionAccessor: (() -> AgentSession?)?

    @ObservationIgnored
    var isSoundMutedAccessor: (() -> Bool)?

    @ObservationIgnored
    var ignoresPointerExitAccessor: (() -> Bool)?

    /// Overrides the global cursor query so pointer-sensitive behavior stays
    /// deterministic when the host machine's real cursor happens to hover the
    /// overlay area (e.g. during unit tests).
    @ObservationIgnored
    var pointerLocationProvider: (() -> NSPoint)?

    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor?

    @ObservationIgnored
    let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private var screenParametersObserver: NSObjectProtocol?

    @ObservationIgnored
    private var overlayDisplaySelectionTitle: String?

    @ObservationIgnored
    private var overlayTransitionGeneration: UInt64 = 0

    @ObservationIgnored
    private var notificationAutoCollapseTask: Task<Void, Never>?

    var hasPendingNotificationAutoCollapse: Bool {
        notificationAutoCollapseTask != nil
    }

    @ObservationIgnored
    private var autoCollapseSurfaceHasBeenEntered = false

    @ObservationIgnored
    private var isPointerInsideIslandSurface = false

    /// Kept for API compatibility; always false now that the window never
    /// resizes and close transitions are pure SwiftUI.
    var isCloseTransitionPending: Bool { false }

    private var activeIslandCardSession: AgentSession? {
        activeIslandCardSessionAccessor?()
    }

    private var isSoundMuted: Bool {
        isSoundMutedAccessor?() ?? false
    }

    private var ignoresPointerExitDuringHarness: Bool {
        ignoresPointerExitAccessor?() ?? false
    }

    private var currentPointerLocation: NSPoint {
        pointerLocationProvider?() ?? NSEvent.mouseLocation
    }

    private var preferredOverlayScreenID: String? {
        overlayDisplaySelectionID == OverlayDisplayOption.automaticID
            ? nil
            : overlayDisplaySelectionID
    }

    // MARK: - Initialization

    func restoreDisplayPreference() {
        let defaults = UserDefaults.standard
        let storedSelectionID = defaults.string(
            forKey: OverlayDisplayPreferencePolicy.preferenceDefaultsKey
        )
        let restoredSelectionID = OverlayDisplayPreferencePolicy.restoredSelectionID(
            from: storedSelectionID
        )

        if storedSelectionID != nil,
           restoredSelectionID == OverlayDisplayOption.automaticID {
            defaults.removeObject(forKey: OverlayDisplayPreferencePolicy.preferenceDefaultsKey)
            defaults.removeObject(forKey: OverlayDisplayPreferencePolicy.preferenceTitleDefaultsKey)
        }

        overlayDisplaySelectionTitle = defaults.string(
            forKey: OverlayDisplayPreferencePolicy.preferenceTitleDefaultsKey
        )
        overlayDisplaySelectionID = restoredSelectionID
    }

    /// Re-syncs the cached display options and the target panel placement
    /// whenever macOS reports a screen configuration change (hotplug,
    /// arrangement change, sleep/wake). Without this, the picker list keeps
    /// stale entries after disconnect, and a saved preference whose
    /// `CGDirectDisplayID` gets reused for a different physical display can
    /// silently route the island to the wrong screen.
    func startObservingDisplayChanges() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshOverlayDisplayConfiguration()
            }
        }
    }

    isolated deinit {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Overlay transitions

    func toggleOverlay() {
        if notchStatus == .closed {
            notchOpen(reason: .click)
        } else {
            notchClose()
        }
    }

    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) {
        transitionOverlay(
            to: .opened,
            reason: reason,
            surface: surface,
            interactive: true,
            beforeTransition: nil,
            afterStateChange: { [weak self] in
                guard let self else { return }
                self.autoCollapseSurfaceHasBeenEntered = false
                self.isPointerInsideIslandSurface = false
                self.updateNotificationAutoCollapse()
            },
            onPlacementResolved: { [weak self] in
                guard let self, let overlayPlacementDiagnostics else { return }
                self.onStatusMessage?("Overlay showing on \(overlayPlacementDiagnostics.targetScreenName) as \(overlayPlacementDiagnostics.modeDescription.lowercased()).")
            }
        )
    }

    func notchClose() {
        transitionOverlay(
            to: .closed,
            reason: nil,
            surface: .sessionList(),
            interactive: false,
            beforeTransition: { [weak self] in
                self?.notificationAutoCollapseTask?.cancel()
                self?.notificationAutoCollapseTask = nil
            },
            afterStateChange: { [weak self] in
                self?.autoCollapseSurfaceHasBeenEntered = false
                self?.isPointerInsideIslandSurface = false
                self?.appModel?.measuredNotificationContentHeight = 0
            }
        )
    }

    /// Coordinates overlay transitions.
    ///
    /// The window stays at a fixed (opened) size at all times.  All visual
    /// transitions — shape morphing, content fade, corner radius — are
    /// driven purely by SwiftUI `.animation()` modifiers reacting to
    /// `notchStatus` changes.  No AppKit animation, no window resize.
    private func transitionOverlay(
        to status: NotchStatus,
        reason: NotchOpenReason?,
        surface: IslandSurface,
        interactive: Bool,
        beforeTransition: (() -> Void)?,
        afterStateChange: (() -> Void)? = nil,
        onPlacementResolved: (() -> Void)? = nil
    ) {
        beforeTransition?()

        overlayTransitionGeneration &+= 1

        // Reset measured notification height when the surface changes so stale
        // measurements from a previous notification don't mis-size the new one.
        if surface != islandSurface {
            appModel?.measuredNotificationContentHeight = 0
        }

        islandSurface = surface
        notchOpenReason = reason
        notchStatus = status
        overlayPanelController.setInteractive(interactive)

        if status == .opened, let appModel {
            overlayPlacementDiagnostics = overlayPanelController.show(
                model: appModel,
                preferredScreenID: preferredOverlayScreenID
            )
        }

        afterStateChange?()
        onPlacementResolved?()
    }

    func notchPop() {
        guard notchStatus == .closed else { return }
        islandSurface = .sessionList()
        notchStatus = .popping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.notchStatus == .popping else { return }
            self?.notchStatus = .closed
        }
    }

    func performBootAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.notchOpen(reason: .boot, surface: .sessionList())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.notchOpenReason == .boot else { return }
                self?.notchClose()
            }
        }
    }

    func ensureOverlayPanel() {
        guard let appModel else { return }
        overlayPanelController.ensurePanel(model: appModel, preferredScreenID: preferredOverlayScreenID)
    }

    // Legacy compatibility
    func showOverlay() { notchOpen(reason: .click, surface: .sessionList()) }
    func hideOverlay() { notchClose() }

    /// Transition from notification mode (single session) to full session list.
    /// - Parameter clearExpansion: If true, clears the actionable session's expansion
    ///   (used for completion notifications which are informational only).
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        if clearExpansion {
            islandSurface = .sessionList()
        }
        // When not clearing, keep actionableSessionID so approval/question expansion persists
        notchOpenReason = .click
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        refreshOverlayPlacementIfVisible()
        // Widening a completed card into the list must not stop the dwell timer:
        // the list still fronts a session with nothing left to answer.
        updateNotificationAutoCollapse()
    }

    // MARK: - Display configuration

    func refreshOverlayDisplayConfiguration() {
        let reconciliation = OverlayDisplayPreferencePolicy.reconcile(
            availableOptions: overlayPanelController.availableDisplayOptions(),
            selectionID: overlayDisplaySelectionID,
            rememberedSelectionTitle: overlayDisplaySelectionTitle
        )
        overlayDisplaySelectionID = reconciliation.selectionID
        overlayDisplaySelectionTitle = reconciliation.selectionTitle
        overlayDisplayOptions = reconciliation.displayOptions
        persistOverlayDisplayPreference()

        refreshOverlayPlacement()
    }

    func refreshOverlayPlacement() {
        overlayPlacementDiagnostics = overlayPanelController.reposition(
            preferredScreenID: preferredOverlayScreenID
        )
    }

    func refreshOverlayPlacementIfVisible() {
        refreshOverlayPlacement()
    }

    // MARK: - Pointer tracking

    var shouldAutoCollapseOnMouseLeave: Bool {
        if ignoresPointerExitDuringHarness {
            return false
        }

        guard notchStatus == .opened else {
            return false
        }

        if notchOpenReason == .hover && !islandSurface.isNotificationCard {
            return true
        }

        return isCurrentCardTransient
    }

    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool {
        // The wait-for-entry guard exists so a card that appears under the
        // cursor is not dismissed before the user can read it. A click-opened
        // session list was deliberately requested by the user, so it may close
        // as soon as the pointer leaves instead of requiring a hover first.
        guard notchOpenReason == .notification else { return false }
        // If the session was removed from state (e.g. by process monitoring),
        // default to requiring prior surface entry — prevents the notification
        // from closing immediately on pointer exit before the user sees it.
        guard activeIslandCardSession != nil else { return true }
        return isCurrentCardTransient
    }

    var showsNotificationCard: Bool {
        islandSurface.isNotificationCard
    }

    func notePointerInsideIslandSurface() {
        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = true
        autoCollapseSurfaceHasBeenEntered = true

        if notchOpenReason == .notification {
            notificationAutoCollapseTask?.cancel()
            notificationAutoCollapseTask = nil
        }
    }

    func handlePointerExitedIslandSurface() {
        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = false

        guard shouldAutoCollapseOnMouseLeave else {
            return
        }

        guard !autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry
                || autoCollapseSurfaceHasBeenEntered else {
            return
        }

        notchClose()
    }

    // MARK: - Notification surfaces

    func presentNotificationSurface(_ surface: IslandSurface, cue: SoundCue?) {
        guard surface.isNotificationCard else {
            return
        }

        guard !shouldPreserveCurrentNotificationSurface(against: surface) else {
            return
        }

        appModel?.measuredNotificationContentHeight = 0
        // Sound rides with the card rather than with the raw event, so the
        // duplicate/stale/frontmost suppression that already guards the card
        // guards the sound too — an event that shows nothing must not ring.
        if let cue {
            EventSoundService.shared.play(cue, isMuted: isSoundMuted)
        }
        notchOpen(reason: .notification, surface: surface)
    }

    func shouldPreserveCurrentNotificationSurface(against candidate: IslandSurface) -> Bool {
        guard candidate.isNotificationCard,
              notchStatus == .opened,
              notchOpenReason == .notification,
              islandSurface.isNotificationCard,
              islandSurface != candidate else {
            return false
        }

        return isPointerInsideCurrentNotificationCard
    }

    func reconcileIslandSurfaceAfterStateChange() {
        guard islandSurface.isNotificationCard else {
            return
        }

        let session = activeIslandCardSession
        guard islandSurface.matchesCurrentState(of: session) else {
            if notchOpenReason == .notification {
                notchClose()
            } else {
                islandSurface = .sessionList()
                updateNotificationAutoCollapse()
            }
            return
        }

        updateNotificationAutoCollapse()
    }

    func dismissNotificationSurfaceIfPresent(for sessionID: String) {
        guard islandSurface.sessionID == sessionID,
              notchOpenReason == .notification else {
            return
        }

        notchClose()
    }

    func dismissOverlayForJump() {
        guard isOverlayVisible else {
            return
        }

        notchClose()
    }

    /// Schedules the timed collapse for a transient card.
    ///
    /// A transient card is one whose session has nothing left to answer, i.e.
    /// `IslandSurface.autoDismissesWhenPresentedAsNotification` is true. Waiting
    /// sessions are never transient, so an unanswered approval card stays put.
    ///
    /// The timer deliberately does **not** require `notchOpenReason == .notification`.
    /// When it did, a completed card opened by click (`.click`) or by pointer
    /// entry (`.hover`) had no way back to closed except an explicit dismissal, so
    /// reviewing a finished session left the island open indefinitely. The reason
    /// records *why* the overlay opened; transience is a property of the card, and
    /// conflating the two made the dwell timer conditional on how the user got there.
    private func updateNotificationAutoCollapse() {
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil

        guard notchStatus == .opened,
              isCurrentCardTransient else {
            return
        }

        if overlayPanelController.isPointInExpandedArea(currentPointerLocation) {
            notePointerInsideIslandSurface()
            return
        }

        notificationAutoCollapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.notificationSurfaceAutoCollapseDelay))
            } catch {
                // Task was cancelled (e.g. a new event reset the timer).
                // Do NOT proceed — the replacement task owns the new timer.
                return
            }

            guard let self,
                  self.notchStatus == .opened,
                  self.isCurrentCardTransient else {
                return
            }

            guard !self.shouldDeferTimedNotificationAutoCollapse else {
                return
            }

            self.notchClose()
        }
    }

    /// Whether the surface currently on screen has nothing left to answer, so the
    /// island may return to closed on its own once the dwell elapses.
    private var isCurrentCardTransient: Bool {
        islandSurface.autoDismissesWhenPresentedAsNotification(session: activeIslandCardSession)
    }

    var shouldDeferTimedNotificationAutoCollapse: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(currentPointerLocation)
    }

    private var shouldTrackPointerInsideIslandSurface: Bool {
        shouldAutoCollapseOnMouseLeave || (notchStatus == .opened && isCurrentCardTransient)
    }

    private var isPointerInsideCurrentNotificationCard: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(currentPointerLocation)
    }

    // MARK: - Debug snapshots (overlay portion)

    func applyOverlayState(from snapshot: IslandDebugSnapshot, presentOverlay: Bool, autoCollapseNotificationCards: Bool) {
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        autoCollapseSurfaceHasBeenEntered = false
        isPointerInsideIslandSurface = false

        islandSurface = snapshot.islandSurface
        notchStatus = snapshot.notchStatus
        notchOpenReason = snapshot.notchOpenReason

        if autoCollapseNotificationCards {
            updateNotificationAutoCollapse()
        }

        guard presentOverlay, let appModel else {
            return
        }

        // Immediate interactivity update.
        let interactive = snapshot.notchStatus == .opened
        overlayPanelController.setInteractive(interactive)

        // Defer AppKit panel animation to the next run-loop iteration.
        overlayTransitionGeneration &+= 1
        let capturedGeneration = overlayTransitionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlayTransitionGeneration == capturedGeneration else { return }
            switch snapshot.notchStatus {
            case .opened:
                self.overlayPlacementDiagnostics = self.overlayPanelController.show(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID
                )
            case .closed, .popping:
                self.overlayPanelController.ensurePanel(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID
                )
                self.refreshOverlayPlacement()
            }
            self.harnessRuntimeMonitor?.recordMilestone("overlayPresented", message: snapshot.title)
        }
    }

    // MARK: - Persistence

    private func persistOverlayDisplayPreference() {
        let defaults = UserDefaults.standard
        if overlayDisplaySelectionID == OverlayDisplayOption.automaticID {
            overlayDisplaySelectionTitle = nil
            defaults.removeObject(forKey: OverlayDisplayPreferencePolicy.preferenceDefaultsKey)
            defaults.removeObject(forKey: OverlayDisplayPreferencePolicy.preferenceTitleDefaultsKey)
        } else {
            if let selectedOption = overlayDisplayOptions.first(where: {
                $0.id == overlayDisplaySelectionID && $0.isAvailable
            }) {
                overlayDisplaySelectionTitle = selectedOption.title
            }
            defaults.set(
                overlayDisplaySelectionID,
                forKey: OverlayDisplayPreferencePolicy.preferenceDefaultsKey
            )
            if let overlayDisplaySelectionTitle {
                defaults.set(
                    overlayDisplaySelectionTitle,
                    forKey: OverlayDisplayPreferencePolicy.preferenceTitleDefaultsKey
                )
            }
        }
    }
}
