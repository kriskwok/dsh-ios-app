import SwiftUI

enum DrawerDragAxis {
    case horizontal
    case vertical
}

enum DrawerMotion {
    static func clamped(_ progress: CGFloat) -> CGFloat {
        min(1, max(0, progress))
    }

    static func targetProgress(current: CGFloat, predicted: CGFloat) -> CGFloat {
        let projected = clamped(predicted)
        if abs(projected - current) < 0.08 {
            return current >= 0.5 ? 1 : 0
        }
        return projected >= 0.5 ? 1 : 0
    }
}
