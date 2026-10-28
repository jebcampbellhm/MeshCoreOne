import SwiftUI

extension View {
  /// Enables row `.swipeActions` inside this `ScrollView` on iOS 27.
  /// Earlier OSes have no container API, so the row modifiers stay inert outside `List`.
  @ViewBuilder
  func swipeActionsContainerIfAvailable() -> some View {
    // Xcode 26's SDK cannot resolve the iOS 27 API, even inside #available.
    #if compiler(>=6.4)
    if #available(iOS 27, *) {
      swipeActionsContainer()
    } else {
      self
    }
    #else
    self
    #endif
  }
}
