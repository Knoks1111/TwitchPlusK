#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSData *TPKVODEmotesTransform(NSData *data, NSURLRequest *request);
FOUNDATION_EXPORT BOOL TPKVODEmotesReceive(NSURLSessionDataTask *task, NSData *data, void (^flush)(NSData *));
FOUNDATION_EXPORT NSData *TPKVODEmotesComplete(NSURLSessionTask *task, NSError *error);
FOUNDATION_EXPORT void TPKVODEmotesTrack(NSURLSessionTask *task, NSURLRequest *request);
FOUNDATION_EXPORT void TPKVODEmotesNoteSession(NSURLSessionTask *task, NSURLSession *session);
