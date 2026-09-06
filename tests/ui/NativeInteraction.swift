import AppKit

/// Real AppKit editor/window events; synthetic data and no external keystrokes.
func testNativeReviewInteraction() {
    guard activePreview else { return }
    let review = PromptReviewController()
    var variants: [String:String] = [:]
    var choices = 0
    var picked: String?
    review.show(concise: "Short draft", detailed: "Long draft", coding: "Code draft", onDraft: { draft,_ in variants = draft }) { value in choices += 1; picked = value }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.15))
    guard review.panel?.isKeyWindow == true else {
        print("NATIVE REVIEW BLOCKED: preview cannot become key; foreground=", NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
        review.discardOpenReview(); return
    }
    review.textView?.string = "Edited short draft"
    func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: review.panel?.windowNumber ?? 0, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        app.postEvent(event, atStart: false)
        pumpPreviewEvents(until: Date().addingTimeInterval(0.1))
    }
    key("2", code: 19, modifiers: .command)
    previewCheck(variants["concise"] == "Edited short draft")
    previewCheck(review.textView?.string == "Long draft")
    review.textView?.string = "Edited long draft"
    review.panel?.performClose(nil)
    previewCheck(!review.isVisible && choices == 1 && picked == nil)
    previewCheck(variants["detailed"] == "Edited long draft")
    review.showText("Second review") { value in choices += 1; picked = value }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.15))
    key("\r", code: 36, modifiers: .command)
    previewCheck(choices == 2 && picked == "Second review" && !review.isVisible)
    review.showText("Save failure", onDraft: { _,_ in throw CocoaError(.fileWriteOutOfSpace) }) { _ in choices += 1 }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.1))
    review.panel?.performClose(nil)
    previewCheck(review.isVisible && choices == 2, "Disk error must preserve the open edit")
    review.discardOpenReview()
    previewCheck(!review.isVisible && choices == 3)
    print("NATIVE REVIEW PASS: key focus, Cmd2, variant draft persistence, title-bar close, reopen, CmdReturn, disk-failure retention, explicit discard")
}
