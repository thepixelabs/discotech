import CoreGraphics

/// Tunable constants for the Layers chart (a left-to-right partition/icicle view — see
/// `ColumnsLayout`). Kept in one place so the look can be adjusted without hunting through
/// layout/draw code — mirrors `SunburstConstants`/`FloorStyle`.
enum ColumnsConstants {
    // MARK: Column geometry

    /// Width of the focus spine on the left — full height, the current folder's name
    /// written vertically. Clicking it (or any empty canvas area) zooms out, same as the
    /// ring's center orb.
    static let spineWidth: CGFloat = 34
    /// Gap between the spine and column 1, and between every later pair of columns.
    static let columnGutter: CGFloat = 6
    /// Column 1 gets this width whenever there's room — it carries the most labels people
    /// read first, so it gets the most breathing room.
    static let idealFirstColumnWidth: CGFloat = 260
    /// Every later column wants at least this much width for a name + size line to fit
    /// without truncating too aggressively.
    static let minColumnWidth: CGFloat = 200
    /// However many columns fit at `minColumnWidth`, never draw more than this many —
    /// a 5th level rarely adds a legible macro read, and it keeps the eyebrow header
    /// vocabulary ("ONE LEVEL DOWN" … ) finite.
    static let maxColumns = 4

    // MARK: Column header (eyebrow row)

    static let headerHeight: CGFloat = 24
    static let eyebrowFontSize: CGFloat = 10.5
    /// Letter-spacing applied to the eyebrow row, in points (the halfcat tracked-caps habit).
    static let eyebrowTracking: CGFloat = 0.9

    // MARK: Bands

    /// Vertical breathing room carved out of each band's fill rect. Bands have no minimum
    /// height (sizes are drawn exactly proportional), so this never grows past what a band
    /// can actually spare.
    static let bandInset: CGFloat = 1
    /// A child whose exact proportional height would fall under this merges into its
    /// parent's "N smaller items" band instead of drawing its own sliver — the same
    /// pixel-legibility floor the Ball uses for angle, applied to length here. Children are
    /// sorted by size descending, so this is always a clean suffix cut, never a scatter.
    static let mergeThreshold: CGFloat = 1.5
    /// Below this height a band shows no text at all (just its color).
    static let nameOnlyHeight: CGFloat = 18
    /// Below this height a band shows name only, no size/percent line.
    static let fullDetailHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 6

    // MARK: Pass-through ("Ableton Live 12 Suite.app › Contents")

    /// A child holding at least this share of its parent's bytes is "the same thing one
    /// level down" — its own name is folded into the parent band's label instead of
    /// spending a whole column on a single, near-total band. Mirrors `FloorStyle.mostOfParent`.
    static let mostOfParentShare = 0.85
    /// How many single-dominant-child hops a pass-through chain may absorb before it stops
    /// and actually spends a column — mirrors `FloorLayout.split`'s hop cap.
    static let maxPassThroughHops = 4

    // MARK: Hover / emphasis (mirrors the Ball's and Floor's values so switching views
    // feels like the same instrument, not three different ones)

    static let hoverDimAlpha: CGFloat = 0.28
    static let hoverDescendantAlpha: CGFloat = 0.92
    static let hoverBlendDuration: Double = 0.12
    /// Blur radius of the "everything else" merge texture's diagonal hatch spacing.
    static let hatchSpacing: CGFloat = 6

    // MARK: Zoom transition

    /// Cross-fade length when a click re-roots the view at a new focus — "smooth, short",
    /// same order of magnitude as `FloorStyle.focusFadeDuration`. Skipped entirely (instant
    /// swap) under Reduce Motion.
    static let focusFadeDuration: CFTimeInterval = 0.22
}
