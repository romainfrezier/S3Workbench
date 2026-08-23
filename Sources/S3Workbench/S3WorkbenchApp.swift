import SwiftUI

@main
struct S3WorkbenchApp: App {
  @State private var model = WorkbenchViewModel(service: AppServices.makeWorkbenchService())
  @State private var preferences = AppPreferences()
  @State private var settingsNavigation = SettingsNavigationModel()

  var body: some Scene {
    WindowGroup {
      WorkbenchRootView(
        model: model,
        preferences: preferences,
        settingsNavigation: settingsNavigation
      )
        .frame(minWidth: 900, minHeight: 560)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
    .defaultSize(width: 1280, height: 800)
    .commands {
      SidebarCommands()
      WorkbenchCommands()
    }

    Settings {
      WorkbenchSettingsView(
        preferences: preferences,
        navigation: settingsNavigation,
        model: model
      )
      .preferredColorScheme(preferences.appearance.colorScheme)
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
