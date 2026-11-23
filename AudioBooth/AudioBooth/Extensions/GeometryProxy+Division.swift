import SwiftUI

extension GeometryProxy {
  var leadingPanelWidth: CGFloat? {
    #if AUDIOBOOTH_HINGE_SDK && !targetEnvironment(macCatalyst)
    guard #available(iOS 27.1, *) else { return nil }
    let division = reservedRegions(kind: .division).first { $0.isActive && $0.frame.minX > 0 }
    return division?.frame.midX
    #else
    return nil
    #endif
  }

  var topPanelHeight: CGFloat? {
    #if AUDIOBOOTH_HINGE_SDK && !targetEnvironment(macCatalyst)
    guard #available(iOS 27.1, *) else { return nil }
    let division = reservedRegions(kind: .division).first { $0.isActive && $0.frame.minY > 0 }
    return division?.frame.minY
    #else
    return nil
    #endif
  }
}
