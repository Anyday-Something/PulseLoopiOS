import Charts
import SwiftUI

/// Pinch-to-zoom + horizontal scroll for a time-axis chart. Double-tap resets to the full window.
struct ChartZoom {
    let full: TimeInterval
    let minimum: TimeInterval
    var visible: TimeInterval
    var gestureBase: TimeInterval
    var scrollTo: Date

    init(full: TimeInterval, minimum: TimeInterval = 30 * 60, start: Date) {
        self.full = full
        self.minimum = minimum
        self.visible = full
        self.gestureBase = full
        self.scrollTo = start
    }

    var isZoomed: Bool { visible < full - 1 }

    mutating func reset(to start: Date) {
        visible = full
        gestureBase = full
        scrollTo = start
    }
}

private struct ChartZoomModifier: ViewModifier {
    @Binding var zoom: ChartZoom
    let start: Date

    func body(content: Content) -> some View {
        content
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: zoom.visible)
            .chartScrollPosition(x: $zoom.scrollTo)
            // Gestures go through the chart's own gesture hook so they coexist with its scroll drag; a
            // gesture attached around the chart steals the drag and scrolling dies.
            .chartGesture { _ in
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let next = zoom.gestureBase / max(0.1, value.magnification)
                            zoom.visible = min(zoom.full, max(zoom.minimum, next))
                        }
                        .onEnded { _ in zoom.gestureBase = zoom.visible },
                    TapGesture(count: 2)
                        .onEnded { withAnimation { zoom.reset(to: start) } }
                )
            }
    }
}

extension View {
    /// Apply after `chartXScale(domain:)`. Pinch zooms between `minimum` and the full domain, drag scrolls,
    /// double-tap resets.
    func chartZoomable(_ zoom: Binding<ChartZoom>, start: Date) -> some View {
        modifier(ChartZoomModifier(zoom: zoom, start: start))
    }
}
