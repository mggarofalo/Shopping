import CloudKit
import Foundation
import OSLog

/// User guidance and safe diagnostics are separate from the operation's recovery state.
enum HomeSharingErrorPresentation {
    static func message(_ error: Error) -> String {
        if let error = error as? HomeMembershipError { return error.localizedDescription }
        if let error = error as? HomeSharingError { return error.localizedDescription }
        if let error = error as? HomeShareGraphValidator.Failure { return error.localizedDescription }
        if let error = error as? HomeDeletionError { return error.localizedDescription }
        if let error = error as? ManagedHomeLeaveTransport.Failure { return error.localizedDescription }
        if let error = error as? ShopperSessionError { return error.localizedDescription }
        if let error = error as? HomeLeaveError { return error.localizedDescription }
        if let error = error as? CKError {
            switch error.code {
            case .networkUnavailable, .networkFailure:
                return "iCloud couldn’t be reached. Check your connection and try again."
            case .notAuthenticated:
                return "Sign in to iCloud in iPhone Settings, then try again."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free up space in iPhone Settings, then try again."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud is busy. Try again in a moment."
            case .permissionFailure:
                return "iCloud did not allow this sharing action. Check this home’s access and try again."
            case .unknownItem, .zoneNotFound:
                return "iCloud couldn’t find this home’s sharing information. Check members again."
            default:
                return "iCloud couldn’t complete this sharing action (error \(error.code.rawValue)). Try again."
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain {
            return "This home’s saved sharing information could not be read or updated (error \((error as NSError).code)). Try again."
        }
        return "This home action couldn’t be completed. Try again."
    }

    /// Never log error descriptions/userInfo: they can contain links, accounts or record data.
    static func record(_ error: Error, operation: String) {
        let value = error as NSError
        let category = value.domain == CKErrorDomain ? "CloudKit"
            : value.domain == NSCocoaErrorDomain ? "Cocoa" : "Application"
        Logger(subsystem: "com.mggarofalo.shopping", category: "HomeSharing")
            .error("\(operation, privacy: .public) failed: \(category, privacy: .public) code \(value.code, privacy: .public)")
    }
}
