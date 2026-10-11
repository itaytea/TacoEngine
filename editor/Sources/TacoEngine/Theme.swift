import SwiftUI

// Taco Engine's design tokens. Every spacing, text style, corner radius and color in the app comes from
// here, so panels built at different times look like one product. Don't use literal values in views:
// add a token if none fits.

/// Spacing on a 4 pt scale, for padding, stack spacing and grid gaps
enum Space {
    static let xs: CGFloat = 4     // icon to label, lines inside a row
    static let sm: CGFloat = 8     // between controls, inside rows and cells
    static let md: CGFloat = 12    // panel edge insets, between groups
    static let lg: CGFloat = 16    // between sections
    static let xl: CGFloat = 24    // page margins (launcher, empty states)
    static let xxl: CGFloat = 32
}

/// Corner radii: one for anything you click or that holds content, a smaller one for small swatches
enum Radius {
    static let control: CGFloat = 6   // buttons, tabs, rows, cells, thumbnails, previews
    static let swatch: CGFloat = 4    // color and tile swatches under 24 pt
}

/// The type ramp. SF throughout; SF Mono only for numbers that change and for code.
enum Typo {
    static let display = Font.largeTitle.weight(.bold)          // 26: launcher title
    static let title = Font.title3.weight(.semibold)            // 15: editor titles
    static let heading = Font.headline                          // 13 semibold: group headings
    static let body = Font.body                                 // 13: running text
    static let bodyStrong = Font.body.weight(.medium)           // 13: names in lists
    static let label = Font.callout                             // 12: controls, rows, tabs
    static let labelStrong = Font.callout.weight(.semibold)
    static let caption = Font.caption                           // 10: secondary information
    static let captionStrong = Font.caption.weight(.semibold)   // 10: badges
    static let section = Font.system(size: 11, weight: .semibold)   // panel headers (uppercase)
    static let mono = Font.caption.monospaced()                 // file:line, build log
    static let code = Font.callout.monospaced()                 // C names
    static let digits = Font.callout.monospacedDigit()          // live numbers
    static let captionDigits = Font.caption.monospacedDigit()
}

/// Semantic colors. Everything else uses the system's primary/secondary/tertiary label colors.
enum Tone {
    static let accent = Color.accentColor
    static let prefab = Color.blue            // prefab instances and overridden values (the Unity convention)
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let well = Color.primary.opacity(0.06)            // behind thumbnails, previews and grouped sections
    static let border = Color.primary.opacity(0.12)          // hairline outlines
    static let hover = Color.primary.opacity(0.06)
    static let selected = Color.accentColor.opacity(0.2)
    static let dropTarget = Color.accentColor.opacity(0.3)
    static let canvas = Color(nsColor: .underPageBackgroundColor)   // behind the scene and editors
}

/// Motion: short and only in response to the user
enum Motion {
    static let quick = Animation.easeOut(duration: 0.15)      // hover, selection
    static let standard = Animation.easeInOut(duration: 0.25) // panels and status changes
}
