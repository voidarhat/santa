/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "SNTCommandSyncLogUpload.h"

#include "SNTCommonEnums.h"
#include "SNTLogging.h"

#import "SNTCommandSyncStatus.h"


@implementation SNTCommandSyncLogUpload

+ (void)performSyncInSession:(NSURLSession *)session
                    progress:(SNTCommandSyncStatus *)progress
                  daemonConn:(SNTXPCConnection *)daemonConn
           completionHandler:(void (^)(BOOL success))handler {
  NSURL *url = progress.uploadLogURL;
  NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
  [req setHTTPMethod:@"POST"];
  NSString *boundary = @"santa-sync-upload-boundary";

  NSString *contentType =
      [NSString stringWithFormat:@"multipart/form-data; charset=UTF-8; boundary=%@", boundary];
  [req setValue:contentType forHTTPHeaderField:@"Content-Type"];

  // General logs
  NSMutableArray *logsToUpload = [@[ @"/var/log/santa.log",
                                     @"/var/log/system.log" ] mutableCopy];

  // Kernel Panics, santad & santactl crashes
  NSString *diagsDir = @"/Library/Logs/DiagnosticReports/";
  NSDirectoryEnumerator *dirEnum = [[NSFileManager defaultManager] enumeratorAtPath:diagsDir];
  NSString *file;
  while (file = [dirEnum nextObject]) {
    if ([[file pathExtension] isEqualToString: @"panic"] ||
        [file hasPrefix:@"santad"] ||
        [file hasPrefix:@"santactl"]) {
      [logsToUpload addObject:[diagsDir stringByAppendingString:file]];
    }
  }

  // Prepare the body of the request, encoded as a multipart/form-data.
  // Along the way, gzip the individual log files (they'll be stored in blobstore gzipped, which is
  // what we want) and append .gz to their filenames.
  NSMutableData *reqBody = [[NSMutableData alloc] init];
  for (NSString *log in logsToUpload) {
    [reqBody appendData:
        [[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [reqBody appendData:
        [[NSString stringWithFormat:@"Content-Disposition: multipart/form-data; "
            @"name=\"files\"; "
            @"filename=\"%@.gz\"\r\n", [log lastPathComponent]]
         dataUsingEncoding:NSUTF8StringEncoding]];
    [reqBody appendData:
        [@"Content-Type: application/x-gzip\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [reqBody appendData:[NSData dataWithContentsOfFile:log]];
    [reqBody appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  }
  [reqBody appendData:
     [[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

  // Upload the logs
  [[session uploadTaskWithRequest:req
                         fromData:reqBody
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if ([(NSHTTPURLResponse *)response statusCode] != 200) {
                      LOGD(@"HTTP Response Code: %d", [(NSHTTPURLResponse *)response statusCode]);
                      handler(NO);
                    } else {
                      LOGI(@"Uploaded %d logs", [logsToUpload count]);
                      handler(YES);
                    }
                }] resume];
}

@end
