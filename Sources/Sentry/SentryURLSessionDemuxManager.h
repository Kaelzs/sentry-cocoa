#import <Foundation/Foundation.h>
#import "SentryURLSessionDemux.h"

NS_ASSUME_NONNULL_BEGIN

@interface SentryURLSessionDemuxManager : NSObject

+ (SentryURLSessionDemuxManager *)sharedInstance;

- (SentryURLSessionDemux *)demuxForSession:(NSURLSession *)session;

@property (atomic, strong, readonly) SentryURLSessionDemux *defaultDemux;

@end

NS_ASSUME_NONNULL_END
