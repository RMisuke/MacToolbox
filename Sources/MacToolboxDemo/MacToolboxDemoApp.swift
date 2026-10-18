import AppKit
import SwiftUI

@main
struct MacToolboxDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacToolbox Demo", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1020, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("前往") {
                Button("主页") { model.goHome() }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("任务") { model.destination = .tasks }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("工具") { model.destination = .tools }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("设置") { model.destination = .settings }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button("高级设置…") {
                    if let tool = model.primaryTool {
                        model.openSettings(tool)
                    }
                }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(model.primaryTool == nil)
            }

            CommandMenu("任务") {
                Button("快速运行…") {
                    if let tool = model.primaryTool {
                        model.openQuickRun(tool)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.primaryTool == nil || model.job.state.isActive || model.coordinator.isActive)

                if model.primaryTool?.manifest.batch != nil {
                    Button("批量运行…") {
                        if let tool = model.primaryTool {
                            model.openBatchRun(tool)
                        }
                    }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(model.job.state.isActive || model.coordinator.isActive)
                }

                Button("取消当前任务") { model.job.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.job.state.isActive)
                Divider()
                Button("打开任务控制台") { model.showConsole = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.coordinator.isActive ? "shippingbox.fill" : "shippingbox")
                if model.coordinator.isActive {
                    Text("\(Int(model.coordinator.progress * 100))%")
                        .font(.caption2)
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 图标显式加载 bundle 里的 icns，避免 LaunchServices 缓存旧图标时
        // 运行中的 App 仍显示通用图标；Finder 侧仍由 Info.plist 的 IconFile/Name 负责。
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        } else {
            NSLog("MacToolbox: AppIcon.icns not found in bundle")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 保留菜单栏状态项；退出走菜单栏/⌘Q。
        false
    }
}
