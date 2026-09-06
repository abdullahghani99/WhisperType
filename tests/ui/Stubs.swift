import Foundation
struct AudioInputDevice: Identifiable, Hashable { let id: Int; let uid: String; let name: String }
enum AudioDevices {
 static var warmBluetooth: Bool { true }
 static let defaultsKey = "vf_micUID"
 static func inputs() -> [AudioInputDevice] { [.init(id:1,uid:"usb",name:"PowerConf"),.init(id:2,uid:"built-in",name:"MacBook Pro Microphone"),.init(id:3,uid:"airpods",name:"AirPods Pro")] }
}
final class ReviewDefaults {
 static let shared = ReviewDefaults()
 private var data:[String:Any] = ["vf_preroll":true,"vf_micUID":"usb","vf_myName":"Alex"]
 func string(forKey k:String)->String? {data[k] as? String}
 func bool(forKey k:String)->Bool {data[k] as? Bool ?? false}
 func object(forKey k:String)->Any? {data[k]}
 func set(_ v:Any?,forKey k:String) {data[k]=v}
}

func vlog(_ message: String) { print(message) }
