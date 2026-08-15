import SwiftUI

enum AppColors {
    static let background = Color("AppBackground")
    static let card = Color("AppCard")
    static let ink = Color("AppInk")
    static let accent = Color("AppAccent")
    static let accentSoft = Color("AppAccentSoft")
    static let yellow = Color("AppYellow")
    static let purple = Color("AppPurple")
    static let greenSoft = Color("AppGreenSoft")
    static let border = Color("AppBorder")
}

enum AppSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 36
}

enum AppRadius {
    static let field: CGFloat = 10
    static let card: CGFloat = 18
    static let sheet: CGFloat = 26
    static let pill: CGFloat = 999
}

enum AppTypography {
    static let display = Font.largeTitle.weight(.heavy)
    static let title = Font.title2.weight(.bold)
    static let section = Font.headline.weight(.bold)
    static let body = Font.body
    static let caption = Font.footnote
    static let small = Font.caption
}
