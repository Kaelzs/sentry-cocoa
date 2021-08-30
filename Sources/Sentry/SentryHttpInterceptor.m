#import "SentryHttpInterceptor+Private.h"
#import "SentryHub+Private.h"
#import "SentrySDK+Private.h"
#import "SentryScope+Private.h"
#import "SentryTraceHeader.h"
#import "SentryURLSessionDemux.h"
#import "SentryURLSessionDemuxManager.h"

@interface
SentryHttpInterceptor ()

@property (readwrite) NSThread *clientThread;
@property (readwrite) NSArray *modes;
@property (readwrite) NSURLSessionTask *originalTask;
@property (readwrite) NSURLSessionTask *currentTask;
@property (nullable, readonly, weak) id<NSURLSessionTaskDelegate> originalDelegate;
@property (nullable, readonly) NSOperationQueue *originalDelegateOperationQueue;

+ (void)configureSessionConfiguration:(NSURLSessionConfiguration *)configuration;

@end

@implementation SentryHttpInterceptor

+ (void)configureSessionConfiguration:(NSURLSessionConfiguration *)configuration
{
    if (configuration == nil)
        return;

    NSMutableArray *protocolClasses = configuration.protocolClasses != nil
        ? [NSMutableArray arrayWithArray:[configuration protocolClasses]]
        : [[NSMutableArray alloc] init];

    if (![protocolClasses containsObject:[self class]]) {
        // Adding SentryHTTPInterceptor at index 0 of the protocol list to be the first to
        // intercept.
        [protocolClasses insertObject:[self class] atIndex:0];
    }

    configuration.protocolClasses = protocolClasses;
}

- (instancetype)initWithTask:(NSURLSessionTask *)task cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    self = [super initWithTask:task cachedResponse:cachedResponse client:client];
    if (self != nil) {
        self->_originalTask = task;
    }
    return self;
}

// Documentation says that the method that takes a task parameter are preferred by the system to
// those that do not. But for the iOS versions we support `canInitWithTask:` does not work well.
+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    // Intercept the request if it is a http/https request
    // not targeting Sentry and there is transaction in the scope.
    NSNumber *intercepted = [NSURLProtocol propertyForKey:SENTRY_INTERCEPTED_REQUEST
                                                inRequest:request];
    if (intercepted != nil && [intercepted boolValue])
        return NO;

    NSURL *apiUrl = [NSURL URLWithString:SentrySDK.options.dsn];
    if ([request.URL.host isEqualToString:apiUrl.host] &&
        [request.URL.path containsString:apiUrl.path])
        return NO;

    if (SentrySDK.currentHub.scope.span == nil)
        return NO;

    return ([request.URL.scheme isEqualToString:@"http"] ||
        [request.URL.scheme isEqualToString:@"https"]); 
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    id<SentrySpan> span = SentrySDK.currentHub.scope.span;
    if (span == nil)
        return request;

    NSMutableURLRequest *newRequest = [request mutableCopy];
    [newRequest addValue:[span toTraceHeader].value forHTTPHeaderField:SENTRY_TRACE_HEADER];
    [NSURLProtocol setProperty:@YES forKey:SENTRY_INTERCEPTED_REQUEST inRequest:newRequest];
    return newRequest;
}

- (void)startLoading
{
    SentryURLSessionDemux *demux;
    NSURLSession* session;

    session = [_originalTask valueForKey:@"session"];

    if (session != nil) {
        demux = [[SentryURLSessionDemuxManager sharedInstance] demuxForSession:session];
        self->_originalDelegate = (id<NSURLSessionTaskDelegate>)session.delegate;
        self->_originalDelegateOperationQueue = session.delegateQueue;
    } else {
        demux = [[SentryURLSessionDemuxManager sharedInstance] defaultDemux];
    }

    self->_originalTask = nil;

    NSMutableArray *calculatedModes = [NSMutableArray array];
    [calculatedModes addObject:NSDefaultRunLoopMode];
    NSString *currentMode = [[NSRunLoop currentRunLoop] currentMode];
    if ( (currentMode != nil) && ! [currentMode isEqual:NSDefaultRunLoopMode] ) {
        [calculatedModes addObject:currentMode];
    }
    self.modes = calculatedModes;

    self.clientThread = [NSThread currentThread];

    self.currentTask = [demux dataTaskWithRequest:self.request delegate:self modes:calculatedModes];

    [self.currentTask resume];
}

- (void)stopLoading
{
    [self performSelector:@selector(completeLoading) onThread:self.clientThread withObject:NULL waitUntilDone:false modes:self.modes];
}

- (void)completeLoading
{
    [self.currentTask cancel];
}

#pragma mark - NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    if (error == nil) {
        return;
    }

    [self.client URLProtocol:self didFailWithError:error];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    // [rdar://21484589](https://openradar.appspot.com/21484589)
    // this is called from SentryURLSessionDemux,
    // which is called from the NSURLSession delegateQueue,
    // which is a different thread than self.clientThread.
    // It is possible that -stopLoading was called on self.clientThread
    // just before this method if so, ignore this callback
    if (self.currentTask == nil) {
        return;
    }

    [self.client URLProtocol:self wasRedirectedToRequest:request redirectResponse:response];
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error != nil) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

typedef void (^forward_to_delegate_challenge_handler_t)(void);
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    [self.client URLProtocol:self didReceiveAuthenticationChallenge:challenge];

    if (self.originalDelegate == nil || self.originalDelegateOperationQueue == nil) {
        NSURLProtectionSpace *space = challenge.protectionSpace;
        id<NSURLAuthenticationChallengeSender> sender = challenge.sender;

        if (space.authenticationMethod == NSURLAuthenticationMethodServerTrust) {
            if (space.serverTrust != nil) {
                NSURLCredential *credential = [[NSURLCredential alloc] initWithTrust:space.serverTrust];
                [sender useCredential:credential forAuthenticationChallenge:challenge];
                completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
                return;
            }
        }
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
        return;
    }

    id<NSURLSessionTaskDelegate> strongDelegate = self.originalDelegate;

    [self.originalDelegateOperationQueue addOperationWithBlock:^{
        [strongDelegate URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
    }];
}

@end
