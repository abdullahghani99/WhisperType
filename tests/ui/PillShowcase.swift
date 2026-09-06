import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WhisperTypeKit

private func pill(_ state: DockState) -> DockView {
    DockView(state: state, onToggleRecord: {}, onPickMic: { _ in }, onToggleMode: {}, onMeeting: {}, onSettings: {},
             micDevices: { [("usb", "USB microphone")] })
}
func renderPillShowcase(_ output: URL) {
    let labels = ["At rest", "Prompt mode", "Starting microphone", "Listening", "Processing", "Ready for review", "Sent", "Recovery", "Meeting", "Microphone interrupted"]
    let states = labels.map { _ in DockState() }
    for state in states { state.serverOK = true; state.micName = "USB microphone" }
    states[1].mode = .prompt
    states[2].starting()
    states[3].begin(); states[3].elapsed = 14
    for index in 0..<24 { states[3].setLevel(Float(0.1 + abs(sin(Double(index) * 0.54)) * 0.72)) }
    states[4].begin(); states[4].finishRecording()
    states[5].ready(); states[6].complete(words: 28)
    states[7].fail("Server unavailable. Audio saved.")
    states[8].meetingRecording = true; states[8].meetingElapsed = 1280
    states[9].meetingRecording = true; states[9].meetingElapsed = 1280; states[9].meetingMicTrouble = true
    let expanded = DockState(); expanded.serverOK = true; expanded.micName = "USB microphone"; expanded.expanded = true
    let gallery = VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
            Text("The recording pill").font(VF.Font.display)
            Text("Compact at rest. Clear when it matters.").font(VF.Font.body).foregroundStyle(VF.Color.muted(dark: false))
        }
        ForEach(0..<5) { row in
            HStack(alignment: .top, spacing: 28) {
                ForEach(0..<2) { column in
                    let index = row * 2 + column
                    VStack(alignment: .leading, spacing: 2) {
                        Text(labels[index]).font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: false))
                        pill(states[index]).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 500, alignment: .leading)
                }
            }
        }
        Divider()
        HStack(spacing: 24) {
            Text("Expanded controls").font(VF.Font.callout)
            pill(expanded)
        }
        Text("Actual SwiftUI controls · synthetic audio levels · no microphone captured").font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: false))
    }.padding(32).foregroundStyle(VF.Color.ink(dark: false)).background(VF.Color.canvas(dark: false))
    render(gallery, "Pill-Showcase", width: 1120, height: 840)

    let animated = DockState(); animated.serverOK = true; animated.micName = "USB microphone"
    let scene = VStack(spacing: 0) {
        Text("WhisperType · recording controls").font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: false))
        pill(animated).frame(width: 680, height: 112)
        Text("Synthetic sequence · actual interface transitions").font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: false))
    }.frame(width: 720, height: 176).background(VF.Color.canvas(dark: false))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 176), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: scene); window.orderBack(nil)
    let url = output.appendingPathComponent("WhisperType-Pill-Motion.gif")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 72, nil) else { window.close(); return }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    var frames = 0
    for frame in 0..<72 {
        let start = Date()
        switch frame {
        case 6: animated.expanded = true
        case 18: animated.starting()
        case 24: animated.begin()
        case 46: animated.finishRecording()
        case 57: animated.complete(words: 28)
        case 66: animated.returnToIdle()
        default: break
        }
        if (24..<46).contains(frame) {
            for sample in 0..<3 { animated.setLevel(Float(0.08 + abs(sin(Double(frame * 3 + sample) * 0.53)) * 0.7)) }
            animated.elapsed = Double(frame - 24) / 6
        }
        window.contentView?.layoutSubtreeIfNeeded()
        pumpPreviewEvents(until: Date().addingTimeInterval(0.025))
        guard let image = captureOwnWindow(window) else { continue }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
        frames += 1
        let remaining = start.addingTimeInterval(0.08)
        if Date() < remaining { pumpPreviewEvents(until: remaining) }
    }
    print("PILL MOTION", frames, "frames", CGImageDestinationFinalize(destination))
    window.orderOut(nil); window.close()
}
