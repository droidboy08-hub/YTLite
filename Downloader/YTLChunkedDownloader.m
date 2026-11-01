#import "YTLChunkedDownloader.h"
#import "YTLStreamResolver.h"

// googlevideo throttles requests much larger than ~10 MiB (yt-dlp uses the same limit).
static const long long kYTLChunkSize = 8LL * 1024 * 1024;
static const NSUInteger kYTLMaxConcurrentChunks = 3;
static const NSUInteger kYTLMaxAttempts = 4;

@interface YTLDownloadChunk : NSObject
@property (nonatomic, assign) long long offset;
@property (nonatomic, assign) long long length;
@property (nonatomic, assign) NSUInteger attempts;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong, nullable) NSMutableData *data;
@end

@implementation YTLDownloadChunk
@end

@interface YTLChunkedDownloader () <NSURLSessionDataDelegate>
@end

// All mutable state is only touched on `_queue`, which is also the URL session's delegate queue.
@implementation YTLChunkedDownloader {
    NSURL *_URL;
    NSURL *_destination;
    NSString *_userAgent;
    long long _totalLength;
    NSOperationQueue *_queue;
    NSURLSession *_session;
    NSFileHandle *_fileHandle;
    NSMutableArray <YTLDownloadChunk *> *_pending;
    NSMutableDictionary <NSNumber *, YTLDownloadChunk *> *_active;
    long long _completedBytes;
    long long _nextOffset;
    BOOL _sequential;   // total size unknown: fetch chunk after chunk until a short one arrives
    BOOL _reachedEnd;
    BOOL _refreshing;
    BOOL _finished;
    CFAbsoluteTime _lastProgressReport;
    void (^_completion)(NSError *);
}

- (instancetype)initWithURL:(NSURL *)URL destination:(NSURL *)destination expectedLength:(long long)expectedLength userAgent:(NSString *)userAgent {
    self = [super init];
    if (self) {
        _URL = URL;
        _destination = destination;
        _userAgent = [userAgent copy];
        _totalLength = expectedLength;
        _pending = [NSMutableArray array];
        _active = [NSMutableDictionary dictionary];

        _queue = [NSOperationQueue new];
        _queue.maxConcurrentOperationCount = 1;
        _queue.name = @"com.dvntm.ytlite.download";

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPMaximumConnectionsPerHost = kYTLMaxConcurrentChunks;
        configuration.timeoutIntervalForRequest = 30;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_queue];
    }
    return self;
}

#pragma mark - Public

- (void)startWithCompletion:(void (^)(NSError *))completion {
    [_queue addOperationWithBlock:^{
        if (self->_completion || self->_finished) return;
        self->_completion = [completion copy];

        NSError *error = nil;
        [NSFileManager.defaultManager removeItemAtURL:self->_destination error:nil];
        if ([NSFileManager.defaultManager createFileAtPath:self->_destination.path contents:nil attributes:nil]) {
            self->_fileHandle = [NSFileHandle fileHandleForWritingToURL:self->_destination error:&error];
        }
        if (!self->_fileHandle) {
            [self finishWithError:error ?: [NSError errorWithDomain:YTLDownloaderErrorDomain code:YTLDownloaderErrorFile userInfo:nil]];
            return;
        }

        if (self->_totalLength > 0) [self scheduleChunks];
        else [self probeLengthAttempt:0];
    }];
}

- (void)cancel {
    [_queue addOperationWithBlock:^{
        [self finishWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    }];
}

#pragma mark - Scheduling

- (NSMutableURLRequest *)requestFrom:(long long)start to:(long long)end {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, end] forHTTPHeaderField:@"Range"];
    if (_userAgent.length) [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

// Some formats (e.g. muxed itag 18) come without contentLength: ask for one byte to learn the size.
- (void)probeLengthAttempt:(NSUInteger)attempt {
    [[_session dataTaskWithRequest:[self requestFrom:0 to:0] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (self->_finished) return;

        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *contentRange = status == 206 ? [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Range"] : nil;
        long long total = [[contentRange componentsSeparatedByString:@"/"].lastObject longLongValue];
        if (total > 0) {
            self->_totalLength = total;
            [self scheduleChunks];
        } else if ((status == 403 || status == 410) && self.URLRefresher && attempt + 1 < kYTLMaxAttempts) {
            [self refreshURLThen:^{
                [self probeLengthAttempt:attempt + 1];
            }];
        } else {
            self->_sequential = YES;
            [self pump];
        }
    }] resume];
}

- (void)scheduleChunks {
    for (long long offset = 0; offset < _totalLength; offset += kYTLChunkSize) {
        YTLDownloadChunk *chunk = [YTLDownloadChunk new];
        chunk.offset = offset;
        chunk.length = MIN(kYTLChunkSize, _totalLength - offset);
        [_pending addObject:chunk];
    }
    [self pump];
}

- (void)pump {
    if (_finished || _refreshing) return;

    NSUInteger limit = _sequential ? 1 : kYTLMaxConcurrentChunks;
    while (_active.count < limit) {
        YTLDownloadChunk *chunk = _pending.firstObject;
        if (chunk) {
            [_pending removeObjectAtIndex:0];
        } else if (_sequential && !_reachedEnd) {
            chunk = [YTLDownloadChunk new];
            chunk.offset = _nextOffset;
            chunk.length = kYTLChunkSize;
            _nextOffset += kYTLChunkSize;
        } else {
            break;
        }
        [self startChunk:chunk];
    }

    BOOL done = _active.count == 0 && _pending.count == 0 && (!_sequential || _reachedEnd);
    if (done) [self finishWithError:nil];
}

- (void)startChunk:(YTLDownloadChunk *)chunk {
    chunk.data = [NSMutableData dataWithCapacity:(NSUInteger)chunk.length];
    chunk.statusCode = 0;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:[self requestFrom:chunk.offset to:chunk.offset + chunk.length - 1]];
    _active[@(task.taskIdentifier)] = chunk;
    [task resume];
}

- (void)retryChunk:(YTLDownloadChunk *)chunk status:(NSInteger)status error:(NSError *)error {
    chunk.attempts += 1;
    chunk.data = nil;
    if (chunk.attempts >= kYTLMaxAttempts) {
        NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        [self finishWithError:error ?: [NSError errorWithDomain:YTLDownloaderErrorDomain code:YTLDownloaderErrorHTTP userInfo:@{NSLocalizedDescriptionKey: message}]];
        return;
    }
    [_pending insertObject:chunk atIndex:0];

    // 403/410 means the signed URL expired (they live a few hours): fetch a fresh one.
    BOOL expired = status == 403 || status == 410;
    if ((expired || chunk.attempts >= 2) && self.URLRefresher) {
        if (!_refreshing) [self refreshURLThen:nil];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * chunk.attempts * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self->_queue addOperationWithBlock:^{
            [self pump];
        }];
    });
}

- (void)refreshURLThen:(void (^)(void))then {
    _refreshing = YES;
    void (^refresher)(void (^)(NSURL *)) = self.URLRefresher;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        refresher(^(NSURL *freshURL) {
            [self->_queue addOperationWithBlock:^{
                self->_refreshing = NO;
                if (freshURL) self->_URL = freshURL;
                if (self->_finished) return;
                then ? then() : [self pump];
            }];
        });
    });
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    YTLDownloadChunk *chunk = _active[@(dataTask.taskIdentifier)];
    chunk.statusCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    YTLDownloadChunk *chunk = _active[@(dataTask.taskIdentifier)];
    if (chunk.statusCode != 206) return;
    [chunk.data appendData:data];
    [self reportProgress:NO];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key = @(task.taskIdentifier);
    YTLDownloadChunk *chunk = _active[key];
    if (!chunk) return;
    [_active removeObjectForKey:key];
    if (_finished) return;

    NSInteger status = chunk.statusCode;
    if (_sequential && status == 416) {
        // Requested past the end of a file whose size is a multiple of the chunk size.
        _reachedEnd = YES;
        [self pump];
        return;
    }

    long long received = (long long)chunk.data.length;
    BOOL complete = _sequential ? received > 0 : received == chunk.length;
    if (error || status != 206 || !complete) {
        [self retryChunk:chunk status:status error:error];
        return;
    }

    NSError *writeError = nil;
    if (![_fileHandle seekToOffset:(unsigned long long)chunk.offset error:&writeError] || ![_fileHandle writeData:chunk.data error:&writeError]) {
        [self finishWithError:writeError];
        return;
    }

    _completedBytes += received;
    if (_sequential && received < chunk.length) _reachedEnd = YES;
    chunk.data = nil;
    [self reportProgress:NO];
    [self pump];
}

#pragma mark - Completion

- (void)reportProgress:(BOOL)force {
    void (^handler)(long long, long long) = self.progressHandler;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!handler || (!force && now - _lastProgressReport < 0.1)) return;
    _lastProgressReport = now;

    long long received = _completedBytes;
    for (YTLDownloadChunk *chunk in _active.allValues) received += (long long)chunk.data.length;
    long long total = _totalLength > 0 ? _totalLength : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(received, total);
    });
}

- (void)finishWithError:(NSError *)error {
    if (_finished) return;
    _finished = YES;

    // Invalidating also releases the session's strong reference to its delegate (self).
    [_session invalidateAndCancel];
    [_fileHandle closeAndReturnError:nil];
    _fileHandle = nil;
    [_pending removeAllObjects];
    [_active removeAllObjects];

    if (!error) [self reportProgress:YES];
    void (^completion)(NSError *) = _completion;
    _completion = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    }
}

@end
