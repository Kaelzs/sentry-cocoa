#import "SentryURLSessionDemuxManager.h"

@interface SentryURLSessionDemuxManager ()

@property (atomic, strong, readwrite) NSMutableDictionary *demuxBySessionObjectIdentifier;
@property (atomic, strong, readwrite) SentryURLSessionDemux *defaultDemux;

@end

@implementation SentryURLSessionDemuxManager

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        self->_demuxBySessionObjectIdentifier = [[NSMutableDictionary alloc] init];

        self->_defaultDemux = [[SentryURLSessionDemux alloc] initWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
    }
    return self;
}

+ (SentryURLSessionDemuxManager *)sharedInstance
{
    static SentryURLSessionDemuxManager *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{ sharedInstance = [[SentryURLSessionDemuxManager alloc] init]; });
    return sharedInstance;
}

- (SentryURLSessionDemux *)demuxForSession:(NSURLSession *)session
{
    id pointer = session;

    SentryURLSessionDemux *demux;

    @synchronized (self) {
        demux = _demuxBySessionObjectIdentifier[pointer];
    }

    if (demux != nil) {
        return demux;
    }

    demux = [[SentryURLSessionDemux alloc] initWithConfiguration:session.configuration];

    @synchronized (self) {
        _demuxBySessionObjectIdentifier[pointer] = demux;
    }

    return demux;
}

@end
