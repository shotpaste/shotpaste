import Foundation

extension Error {
  var isPermissionDenied: Bool {
    let nsError = self as NSError
    if nsError.domain == NSCocoaErrorDomain {
      return nsError.code == NSFileReadNoPermissionError
        || nsError.code == NSFileWriteNoPermissionError
    }
    if nsError.domain == NSPOSIXErrorDomain {
      return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    }
    return false
  }
}
