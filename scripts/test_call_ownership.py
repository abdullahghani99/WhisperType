#!/usr/bin/env python3
"""Exercise shipping meeting-start and call-end decisions without audio or UI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'client/Sources/WhisperType/main.swift').read_text()
def block(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
start = block('    private func startMeeting(fromCall:')
start = start[:start.index('        Task {')] + '    }'
start = start.replace('private func', 'func')
toggle = block('    @objc private func toggleMeeting()').replace('@objc private func', 'func')
ended = block('        callWatcher.onCallEnded =')
# Check the real UI routes as well as the transition behavior.
assert 'textAction("Record", action: onAcceptCall)' in (root / 'client/Sources/WhisperType/DockView.swift').read_text()
assert 'onAcceptCall: { [weak self] in self?.onAcceptCall() }' in (root / 'client/Sources/WhisperType/DockController.swift').read_text()
assert 'dockController.onAcceptCall = { [weak self] in self?.startMeeting(fromCall: true) }' in source
fixture = '''import Foundation
func vlog(_ text: String) {}
final class Recorder { var isRecording = false; var isStarting = false }
final class State { var callOffer = false; var captureStatus = "" }
final class Dock { let state = State() }
final class Window { let settings = State() }
final class Watcher { var onCallEnded: () -> Void = {} }
final class Harness {
 var terminationPending = false; var isRecording = false; var meetingStarting = false; var meetingFinishing = false
 var meetingAttemptID: UUID?; var meetingFromCall = false; var stops = 0
 let meetingRecorder = Recorder(); let dockController = Dock(); let mainWC = Window(); let callWatcher = Watcher()
 func stopMeeting() { stops += 1; meetingRecorder.isRecording = false }
''' + start + '\n' + toggle + '\n func connect() {\n' + ended + '\n }\n}\n' + '''
func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: " + message + "\\n", stderr); exit(1) } }
let manual = Harness(); manual.connect(); manual.dockController.state.callOffer = true
manual.toggleMeeting(); check(!manual.meetingFromCall, "Manual start must not inherit a call offer")
manual.meetingRecorder.isRecording = true; manual.callWatcher.onCallEnded()
check(manual.stops == 0 && !manual.dockController.state.callOffer, "Call end clears offer but preserves manual meeting")
let offered = Harness(); offered.connect(); offered.dockController.state.callOffer = true
 offered.startMeeting(fromCall: true); check(offered.meetingFromCall, "Accepted offer owns its meeting")
 offered.meetingRecorder.isRecording = true; offered.callWatcher.onCallEnded()
check(offered.stops == 1, "Call-owned meeting stops when call ends")
let expired = Harness(); expired.connect(); expired.startMeeting(fromCall: true)
expired.meetingRecorder.isRecording = true; expired.callWatcher.onCallEnded()
check(expired.stops == 0, "Expired offer must not acquire call ownership")
let busy = Harness(); busy.terminationPending = true; busy.startMeeting(fromCall: true)
check(!busy.meetingStarting && busy.meetingAttemptID == nil, "Quit blocks a new meeting")
let active = Harness(); active.meetingRecorder.isRecording = true; active.toggleMeeting()
check(active.stops == 1, "Manual Finish still stops an active recording")
print("7 actual meeting ownership/transition checks and 3 UI routing checks PASS; no microphone or foreground UI")
'''
with tempfile.TemporaryDirectory(prefix='whispertype-call-ownership-') as directory:
    path = Path(directory) / 'check.swift'
    path.write_text(fixture)
    subprocess.run(['swift', str(path)], check=True)
