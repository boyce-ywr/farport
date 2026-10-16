import Foundation
import WorkbenchCore

func checkAttachmentIdentity() throws {
    let session = UUID(); let connection = UUID()
    func identity(focus: UInt64 = 1, input: UInt64 = 1, window: Int? = 42, active: Bool = true) -> AttachmentDeliveryIdentity {
        AttachmentDeliveryIdentity(sessionID: session, connectionID: connection, focusGeneration: focus, inputGeneration: input, windowNumber: window, applicationActive: active)
    }
    let initial = identity()
    try expect(identity().allowsAutomaticInsertion(from: initial), "同一附件目标允许自动插入")
    try expect(identity().allowsAutomaticInsertion(from: identity(active: false)), "Finder 拖入后应用激活允许自动插入")
    try expect(!identity(active: false).allowsAutomaticInsertion(from: initial), "后台应用不自动插入")
    try expect(!identity(focus: 2).allowsAutomaticInsertion(from: initial), "切换标签不自动插入")
    try expect(!identity(input: 2).allowsAutomaticInsertion(from: initial), "继续输入不自动插入")
    try expect(!identity(window: 43).allowsAutomaticInsertion(from: initial), "切换窗口不自动插入")
    try expect(!identity(window: nil).allowsAutomaticInsertion(from: identity(window: nil)), "未挂载窗口不自动插入")
    try expect(!AttachmentDeliveryIdentity(sessionID: session, connectionID: UUID(), focusGeneration: 1, inputGeneration: 1, windowNumber: 42).allowsAutomaticInsertion(from: initial), "重连不自动插入")
}
