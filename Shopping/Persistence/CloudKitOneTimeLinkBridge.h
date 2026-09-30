#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns nil when the public one-time participant factory is unavailable.
FOUNDATION_EXPORT CKShareParticipant * _Nullable ShoppingMakeOneTimeLinkParticipant(void);

/// Preserves CloudKit's nil result until a saved participant has a one-time URL.
FOUNDATION_EXPORT NSURL * _Nullable ShoppingOneTimeInvitationURL(CKShare *share, NSString *participantID);

NS_ASSUME_NONNULL_END
