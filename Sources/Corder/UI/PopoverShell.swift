import SwiftUI

/// Shared geometry tokens for every menu-bar popover surface so the
/// three places that draw a popover (the main idle/recording/stopping
/// PopoverContentView, the locked-wizard variant, and the meeting-
/// invite InviteOfferView in MenuBarController) stay byte-identical
/// when one number moves.
///
/// **Rule of thumb (and the one Kostya keeps reminding us of):**
/// if you're tempted to write a literal `20`, `320`, `18`, `14`,
/// or `10` inside a popover layout, pull it from `PopoverShell`
/// instead. Otherwise the next theme tweak only lands in one of
/// the surfaces and the others drift.
enum PopoverShell {
    /// Width of the popover bubble. Set on the outer container.
    static let width: CGFloat = 320

    /// Outer padding around the bubble's content.
    static let outerPadding: CGFloat = 20

    /// Gap between the primary block (status + action button)
    /// and the hairline divider, and between the hairline and
    /// the secondary block (Open library / Quit). 10 pt, tighter
    /// than the previous 18 pt so the divider reads as a section
    /// break inside the same card, not as a hard split between two.
    static let outerSpacing: CGFloat = 10

    /// Gap between rows inside a single section (e.g. status pill +
    /// primary button). 14 pt is the long-standing rhythm here.
    static let sectionSpacing: CGFloat = 14
}
