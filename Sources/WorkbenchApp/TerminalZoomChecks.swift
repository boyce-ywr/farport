import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum TerminalZoomChecks {
    static func run(workspace: Workspace) async throws {
        let store = workspace.store
        let original = store.fontSize
        let defaults = UserDefaults.standard.object(forKey: "fontSize")
        defer {
            store.fontSize = original
            if let defaults { UserDefaults.standard.set(defaults, forKey: "fontSize") }
            else { UserDefaults.standard.removeObject(forKey: "fontSize") }
        }
        workspace.connectLocal()
        guard let first = workspace.selectedTerminal else { throw WorkbenchError.message("未创建缩放测试终端") }
        workspace.connectLocal(split: true)
        guard let second = workspace.selectedTerminal else { throw WorkbenchError.message("未创建第二窗格") }
        try await wait { first.connected && second.connected }
        store.fontSize = 14
        try await wait { abs(first.terminal.font.pointSize - 14) < 0.1 && abs(second.terminal.font.pointSize - 14) < 0.1 }
        let layout = workspace.layout
        let inputBefore = first.inputGeneration
        first.terminal.applyMagnification(0, phase: .began)
        first.terminal.applyMagnification(0.25, phase: .changed)
        first.terminal.applyMagnification(0.25, phase: .changed)
        first.terminal.applyMagnification(0, phase: .ended)
        try await wait { abs(first.terminal.font.pointSize - 21) < 0.1 && abs(second.terminal.font.pointSize - 21) < 0.1 }
        guard UserDefaults.standard.double(forKey: "fontSize") == 21, first.inputGeneration == inputBefore, workspace.layout == layout else { throw WorkbenchError.message("缩放未保存或影响终端输入/布局") }
        second.terminal.applyMagnification(0, phase: .began)
        second.terminal.applyMagnification(-0.25, phase: .changed)
        try await wait { abs(store.fontSize - 15.75) < 0.1 }
        second.terminal.applyMagnification(0, phase: .cancelled)
        try await wait { abs(store.fontSize - 21) < 0.1 }
        first.terminal.applyMagnification(-5, phase: [])
        try await wait { store.fontSize == 10 && abs(first.terminal.font.pointSize - 10) < 0.1 }
        first.terminal.applyMagnification(8, phase: [])
        try await wait { store.fontSize == 28 && abs(first.terminal.font.pointSize - 28) < 0.1 }
        store.fontSize = 17
        try await wait { abs(first.terminal.font.pointSize - 17) < 0.1 }
        first.terminal.send(txt: "printf '\\nFarport · 双指缩放终端字体\\n'\n")
        print("PASS · 原生 magnify 处理链：放大、缩小、取消、边界、跨窗格一致、保存、不向 Shell 发送字符")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("缩放 UI 验证超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
