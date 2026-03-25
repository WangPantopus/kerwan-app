import Foundation

// MARK: - WhisperService entry point

let delegate = WhisperServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

// Block the main thread — NSXPCListener runs on the current run loop.
RunLoop.current.run()
