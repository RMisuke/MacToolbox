import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .sheet(item: $model.quickRunTool) { tool in
            QuickRunSheet(tool: tool)
                .environmentObject(model)
        }
        .sheet(item: $model.settingsTool) { tool in
            ToolSettingsSheet(tool: tool)
                .environmentObject(model)
        }
        .onChange(of: model.destination) { _, newValue in
            if newValue == .home {
                model.homePath = NavigationPath()
            }
        }
        .sheet(item: $model.batchTool) { tool in
            BatchRunSheet(tool: tool)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showConsole) {
            JobConsoleView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showSetup) {
            if let tool = model.primaryTool {
                SetupSheet(
                    setup: model.setup,
                    tool: tool,
                    values: model.values(for: tool),
                    initialChecks: model.doctor.checks,
                    onClose: { model.recheckEnvironment(for: tool) }
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.destination {
        case .home:
            HomeView()
        case .tasks:
            TasksView()
        case .tools:
            ToolsView()
        case .settings:
            SettingsView()
        }
    }
}
