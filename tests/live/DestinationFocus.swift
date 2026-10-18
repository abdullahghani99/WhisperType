import AppKit
import ApplicationServices
func check(_ condition: Bool, _ message: String) { if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) } }
let own: pid_t = 100
func resolve(_ ax: pid_t?, _ status: AXError, _ front: pid_t?) -> pid_t? {
 CaptureDestination.resolveFocusedPID(axPID:ax,status:status,frontmostPID:front,ownPID:own)
}
check(resolve(200,.success,300)==200,"AX focus wins")
check(resolve(nil,.noValue,300)==300,"NoValue validates current frontmost app")
check(resolve(nil,.noValue,nil)==nil,"No current app declines")
check(resolve(nil,.noValue,own)==nil,"Own app never becomes destination")
check(resolve(own,.success,300)==nil,"Own AX focus cannot fall back externally")
check(resolve(nil,.cannotComplete,300)==nil,"Transport failure cannot fall back")
check(resolve(nil,.apiDisabled,300)==nil,"Permission failure cannot fall back")
check(resolve(nil,.success,300)==nil,"Malformed success cannot fall back")
check(resolve(nil,.noValue,0)==nil,"Invalid process declines")
print("9 focus policy cases PASS; no UI, keystrokes or microphone")

let fieldCases: [(String?, String?, Bool, Bool, Bool)] = [
    (nil, nil, false, false, true),
    (nil, nil, true, false, false),
    ("AXTextArea", nil, false, false, true),
    ("AXWebArea", nil, false, false, true),
    ("AXGroup", nil, false, false, true),
    ("AXButton", nil, false, false, false),
    ("AXTextField", "AXSecureTextField", false, false, false),
    (nil, nil, false, true, false),
    ("AXTextArea", nil, false, true, true),
    ("AXTextField", nil, false, true, true),
    ("AXTextField", "AXSearchField", false, true, true),
    ("AXTextField", "AXSecureTextField", false, true, false),
    ("AXTextArea", "AXSecureTextField", false, true, false),
    ("AXWebArea", nil, false, true, false),
    ("AXGroup", nil, false, true, false),
    ("AXButton", nil, false, true, false),
    ("", nil, false, true, false),
    ("AXTextArea", nil, true, true, true),
    ("AXTextField", nil, true, true, true),
    ("AXScrollArea", nil, true, true, true),
    ("AXScrollArea", nil, true, false, true),
    ("AXTextField", "AXSecureTextField", true, true, false),
    ("AXTextField", "AXSecureTextField", true, false, false),
    (nil, nil, true, true, false),
    ("", nil, true, true, false)
]
for (role, subrole, remote, secure, expected) in fieldCases {
    guard CaptureDestination.acceptsField(role: role, subrole: subrole, remote: remote, secureInput: secure) == expected else {
        print("FAIL: paste capability policy"); exit(1)
    }
}
print("\(fieldCases.count) field capability cases PASS; Secure Input permits verified local text roles only, password/unknown local fields declined; remote canvases require paired-agent validation")
