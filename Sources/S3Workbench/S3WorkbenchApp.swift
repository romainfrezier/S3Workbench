import SwiftUI

@main
struct S3WorkbenchApp: App {
  @State private var model = WorkbenchViewModel(service: AppServices.makeWorkbenchService())

  var body: some Scene {
    WindowGroup {
      WorkbenchRootView(model: model)
        .frame(minWidth: 900, minHeight: 560)
    }
    .defaultSize(width: 1280, height: 800)
    .commands {
      SidebarCommands()
      WorkbenchCommands()
    }
  }
}

private enum AppServices {
  static func makeWorkbenchService() -> any WorkbenchServing {
    do {
      return try CoreWorkbenchService.live()
    } catch {
      return PlaceholderWorkbenchService()
    }
  }
}
