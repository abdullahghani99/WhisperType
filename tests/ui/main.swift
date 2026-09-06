import AppKit
import SwiftUI
import CoreText
import ScreenCaptureKit
import WhisperTypeKit

if let path = ProcessInfo.processInfo.environment["VF_UI_LOG_PATH"] { freopen(path, "w", stdout); setbuf(stdout, nil) }
let previousApp = ProcessInfo.processInfo.environment["VF_UI_RESTORE_PID"].flatMap(Int32.init).flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
let activePreview = ProcessInfo.processInfo.environment["VF_UI_ACTIVE"] == "1"
print("ACTIVE PREVIEW REQUESTED", activePreview)
let app = NSApplication.shared
app.setActivationPolicy(activePreview ? .regular : .accessory)
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[1])
for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold"] {
 CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(name+".ttf") as CFURL, .process, nil)
}
VF.Font.interAvailable = NSFont(name:"Inter-Regular",size:14) != nil
print("Preview fonts registered:",VF.Font.interAvailable)
var retained: [NSWindow] = []
// Dispatch AppKit events while capturing multiple windows in one run. A bare
// nested RunLoop services timers but leaves activation/key-window events queued.
func pumpPreviewEvents(until deadline: Date) {
 while Date() < deadline {
  if let event = app.nextEvent(matching: .any, until: min(deadline, Date().addingTimeInterval(0.01)), inMode: .default, dequeue: true) { app.sendEvent(event) }
  app.updateWindows()
 }
}
func captureOwnWindow(_ win: NSWindow) -> CGImage? {
 var screenshot: CGImage?
 var completed = false
 if #available(macOS 14.4, *) {
    // Only this process's synthetic windows; no screen-wide permission or pixels.
    Task { @MainActor in
        defer { completed = true }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else { print("MISSING OWN WINDOW"); return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)); config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.scalesToFit = true; config.captureResolution = .best
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch { print("CAPTURE ERROR", error) }
    }
    let deadline = Date().addingTimeInterval(10)
    while !completed && Date() < deadline { pumpPreviewEvents(until: Date().addingTimeInterval(0.01)) }
 }
 return screenshot
}
func saveView(_ view: NSView, _ name: String, width: CGFloat, height: CGFloat, controller: NSViewController? = nil) {
 view.frame = NSRect(x:0,y:0,width:width,height:height)
 let win: NSWindow
 if let controller = controller { win = NSWindow(contentViewController: controller) }
 else { win = NSWindow(contentRect:view.frame,styleMask:[.titled, .closable, .miniaturizable, .resizable],backing:.buffered,defer:false); win.contentView = view }
 win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
 win.setContentSize(NSSize(width: width, height: height))
 win.appearance = NSAppearance(named: name.contains("Dark") ? .darkAqua : .aqua)
 win.title = "WhisperType — " + name.replacingOccurrences(of: "-", with: " ")
 win.isReleasedWhenClosed = false
 win.setFrameOrigin(NSPoint(x: 70, y: 100))
 if activePreview { app.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil) } else { win.orderBack(nil) }
 retained.append(win)
 view.layoutSubtreeIfNeeded()
 pumpPreviewEvents(until:Date().addingTimeInterval(0.6))
 view.layoutSubtreeIfNeeded()
 print("WINDOW STATE", name, "active=", app.isActive, "key=", win.isKeyWindow)
 let screenshot = captureOwnWindow(win)
 guard let screenshot = screenshot else { print("NO IMAGE", name); win.close(); return }
 let rep = NSBitmapImageRep(cgImage: screenshot)
 guard let data=rep.representation(using:.png,properties:[:]) else {return}
 let path=out.appendingPathComponent("WhisperType-\(name).png")
 try! data.write(to:path)
 print("RENDERED",name,rep.pixelsWide,rep.pixelsHigh)
 win.orderOut(nil); win.close()
}
func render<V:View>(_ view:V,_ name:String,width:CGFloat=1180,height:CGFloat=800) {
 let controller = NSHostingController(rootView:view.frame(width: width, height: height))
 saveView(controller.view,name,width:width,height:height,controller:controller)
}
func runReview() {
assert(MeetingsView.isMine("Ann: send the report", myName: "Ann"))
assert(!MeetingsView.isMine("Johann: send the report", myName: "Ann"))
assert(MeetingsView.isMine("**ALEX:** review the numbers", myName: "Alex"))
print("MEETING NAME BOUNDARIES PASS")
ReviewDefaults.shared.set(nil,forKey:"vf_preroll")
let firstLaunchSettings=SettingsState()
ReviewDefaults.shared.set(true,forKey:"vf_preroll")
assert(firstLaunchSettings.prerollEnabled == true)
assert(ReviewDefaults.shared.bool(forKey:"vf_preroll") == true)
print("FIRST LAUNCH corrected: displayed and effective pre-roll agree")
let settings=SettingsState();settings.loadMics();settings.serverOK=true
settings.activeMicName="USB microphone";settings.microphonePermission="Allowed";settings.accessibilityPermission="Allowed";settings.screenPermission="Allowed"
var ready = try! RecordingStore.create(wav: MeetingAudioJournal.wavHeader(bytes: 0), kind: "dictation")
ready.status="ready";ready.text="Please send the updated report by Friday. Keep the original customer numbers.";ready.error="Destination changed. Your result is ready for review."
try! RecordingStore.save(ready)
var pending = try! RecordingStore.create(wav: MeetingAudioJournal.wavHeader(bytes: 0), kind: "prompt")
pending.error="Server unavailable. Your audio is saved; retry when connected."
try! RecordingStore.save(pending)
settings.reloadRecovery()
settings.historyItems=[.init(id:1,timestamp:"2026-09-06 08:15",text:"Please send the updated report by Friday."),.init(id:2,timestamp:"2026-09-05 14:30",text:"Review the draft, confirm the owner, and schedule the next meeting.")]
settings.replacements=[("atelas","Atlas"),("voice flow","WhisperType")]
settings.terms=["WhisperType","Project Atlas","Quarterly review"]
settings.history=["Please send the updated report by Friday. Keep the original customer numbers.","There are three actions: review the draft, confirm the owner, and schedule the next meeting."]
settings.suggestions=[.init(id:1,kind:"replacement",from:"atelas",to:"Atlas",count:3,source:"edit"),.init(id:2,kind:"term",from:"",to:"Meridian",count:4,source:"scan")]
let meetings=MeetingsState()
meetings.items=[.init(id:1,ts:"2026-09-06 08:00:00",title:"Product launch review and delivery decisions",status:"done",speakers:3,error:"",chars:1800),.init(id:2,ts:"2026-09-05 12:00:00",title:"Weekly team planning and customer follow-up",status:"processing",speakers:0,error:"",chars:0)]
let notes="**Summary**\nThe team agreed to send the release candidate on Friday after checking microphone recovery.\n\n**Decisions**\n- Keep the current server architecture.\n- Verify the actual microphone before reporting that recording is ready.\n\n**Action items**\n- Alex: confirm the recovery test results by Thursday.\n- Morgan: update the release notes and check the installation guide.\n\n**Open questions**\n- Which fallback microphone should be used when the headset disconnects?"
meetings.selected = .init(id:1,status:"done",transcript:"**Alex:** Let’s agree on the release checks.\n\n**Morgan:** I will update the guide.\n\n**Speaker 3:** Please check recovery after unplugging the headset.",notes:notes,speakers:3,error:"")
for section in MainView.Section.allCases {
 let nav=MainNav();nav.section=section
 render(MainView(settings:settings,meetings:meetings,nav:nav).environment(\.colorScheme,.light),section.rawValue+"-Light")
}
let homeNav=MainNav();homeNav.section = .capture
render(MainView(settings:settings,meetings:meetings,nav:homeNav).environment(\.colorScheme,.dark),"Capture-Dark")
let nav=MainNav();nav.section = .meetings
render(MainView(settings:settings,meetings:meetings,nav:nav).environment(\.colorScheme,.dark),"Meetings-Dark")
meetings.selected = .init(id:2,status:"processing",transcript:"",notes:"",speakers:0,error:"")
render(MainView(settings:settings,meetings:meetings,nav:nav).environment(\.colorScheme,.light),"Meeting-Processing")
meetings.selected=nil;meetings.items=[];meetings.loadError="Synthetic server error for review"
render(MainView(settings:settings,meetings:meetings,nav:nav).environment(\.colorScheme,.light),"Meeting-Error")
let dockNames=["Idle", "Meeting", "Mic trouble", "Call offer", "Listening", "Processing", "Error", "Controls"]
var dockStates:[DockState]=[]
for name in dockNames {
 let s=DockState();s.serverOK=true;s.micName="USB microphone"
 if name == "Meeting" {s.meetingRecording=true}
 if name == "Mic trouble" {s.meetingRecording=true;s.meetingMicTrouble=true}
 if name == "Call offer" {s.callOffer=true;s.callTitle="Record this Teams call?"}
 if name == "Listening" {s.begin();s.elapsed=8;for _ in 0..<24 {s.setLevel(0.4)}}
 if name == "Processing" {s.begin();s.finishRecording()}
 if name == "Error" {s.fail("Server unreachable. Audio saved.")}
 if name == "Controls" {s.expanded=true}
 dockStates.append(s)
}
let gallery=VStack(alignment:.leading,spacing:16) {
 ForEach(Array(dockNames.enumerated()),id:\.offset) { i,name in
  HStack(spacing:20) {
   Text(name).foregroundStyle(.black).frame(width:110,alignment:.leading)
   DockView(state:dockStates[i],forceControls:name == "Controls",onToggleRecord:{},onPickMic:{_ in},onToggleMode:{},onMeeting:{},onSettings:{},micDevices:{AudioDevices.inputs().map{($0.uid,$0.name)}})
   Spacer()
  }
 }
}.padding(28).background(Color(red:0.97,green:0.96,blue:0.95))
render(gallery,"Dock-States",width:1100,height:920)
let prompt = PromptReviewController()
prompt.levels = ["Create a clear release checklist for WhisperType. Include microphone switching, transcript recovery, and safe insertion into the intended destination.","Goal: Make dictation dependable.\nRequirements: Preserve audio and confirm the selected input.","Task: Implement recording ownership guards.\nAcceptance: Stale callbacks cannot overwrite a new recording."]
prompt.buildPanel();prompt.render()
if let panel = prompt.panel {
 panel.appearance = NSAppearance(named: .aqua)
 panel.setFrameOrigin(NSPoint(x: 150, y: 150))
 if activePreview { app.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) } else { panel.orderBack(nil) }
 pumpPreviewEvents(until: Date().addingTimeInterval(0.5))
 if let image = captureOwnWindow(panel), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
  try! data.write(to: out.appendingPathComponent("WhisperType-Prompt-Review.png"))
 }
 panel.orderOut(nil); panel.close()
}
renderPillShowcase(out)
testNativeReviewInteraction()
print("COMPLETE: no AppController, AudioRecorder, MeetingRecorder, or CallWatcher compiled into preview; clients nil; preference writes in-memory")
if activePreview { previousApp?.activate(options: []) }
exit(0)

}
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in runReview() }
app.run()
