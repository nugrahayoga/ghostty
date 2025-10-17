import SwiftUI
import Combine

/// Wraps a Ghostty surface view in an NSScrollView to provide native macOS scrollbar support.
///
/// ## Coordinate System
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while terminals conceptually
/// use +Y-down (row 0 at top). This class handles the inversion when converting between row
/// offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: The outermost NSScrollView that manages scrollbar rendering and behavior
/// - `documentView`: A blank NSView whose height represents total scrollback (in pixels)
/// - `surfaceView`: The actual Ghostty renderer, positioned to fill the visible rect
class SurfaceScrollView: NSView {
    private let scrollView: NSScrollView
    private let documentView: NSView
    private let surfaceView: Ghostty.SurfaceView
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isLiveScrolling = false
    
    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: Int?
    
    init(contentSize: CGSize, surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        
        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView
        
        // The document view contains our actual surface as a child.
        // We synchronize the scrolling of the document with this surface
        // so that our primary Ghostty renderer only needs to render the viewport.
        documentView.addSubview(surfaceView)
        
        super.init(frame: .zero)
        
        // Our scroll view is our only view
        addSubview(scrollView)
        
        // Apply initial scrollbar settings
        synchronizeAppearance()
        
        // We listen for scroll events through bounds notifications on our NSClipView.
        // This is based on: https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollChange(notification)
        })
        
        // Listen for scrollbar updates from Ghostty
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })
        
        // Listen for live scroll events
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })
        
        // Listen for derived config changes to update scrollbar settings live
        surfaceView.$derivedConfig
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.synchronizeAppearance()
                }
            }
            .store(in: &cancellables)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        
        // Force layout to be called to fix up our various subviews.
        needsLayout = true
    }
    
    override func layout() {
        super.layout()
        
        // Fill entire bounds with scroll view
        scrollView.frame = bounds
        
        // Use contentSize to account for visible scrollers
        //
        // Only update sizes if we have a valid (non-zero) content size. The content size
        // can be zero when this is added early to a view, or to an invisible hierarchy.
        // Practically, this happened in the quick terminal.
        let contentSize = scrollView.contentSize
        if contentSize.width > 0 && contentSize.height > 0 {
            // Keep document width synchronized with content width
            documentView.setFrameSize(CGSize(
                width: contentSize.width,
                height: documentView.frame.height
            ))
            
            // Inform the actual pty of our size change
            surfaceView.sizeDidChange(contentSize)
        }
        
        // When our scrollview changes make sure our surface view is synchronized
        synchronizeSurfaceView()
    }
    
    // MARK: Scrolling
    
    private func synchronizeAppearance() {
        let scrollbarConfig = surfaceView.derivedConfig.scrollbar
        scrollView.hasVerticalScroller = scrollbarConfig != .never
    }
    
    /// Positions the surface view to fill the currently visible rectangle.
    ///
    /// This is called whenever the scroll position changes. The surface view (which does the
    /// actual terminal rendering) always fills exactly the visible portion of the document view,
    /// so the renderer only needs to render what's currently on screen.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame = visibleRect
    }
    
    // MARK: Notifications
    
    /// Handles bounds changes in the scroll view's clip view, keeping the surface view synchronized.
    private func handleScrollChange(_ notification: Notification) {
        synchronizeSurfaceView()
    }
    
    /// Handles live scroll events (user actively dragging the scrollbar).
    ///
    /// Converts the current scroll position to a row number and sends a `scroll_to_row` action
    /// to the terminal core. Only sends actions when the row changes to avoid IPC spam.
    private func handleLiveScroll() {
        // If our cell height is currently zero then we avoid a div by zero below
        // and just don't scroll (there's no where to scroll anyways). This can
        // happen with a tiny terminal.
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }
        
        // AppKit views are +Y going up, so we calculate from the bottom
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)
        
        // Only send action if the row changed to avoid action spam
        guard row != lastSentRow else { return }
        lastSentRow = row
        
        // Use the keybinding action to scroll.
        _ = surfaceView.surfaceModel?.perform(action: "scroll_to_row:\(row)")
    }
    
    /// Handles scrollbar state updates from the terminal core.
    ///
    /// Updates the document view size to reflect total scrollback and adjusts scroll position
    /// to match the terminal's viewport. During live scrolling, updates document size but skips
    /// programmatic position changes to avoid fighting the user's drag.
    ///
    /// ## Scrollbar State
    /// The scrollbar struct contains:
    /// - `total`: Total rows in scrollback + active area
    /// - `offset`: First visible row (0 = top of history)
    /// - `len`: Number of visible rows (viewport height)
    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[SwiftUI.Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else {
            return
        }
        
        // Convert row units to pixels using cell height, ignore zero height.
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }
        
        // Our width should be the content width to account for visible scrollers.
        // We don't do horizontal scrolling in terminals.
        let totalHeight = CGFloat(scrollbar.total) * cellHeight
        let newSize = CGSize(width: scrollView.contentSize.width, height: totalHeight)
        documentView.setFrameSize(newSize)
        
        // Only update our actual scroll position if we're not actively scrolling.
        if !isLiveScrolling {
            // Invert coordinate system: terminal offset is from top, AppKit position from bottom
            let offsetY = CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            
            // Track the current row position to avoid redundant movements when we
            // move the scrollbar.
            lastSentRow = Int(scrollbar.offset)
        }
        
        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
