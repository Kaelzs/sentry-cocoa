#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SentryURLSessionDemux : NSObject

@property (atomic, strong, readonly) NSURLSessionConfiguration *configuration;
@property (atomic, strong, readonly) NSURLSession *session;

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request delegate:(id<NSURLSessionDataDelegate>)delegate modes:(NSArray *)modes;

@end

NS_ASSUME_NONNULL_END
