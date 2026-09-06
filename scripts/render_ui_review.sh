#!/bin/bash
# Render actual views with synthetic data and no audio/AppController/live client.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?pass an output directory}"
SCRATCH="${VF_UI_SCRATCH:-$(mktemp -d /tmp/whispertype-ui.XXXXXX)}"
mkdir -p "$SCRATCH/Sources/ReviewPreview" "$SCRATCH/Sources/WhisperTypeKit" "$OUT"
cp "$ROOT/client/Sources/WhisperTypeKit/"*.swift "$SCRATCH/Sources/WhisperTypeKit/"
for source in MainWindow SettingsWindow MeetingsWindow DockView DockController DockDragSurface NativePasteInserter ServerClient PromptReview CaptureHome; do
  cp "$ROOT/client/Sources/WhisperType/$source.swift" "$SCRATCH/Sources/ReviewPreview/"
done
cp "$ROOT/tests/ui/"*.swift "$SCRATCH/Sources/ReviewPreview/"
python3 - "$SCRATCH" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
(root/'Package.swift').write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name:"WhisperTypeReviewPreview",platforms:[.macOS(.v13)],targets:[.target(name:"WhisperTypeKit"),.executableTarget(name:"ReviewPreview",dependencies:["WhisperTypeKit"])])
''')
for path in (root/'Sources/ReviewPreview').glob('*.swift'):
 s=path.read_text().replace('UserDefaults.standard','ReviewDefaults.shared')
 if path.name=='PromptReview.swift': s=s.replace('private var panel','var panel').replace('private var levels','var levels').replace('private var textView','var textView').replace('private func buildPanel','func buildPanel').replace('private func render','func render')
 if path.name=='DockController.swift': s=s.replace('private var panel','var panel').replace('private var hosting','var hosting').replace('private var previewPanel','var previewPanel').replace('DockPlacement(store: .standard)','DockPlacement(store: dockReviewDefaults)').replace('defaults: UserDefaults = .standard','defaults: UserDefaults = dockReviewDefaults')
 if path.name=='DockController.swift':
  s=s.replace('previewPanel?.orderFrontRegardless()', 'if ProcessInfo.processInfo.environment["VF_UI_DOCK_BACKGROUND"] != "1" { previewPanel?.orderFrontRegardless() }')
  s=s.replace('panel?.orderFrontRegardless()', 'if ProcessInfo.processInfo.environment["VF_UI_DOCK_BACKGROUND"] == "1" { panel?.alphaValue = 0; panel?.orderBack(nil) } else { panel?.orderFrontRegardless() }')
  s=s.replace('    private func dockProbe(on screen: NSScreen) -> DockProbe {', '    private func dockProbe(on screen: NSScreen) -> DockProbe {\n        if ProcessInfo.processInfo.environment["VF_UI_DOCK_BACKGROUND"] == "1" { return .away }')
 path.write_text(s)
PY
swift build --package-path "$SCRATCH" --product ReviewPreview > "$OUT/build.log" 2>&1
BIN="$(swift build --package-path "$SCRATCH" --show-bin-path)"
DATA_ROOT="$(mktemp -d "$SCRATCH/data.XXXXXX")"
RENDER_OUT="$(mktemp -d "$SCRATCH/render.XXXXXX")"
mkdir -p "$SCRATCH/fonts"
cp "$ROOT/client/Sources/WhisperType/Resources/"*.ttf "$SCRATCH/fonts/"
if [[ "${VF_UI_ACTIVE:-0}" == "1" ]]; then
  APP="$SCRATCH/WhisperType Preview.app"
  mkdir -p "$APP/Contents/MacOS"
  cp "$BIN/ReviewPreview" "$APP/Contents/MacOS/ReviewPreview"
  python3 - "$APP" <<'PLIST'
import plistlib, sys
from pathlib import Path
with (Path(sys.argv[1])/'Contents/Info.plist').open('wb') as file:
 plistlib.dump({'CFBundleIdentifier':'app.whispertype.review.preview','CFBundleName':'WhisperType Preview','CFBundleExecutable':'ReviewPreview','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}, file)
PLIST
  codesign --force --sign - "$APP" > "$OUT/sign.log" 2>&1
  RESTORE_PID="$(swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)')"
  open -W -n --env "VF_DATA_DIR=$DATA_ROOT" --env "VF_UI_ACTIVE=1" --env "VF_UI_NATIVE_ONLY=${VF_UI_NATIVE_ONLY:-0}" --env "VF_UI_RESTORE_PID=$RESTORE_PID" --env "VF_UI_LOG_PATH=$RENDER_OUT/render.log" "$APP" --args "$SCRATCH/fonts" "$RENDER_OUT"
else
  VF_DATA_DIR="$DATA_ROOT" "$BIN/ReviewPreview" "$SCRATCH/fonts" "$RENDER_OUT" > "$RENDER_OUT/render.log" 2>&1
fi
cp "$RENDER_OUT/"* "$OUT/"
cat "$OUT/render.log"
grep -q '^COMPLETE:' "$OUT/render.log" || { echo "Preview did not complete" >&2; exit 1; }
