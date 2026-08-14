import AppKit
import SwiftUI

/// The mouse events SwiftUI has no gesture for — scroll wheel, trackpad
/// magnification, right-click — reported from an NSView laid over a region.
///
/// The view claims ONLY the event types its callbacks handle: `hitTest`
/// inspects the current event and returns nil for everything else, so left
/// clicks and drags fall through to the SwiftUI gestures beneath it. That is
/// what lets it sit over the canvas without eating the pan gesture, and over
/// the curve editor without eating point drags.
struct MouseEventView: NSViewRepresentable {
    /// Precise scroll: location in this view's top-left coordinates + deltaY.
    var onScroll: ((CGPoint, CGFloat) -> Void)?
    /// Trackpad pinch: location + this event's magnification delta.
    var onMagnify: ((CGPoint, CGFloat) -> Void)?
    var onRightClick: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onRightClick = onRightClick
    }

    final class EventView: NSView {
        var onScroll: ((CGPoint, CGFloat) -> Void)?
        var onMagnify: ((CGPoint, CGFloat) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?

        // Top-left origin, matching the SwiftUI layout coordinates every
        // caller thinks in.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel: return onScroll != nil ? super.hitTest(point) : nil
            case .magnify: return onMagnify != nil ? super.hitTest(point) : nil
            case .rightMouseDown, .rightMouseUp:
                return onRightClick != nil ? super.hitTest(point) : nil
            default: return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let onScroll else { return super.scrollWheel(with: event) }
            onScroll(convert(event.locationInWindow, from: nil), event.scrollingDeltaY)
        }

        override func magnify(with event: NSEvent) {
            guard let onMagnify else { return }
            onMagnify(convert(event.locationInWindow, from: nil), event.magnification)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let onRightClick else { return }
            onRightClick(convert(event.locationInWindow, from: nil))
        }
    }
}
