#import "SentryURLSessionDemux.h"

@interface SentrySessionDemuxTaskInfo : NSObject

typedef void (^forward_to_delegate_block_t)(id<NSURLSessionDataDelegate>);

- (instancetype)initWithTask:(NSURLSessionDataTask *)task delegate:(id<NSURLSessionDataDelegate>)delegate modes:(NSArray *)modes;

@property (atomic, strong) NSURLSessionDataTask *task;
@property (atomic, strong) id<NSURLSessionDataDelegate> delegate;
@property (atomic, strong) NSThread *thread;
@property (atomic, copy) NSArray *modes;

- (void)forwardToDelegate:(forward_to_delegate_block_t)block;

- (void)invalidate;

@end

@implementation SentrySessionDemuxTaskInfo

- (instancetype)initWithTask:(NSURLSessionDataTask *)task delegate:(id<NSURLSessionDataDelegate>)delegate modes:(NSArray *)modes
{
    self = [super init];
    if (self != nil) {
        self->_task = task;
        self->_delegate = delegate;
        self->_thread = [NSThread currentThread];
        self->_modes = [modes copy];
    }
    return self;
}

- (void)forwardToDelegate:(forward_to_delegate_block_t)block
{
    [self performSelector:@selector(_perform:) onThread:self.thread withObject:[block copy] waitUntilDone:NO modes:self.modes];
}

- (void)_perform:(forward_to_delegate_block_t)block
{
    if (self.delegate == nil) {
        return;
    }
    block(self.delegate);
}

- (void)invalidate
{
    self.delegate = nil;
    self.thread = nil;
}

@end

@interface SentryURLSessionDemux () <NSURLSessionDataDelegate>

@property (atomic, strong, readwrite) NSMutableDictionary *taskInfoByTaskID;
@property (atomic, strong, readonly) NSOperationQueue *sessionDelegateQueue;

@end

@implementation SentryURLSessionDemux

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration
{
    self = [super init];
    if (self != nil) {
        if (configuration == nil) {
            self->_configuration = [[NSURLSessionConfiguration defaultSessionConfiguration] copy];
        } else {
            self->_configuration = [configuration copy];
        }

        self->_taskInfoByTaskID = [[NSMutableDictionary alloc] init];

        self->_sessionDelegateQueue = [[NSOperationQueue alloc] init];
        [self->_sessionDelegateQueue setMaxConcurrentOperationCount:1];
        [self->_sessionDelegateQueue setName:@"SentryURLSessionDemux"];

        self->_session = [NSURLSession sessionWithConfiguration:self->_configuration delegate:self delegateQueue:self->_sessionDelegateQueue];
        self->_session.sessionDescription = @"SentryURLSessionDemux";
    }
    return self;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request delegate:(id<NSURLSessionDataDelegate>)delegate modes:(NSArray *)modes
{
    if ([modes count] == 0) {
        modes = @[NSDefaultRunLoopMode];
    }

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];

    SentrySessionDemuxTaskInfo *taskInfo = [[SentrySessionDemuxTaskInfo alloc] initWithTask:task delegate:delegate modes:modes];

    @synchronized (self) {
        self.taskInfoByTaskID[@(task.taskIdentifier)] = taskInfo;
    }

    return task;
}

- (SentrySessionDemuxTaskInfo *)taskInfoForTask:(NSURLSessionTask *)task
{
    SentrySessionDemuxTaskInfo *result;
    @synchronized (self) {
        result = self.taskInfoByTaskID[@(task.taskIdentifier)];
        assert(result != nil);
    }
    return result;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)newRequest completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:task];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session task:task willPerformHTTPRedirection:response newRequest:newRequest completionHandler:completionHandler];
        }];
    } else {
        completionHandler(newRequest);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:task];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
        }];
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:task];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:task:needNewBodyStream:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session task:task needNewBodyStream:completionHandler];
        }];
    } else {
        completionHandler(nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:task];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session task:task didSendBodyData:bytesSent totalBytesSent:totalBytesSent totalBytesExpectedToSend:totalBytesExpectedToSend];
        }];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:task];

    @synchronized (self) {
        [self.taskInfoByTaskID removeObjectForKey:@(taskInfo.task.taskIdentifier)];
    }

    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session task:task didCompleteWithError:error];
            [taskInfo invalidate];
        }];
    } else {
        [taskInfo invalidate];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:dataTask];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
        }];
    } else {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:dataTask];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:dataTask:didBecomeDownloadTask:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session dataTask:dataTask didBecomeDownloadTask:downloadTask];
        }];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:dataTask];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session dataTask:dataTask didReceiveData:data];
        }];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask willCacheResponse:(NSCachedURLResponse *)proposedResponse completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    SentrySessionDemuxTaskInfo *taskInfo = [self taskInfoForTask:dataTask];
    if ([taskInfo.delegate respondsToSelector:@selector(URLSession:dataTask:willCacheResponse:completionHandler:)]) {
        [taskInfo forwardToDelegate:^(id<NSURLSessionDataDelegate>delegate) {
            [delegate URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
        }];
    } else {
        completionHandler(proposedResponse);
    }
}

@end
