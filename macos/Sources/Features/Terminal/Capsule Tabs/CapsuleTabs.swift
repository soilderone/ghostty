import AppKit
import SwiftUI

/// Draws a window's tabs as capsules in its titlebar (`macos-capsule-tabs`, feature 8).
///
/// The tabs stay native: each tab is still a window in an `NSWindowTabGroup`, so the tab
/// shortcuts, the Window menu, Show All Tabs and window restoration are untouched and only the
/// drawing changes. The system tab bar is hidden, and every window of a group draws the whole
/// group in a toolbar item, which also centers the window buttons on the same row. Only the
/// selected window of a group is ever on screen, so the bar that shows is always the bar of
/// the selected tab's own window.
final class CapsuleTabs: NSObject, ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let color: TerminalTabColor
        let badge: TerminalBadge?
        let isZoomed: Bool

        init(window: NSWindow) {
            let terminalWindow = window as? TerminalWindow
            self.id = ObjectIdentifier(window)
            self.title = window.title
            self.color = terminalWindow?.tabColor ?? .none
            self.badge = terminalWindow?.tabBadge
            self.isZoomed = terminalWindow?.surfaceIsZoomed ?? false
        }
    }

    /// Where the tabs go in a bar of some width.
    struct Layout {
        let tabWidth: CGFloat
        let count: Int

        var tracksWidth: CGFloat { tabWidth * CGFloat(count) }

        func index(atX x: CGFloat) -> Int? {
            guard x >= 0, x < tracksWidth, tabWidth > 0 else { return nil }
            return Int(x / tabWidth)
        }
    }

    /// Posted when something a tab shows changes: its title, color, badge or zoom.
    static let tabsDidChange = Notification.Name("com.mitchellh.ghostty.capsuleTabsDidChange")

    static let toolbarItem = NSToolbarItem.Identifier("com.mitchellh.ghostty.capsuleTabs")

    /// The height of the track the tabs sit in. The tabs are 4pt shorter.
    static let barHeight: CGFloat = 32
    static let defaultTabWidth: CGFloat = 130

    /// Tabs shrink to share the bar, down to this width where only the dot and the close
    /// button still fit.
    static let squeezedTabWidth: CGFloat = 48
    static let newTabButtonWidth: CGFloat = 32
    static let spacing: CGFloat = 6

    /// Room always left after the new tab button to drag the window by.
    static let dragAreaWidth: CGFloat = 40

    /// How the selection pill slides over from the previous tab: a spring with about 5%
    /// overshoot.
    static let slide = Animation.spring(response: 0.44, dampingFraction: 0.68)

    @Published private(set) var tabs: [Tab] = []

    /// The index of this window's own tab, which is the selected tab whenever the bar shows.
    @Published private(set) var selectedIndex = 0

    /// Where the selection pill is, in tabs from the left. Fractional while it slides.
    @Published private(set) var pillPosition: CGFloat = 0

    private weak var window: TerminalWindow?
    private var tabWindows: [Weak<NSWindow>] = []
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var tabBarObservation: NSKeyValueObservation?

    /// The tab selected last in a group, so the next selected window of the group can slide
    /// its pill over from there.
    private static var lastSelection: (group: ObjectIdentifier, index: Int)?

    init(window: TerminalWindow) {
        self.window = window
        super.init()

        // Tabs of other windows in the group change too, and a window joining or leaving the
        // group becomes main or closes.
        let names = [Self.tabsDidChange, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        tabGroupObservations.forEach { $0.invalidate() }
        tabBarObservation?.invalidate()
    }

    static func layout(count: Int, width: CGFloat) -> Layout {
        let count = max(count, 1)
        let available = width - newTabButtonWidth - spacing - dragAreaWidth
        let share = (available / CGFloat(count)).rounded(.down)
        return Layout(tabWidth: min(defaultTabWidth, max(squeezedTabWidth, share)), count: count)
    }

    // MARK: Installing

    /// Puts the bar in the window's titlebar.
    func install() {
        guard let window else { return }

        // The tabs show the titles.
        window.titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: "CapsuleTabs")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        refresh()
    }

    /// Hides the system tab bar. AppKit adds it as a titlebar accessory whenever the window
    /// joins a tab group and can show it again later, so it is hidden again whenever it shows.
    func hideNativeTabBar(_ accessory: NSTitlebarAccessoryViewController) {
        accessory.isHidden = true
        tabBarObservation = accessory.observe(\.isHidden, options: [.new]) { accessory, _ in
            guard !accessory.isHidden else { return }
            DispatchQueue.main.async { accessory.isHidden = true }
        }
    }

    private func hideNativeTabBars() {
        guard let window else { return }
        for accessory in window.titlebarAccessoryViewControllers where window.isTabBar(accessory) {
            accessory.isHidden = true
        }
    }

    // MARK: Refreshing

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard let window else { return }
        let windows = window.tabbedWindows ?? [window]
        tabWindows = windows.map { Weak($0) }

        let tabs = windows.map(Tab.init(window:))
        if tabs != self.tabs {
            self.tabs = tabs
        }

        let index = windows.firstIndex { $0 === window } ?? 0
        if index != selectedIndex {
            selectedIndex = index
            withAnimation(Self.slide) { pillPosition = CGFloat(index) }
        }

        // Reading `tabGroup` sets up AppKit's tab machinery, which a lone window doesn't need.
        if window.tabbedWindows != nil, let tabGroup = window.tabGroup {
            if window.isMainWindow {
                Self.lastSelection = (ObjectIdentifier(tabGroup), index)
            }
            observeTabGroup(tabGroup)
        }
    }

    /// Called when the window becomes the selected tab, and so the one on screen.
    func windowDidBecomeSelected() {
        let previous = Self.lastSelection
        refresh()
        hideNativeTabBars()

        guard let window, window.tabbedWindows != nil, let tabGroup = window.tabGroup,
              let previous, previous.group == ObjectIdentifier(tabGroup),
              previous.index != selectedIndex, !tabs.isEmpty else {
            pillPosition = CGFloat(selectedIndex)
            return
        }

        // Start where the previous window's pill was, then slide over once that has drawn.
        pillPosition = CGFloat(min(previous.index, tabs.count - 1))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.slide) { self.pillPosition = CGFloat(self.selectedIndex) }
        }
    }

    private func observeTabGroup(_ tabGroup: NSWindowTabGroup) {
        guard tabGroup !== observedTabGroup else { return }
        observedTabGroup = tabGroup

        tabGroupObservations.forEach { $0.invalidate() }
        tabGroupObservations = [
            tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
                // The goto_tab shortcuts are otherwise kept in tab order by watching the
                // native tab bar, which is hidden.
                DispatchQueue.main.async {
                    (self?.window?.windowController as? TerminalController)?.relabelTabs()
                }
                self?.scheduleRefresh()
            },
            tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.hideNativeTabBars() }
            },
        ]
    }

    // MARK: Actions

    private func tabWindow(at index: Int) -> NSWindow? {
        guard tabWindows.indices.contains(index) else { return nil }
        return tabWindows[index].value
    }

    private func controller(at index: Int) -> TerminalController? {
        tabWindow(at: index)?.windowController as? TerminalController
    }

    func select(_ index: Int) {
        guard let target = tabWindow(at: index), target !== window else { return }
        target.makeKeyAndOrderFront(nil)
    }

    func close(_ index: Int) {
        guard let controller = controller(at: index) else { return }
        showIfConfirming(controller)
        controller.closeTab(nil)
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func rename(_ index: Int) {
        controller(at: index)?.promptTabTitle()
    }

    func resetZoom(_ index: Int) {
        guard let controller = controller(at: index) else { return }
        controller.splitZoom(self)
    }

    /// Closing a tab that runs a process asks first, in a sheet on the tab's own window, so
    /// that tab is brought up to show it.
    private func showIfConfirming(_ controller: TerminalController) {
        guard let target = controller.window, target !== window else { return }
        guard controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) else { return }
        target.makeKeyAndOrderFront(nil)
    }

    /// Moves a tab in the group, the same way the `move_tab` action does.
    func move(from: Int, to: Int) {
        guard from != to, let window, let tabGroup = window.tabGroup else { return }
        let windows = tabGroup.windows
        guard windows.indices.contains(from), windows.indices.contains(to) else { return }
        let moving = windows[from]
        let target = windows[to]
        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(moving)
        target.addTabbedWindowSafely(moving, ordered: to < from ? .below : .above)
        selected?.makeKey()
        NSAnimationContext.endGrouping()

        // Keep the goto_tab shortcuts in tab order.
        (window.windowController as? TerminalController)?.relabelTabs()
        refresh()
    }

    // MARK: Menu

    /// The context menu of a tab, with the same commands as the native tab menu.
    func menu(for index: Int) -> NSMenu? {
        guard let target = tabWindow(at: index),
              let controller = controller(at: index) else { return nil }
        let count = tabs.count

        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            item.setImageIfDesired(systemSymbolName: symbol)
            menu.addItem(item)
        }

        add("New Tab", symbol: "plus") { [weak self] in self?.newTab() }
        add("Rename Tab…", symbol: "pencil.line") { [weak controller] in controller?.promptTabTitle() }
        menu.addItem(.separator())

        add("Move Tab to New Window", symbol: "macwindow", enabled: count > 1) { [weak target] in
            target?.moveTabToNewWindow(nil)
        }
        menu.addItem(.separator())

        add("Close Tab", symbol: "xmark") { [weak self] in self?.close(index) }
        add("Close Other Tabs", symbol: "xmark", enabled: count > 1) { [weak self, weak controller] in
            guard let controller else { return }
            self?.showIfConfirming(controller)
            controller.closeOtherTabs(nil)
        }
        add("Close Tabs to the Right", symbol: "xmark", enabled: index < count - 1) { [weak self, weak controller] in
            guard let controller else { return }
            self?.showIfConfirming(controller)
            controller.closeTabsOnTheRight(nil)
        }
        menu.addItem(.separator())

        // The same palette as the native tab menu (feature 1).
        let terminalWindow = target as? TerminalWindow
        let palette = NSHostingView(rootView: TabColorMenuView(
            selectedColor: terminalWindow?.tabColor ?? .none
        ) { [weak terminalWindow] color in
            terminalWindow?.tabColor = color
        })
        palette.frame.size = palette.intrinsicContentSize
        let paletteItem = NSMenuItem()
        paletteItem.view = palette
        menu.addItem(paletteItem)

        return menu
    }
}

// MARK: NSToolbarDelegate

extension CapsuleTabs: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarItem]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.toolbarItem else { return nil }

        let view = CapsuleTabsHostingView(rootView: CapsuleTabBar(tabs: self))
        view.tabs = self
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false

        // A minimum and a maximum width make the item flexible, so the toolbar stretches it
        // over all the room it has.
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.barHeight),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.squeezedTabWidth + Self.newTabButtonWidth + Self.spacing),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
        ])

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = view
        item.label = "Tabs"
        item.visibilityPriority = .user

        // The documented way to keep the macOS 26 glass off an item.
        item.isBordered = false
        return item
    }
}

/// The bar's hosting view. Clicks on it don't drag the window (the bar's empty space does
/// that itself, so dragging a tab can reorder it), and right-clicking a tab shows the tab's
/// menu, which is an AppKit menu so it can hold the tab color palette.
final class CapsuleTabsHostingView: NonDraggableHostingView<CapsuleTabBar> {
    weak var tabs: CapsuleTabs?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tabs else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let layout = CapsuleTabs.layout(count: tabs.tabs.count, width: bounds.width)
        guard let index = layout.index(atX: point.x) else { return super.menu(for: event) }
        return tabs.menu(for: index)
    }
}
