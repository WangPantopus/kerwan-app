// main.swift
// WhisperService — XPC service target
//
// Entry point for the WhisperService XPC process.
//
// The service is embedded in the main app bundle at:
//   KerwanApp.app/Contents/XPCServices/com.kerwan.WhisperService.xpc
//
// The listener name ("com.kerwan.WhisperService") must match:
//   • The NSXPCServiceName key in this target's Info.plist
//   • The mach service name passed to NSXPCConnection in the main app

import Foundation

let delegate = WhisperServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate

// `resume()` starts accepting connections and blocks the run loop.
// Control never returns from this call in normal operation.
listener.resume()
