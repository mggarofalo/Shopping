#import "CloudKitOneTimeLinkBridge.h"

// These public selectors are declared in the iOS 26+ SDK with iOS 18 runtime
// availability. Supply only their declarations for the pinned older CI SDK.
// CloudKit owns the implementations; no category implementation is installed.
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED < 260000
@interface CKShareParticipant (ShoppingOneTimeLinkSDKDeclarations)
+ (instancetype)oneTimeURLParticipant API_AVAILABLE(ios(18.0));
@end

@interface CKShare (ShoppingOneTimeLinkSDKDeclarations)
- (nullable NSURL *)oneTimeURLForParticipantID:(nonnull NSString *)participantID API_AVAILABLE(ios(18.0));
@end
#endif

CKShareParticipant * _Nullable ShoppingMakeOneTimeLinkParticipant(void) {
    if (@available(iOS 18.0, *)) {
        if ([CKShareParticipant respondsToSelector:@selector(oneTimeURLParticipant)]) {
            return [CKShareParticipant oneTimeURLParticipant];
        }
    }
    return nil;
}

NSURL * _Nullable ShoppingOneTimeInvitationURL(CKShare *share, NSString *participantID) {
    if (@available(iOS 18.0, *)) {
        if ([share respondsToSelector:@selector(oneTimeURLForParticipantID:)]) {
            return [share oneTimeURLForParticipantID:participantID];
        }
    }
    return nil;
}
