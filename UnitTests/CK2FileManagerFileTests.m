//
//  Created by Sam Deane on 06/11/2012.
//  Copyright 2012 Karelia Software. All rights reserved.
//

#import "CK2FileManagerBaseTests.h"
#import "KMSServer.h"

#import "CK2FileManager.h"
#import <SenTestingKit/SenTestingKit.h>
#import <curl/curl.h>

@interface CK2FileManagerFileTests : CK2FileManagerBaseTests

@end

@implementation CK2FileManagerFileTests

- (NSURL*)temporaryFolder
{
    NSURL* result = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"CK2FileManagerFileTests"];

    return result;
}

- (void)removeTemporaryFolder
{
    NSError* error = nil;
    NSURL* tempFolder = [self temporaryFolder];
    NSFileManager* fm = [NSFileManager defaultManager];

    NSMutableArray* contents = [NSMutableArray array];
    NSDirectoryEnumerator* enumerator = [fm enumeratorAtURL:tempFolder includingPropertiesForKeys:nil options:0 errorHandler:nil];
    for (NSURL* url in enumerator)
    {
        [contents addObject:url];
    }
    for (NSURL* url in contents)
    {
        [fm removeItemAtURL:url error:&error];
    }
    [fm removeItemAtURL:tempFolder error:&error];
}

- (BOOL)makeTemporaryFolder
{
    NSError* error = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* tempFolder = [self temporaryFolder];
    BOOL ok = [fm createDirectoryAtURL:tempFolder withIntermediateDirectories:YES attributes:nil error:&error];
    STAssertTrue(ok, @"couldn't make temporary directory: %@", error);

    return ok;
}

- (BOOL)makeTestContents
{
    BOOL ok;
    NSError* error = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* tempFolder = [self temporaryFolder];
    NSURL* testSubfolder = [tempFolder URLByAppendingPathComponent:@"subfolder"];

    NSURL* testFile = [tempFolder URLByAppendingPathComponent:@"test.txt"];
    ok = [@"Some test text" writeToURL:testFile atomically:YES encoding:NSUTF8StringEncoding error:&error];
    STAssertTrue(ok, @"couldn't make test file: %@", error);

    if (ok)
    {
        ok = [fm createDirectoryAtURL:testSubfolder withIntermediateDirectories:YES attributes:nil error:&error];
        STAssertTrue(ok, @"couldn't make test subdirectory: %@", error);
    }

    if (ok)
    {
        NSURL* otherFile = [testSubfolder URLByAppendingPathComponent:@"another.txt"];
        ok = [@"Some more text" writeToURL:otherFile atomically:YES encoding:NSUTF8StringEncoding error:&error];
        STAssertTrue(ok, @"couldn't make other test file: %@", error);
    }

    return ok;
}

- (void)setUp
{
    [self removeTemporaryFolder];
    [self makeTemporaryFolder];
}

- (void)tearDown
{
    [super tearDown];
    [self removeTemporaryFolder];
}

#pragma mark - Tests

- (void)testContentsOfDirectoryAtURL
{
    if ([self setupSession])
    {
        if ([self makeTestContents])
        {
            NSURL* url = [self temporaryFolder];
            NSDirectoryEnumerationOptions options = NSDirectoryEnumerationSkipsSubdirectoryDescendants;
            [self.session contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:options completionHandler:^(NSArray *contents, NSError *error) {

                if (error)
                {
                    STFail(@"got error %@", error);
                }
                else
                {
                    NSUInteger count = [contents count];
                    STAssertTrue(count == 2, @"should have two results");
                    if (count == 2)
                    {
                        STAssertTrue([[contents[0] lastPathComponent] isEqual:@"subfolder"], @"got %@", contents[0]);
                        STAssertTrue([[contents[1] lastPathComponent] isEqual:@"test.txt"], @"got %@", contents[1]);
                    }
                }
                
                [self pause];
            }];
            
            [self runUntilPaused];
        }
    }
}

- (void)testEnumerateContentsOfDirectoryAtURL
{
    if ([self setupSession])
    {
        if ([self makeTestContents])
        {
            NSMutableArray* expected = [@[ @"CK2FileManagerFileTests", @"test.txt", @"subfolder" ] mutableCopy];
            NSURL* url = [self temporaryFolder];
            NSDirectoryEnumerationOptions options = NSDirectoryEnumerationSkipsSubdirectoryDescendants;
            [self.session enumerateContentsOfURL:url includingPropertiesForKeys:nil options:options usingBlock:^(NSURL *url) {

                NSString* name = [url lastPathComponent];
                STAssertTrue([expected containsObject:name], @"unexpected name %@", name);
                [expected removeObject:name];

            } completionHandler:^(NSError *error) {
                STAssertNil(error, @"got unexpected error %@", error);
                [self pause];
            }];

            [self runUntilPaused];

            STAssertTrue([expected count] == 0, @"shouldn't have any items left");
            [expected release];
        }
    }
}

- (void)testCreateDirectoryAtURL
{
    if ([self setupSession])
    {
        NSFileManager* fm = [NSFileManager defaultManager];
        NSURL* temp = [self temporaryFolder];
        NSURL* directory = [temp URLByAppendingPathComponent:@"directory"];
        NSURL* subdirectory = [directory URLByAppendingPathComponent:@"subdirectory"];
        NSError* error = nil;

        [fm removeItemAtURL:subdirectory error:&error];
        [fm removeItemAtURL:directory error:&error];

        // try to make subdirectory with intermediate directory - should fail
        [self.session createDirectoryAtURL:subdirectory withIntermediateDirectories:NO openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"expected an error here");
            STAssertEquals([error code], (NSInteger) NSFileNoSuchFileError, @"unexpected error code %ld", [error code]);

            [self pause];
        }];

        [self runUntilPaused];
        STAssertFalse([fm fileExistsAtPath:[subdirectory path]], @"directory shouldn't exist");

        // try to make subdirectory
        [self.session createDirectoryAtURL:subdirectory withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);

            [self pause];
        }];

        [self runUntilPaused];


        BOOL isDir = NO;
        STAssertTrue([fm fileExistsAtPath:[subdirectory path] isDirectory:&isDir], @"directory doesn't exist");
        STAssertTrue(isDir, @"somehow we've ended up with a file not a directory");

        // try to make it again - should quietly work
        [self.session createDirectoryAtURL:subdirectory withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);

            [self pause];
        }];

        [self runUntilPaused];
        STAssertTrue([fm fileExistsAtPath:[subdirectory path] isDirectory:&isDir], @"directory doesn't exist");
        STAssertTrue(isDir, @"somehow we've ended up with a file not a directory");
    }
}

- (void)testCreateDirectoryAtURLNoPermission
{
    if ([self setupSession])
    {
        NSFileManager* fm = [NSFileManager defaultManager];
        NSURL* url = [NSURL fileURLWithPath:@"/System/Test Directory"];

        // try to make subdirectory in /System - this really ought to fail
        [self.session createDirectoryAtURL:url withIntermediateDirectories:NO openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"expected an error here");
            STAssertEquals([error code], (NSInteger) NSFileWriteNoPermissionError, @"unexpected error code %ld", [error code]);

            [self pause];
        }];

        [self runUntilPaused];
        STAssertFalse([fm fileExistsAtPath:[url path]], @"directory shouldn't exist");
    }
}
#if 0 // TODO: rewrite these tests for the file protocol


- (void)testCreateDirectoryAtURLAlreadyExists
{
    if ([self setupSessionWithRealURL:[NSURL URLWithString:@"ftp://ftp.test.com"] fakeResponses:@"ftp"])
    {
        [self useResponseSet:@"mkdir fail"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/newdirectory"];
        [self.session createDirectoryAtURL:url withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"should get error");
            long ftpCode = [[[error userInfo] objectForKey:@(CURLINFO_RESPONSE_CODE)] longValue];
            STAssertTrue(ftpCode == 550, @"should get 550 from server");

            [self pause];
        }];
    }

    [self runUntilPaused];
}

- (void)testCreateDirectoryAtURLBadLogin
{
    if ([self setup])
    {
        [self useResponseSet:@"bad login"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/newdirectory"];
        [self.session createDirectoryAtURL:url withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"should get error");
            STAssertTrue([[error domain] isEqualToString:NSURLErrorDomain] && ([error code] == NSURLErrorUserAuthenticationRequired || [error code] == NSURLErrorUserCancelledAuthentication), @"should get authentication error, got %@ instead", error);

            [self pause];
        }];

        [self runUntilPaused];
    }
}

- (void)testCreateFileAtURL
{
    if ([self setup])
    {
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSData* data = [@"Some test text" dataUsingEncoding:NSUTF8StringEncoding];
        [self.session createFileAtURL:url contents:data withIntermediateDirectories:YES openingAttributes:nil progressBlock:^(NSUInteger bytesWritten, NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);

            if (bytesWritten == 0)
            {
                [self pause];
            }
        }];

        [self runUntilPaused];
    }
}

- (void)testCreateFileAtURL2
{
    if ([self setup])
    {
        NSURL* temp = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        NSURL* source = [temp URLByAppendingPathComponent:@"test.txt"];
        NSError* error = nil;
        STAssertTrue([@"Some test text" writeToURL:source atomically:YES encoding:NSUTF8StringEncoding error:&error], @"failed to write temporary file with error %@", error);

        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];

        [self.session createFileAtURL:url withContentsOfURL:source withIntermediateDirectories:YES openingAttributes:nil progressBlock:^(NSUInteger bytesWritten, NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);

            if (bytesWritten == 0)
            {
                [self pause];
            }
        }];

        [self runUntilPaused];

        STAssertTrue([[NSFileManager defaultManager] removeItemAtURL:source error:&error], @"failed to remove temporary file with error %@", error);
    }
}

- (void)testRemoveFileAtURL
{
    if ([self setup])
    {
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        [self.session removeFileAtURL:url completionHandler:^(NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);
            [self pause];
        }];
    }

    [self runUntilPaused];
}

- (void)testRemoveFileAtURLFileDoesnExist
{
    if ([self setup])
    {
        [self useResponseSet:@"delete fail"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        [self.session removeFileAtURL:url completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"should get error");
            long ftpCode = [[[error userInfo] objectForKey:@(CURLINFO_RESPONSE_CODE)] longValue];
            STAssertTrue(ftpCode == 550, @"should get 550 from server");

            [self pause];
        }];

        [self runUntilPaused];
    }

}

- (void)testRemoveFileAtURLBadLogin
{
    if ([self setup])
    {
        [self useResponseSet:@"bad login"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        [self.session removeFileAtURL:url completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"should get error");
            STAssertTrue([[error domain] isEqualToString:NSURLErrorDomain] && ([error code] == NSURLErrorUserAuthenticationRequired || [error code] == NSURLErrorUserCancelledAuthentication), @"should get authentication error, got %@ instead", error);

            [self pause];
        }];

        [self runUntilPaused];
    }
}

- (void)testSetUnknownAttributes
{
    if ([self setup])
    {
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSDictionary* values = @{ @"test" : @"test" };
        [self.session setAttributes:values ofItemAtURL:url completionHandler:^(NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);
            [self pause];
        }];

        [self runUntilPaused];
    }


    //// Only NSFilePosixPermissions is recognised at present. Note that some servers don't support this so will return an error (code 500)
    //// All other attributes are ignored
    //- (void)setResourceValues:(NSDictionary *)keyedValues ofItemAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;

}

- (void)testSetAttributes
{
    if ([self setup])
    {
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSDictionary* values = @{ NSFilePosixPermissions : @(0744)};
        [self.session setAttributes:values ofItemAtURL:url completionHandler:^(NSError *error) {
            STAssertNil(error, @"got unexpected error %@", error);
            [self pause];
        }];

        [self runUntilPaused];
    }


    //// Only NSFilePosixPermissions is recognised at present. Note that some servers don't support this so will return an error (code 500)
    //// All other attributes are ignored
    //- (void)setResourceValues:(NSDictionary *)keyedValues ofItemAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;

}

- (void)testSetAttributesCHMODNotUnderstood
{
    if ([self setup])
    {
        [self useResponseSet:@"chmod not understood"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSDictionary* values = @{ NSFilePosixPermissions : @(0744)};
        [self.session setAttributes:values ofItemAtURL:url completionHandler:^(NSError *error) {
            // For servers which don't understand or support CHMOD, treat as success, like -[NSURL setResourceValue:forKey:error:] does
            STAssertNil(error, @"got unexpected error %@", error);
            [self pause];
        }];

        [self runUntilPaused];
    }
}

- (void)testSetAttributesCHMODUnsupported
{
    if ([self setup])
    {
        [self useResponseSet:@"chmod unsupported"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSDictionary* values = @{ NSFilePosixPermissions : @(0744)};
        [self.session setAttributes:values ofItemAtURL:url completionHandler:^(NSError *error) {
            // For servers which don't understand or support CHMOD, treat as success, like -[NSURL setResourceValue:forKey:error:] does
            STAssertNil(error, @"got unexpected error %@", error);
            [self pause];
        }];

        [self runUntilPaused];
    }
}

- (void)testSetAttributesOperationNotPermitted
{
    if ([self setup])
    {
        [self useResponseSet:@"chmod not permitted"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/test.txt"];
        NSDictionary* values = @{ NSFilePosixPermissions : @(0744)};
        [self.session setAttributes:values ofItemAtURL:url completionHandler:^(NSError *error) {
            // For servers which don't understand or support CHMOD, treat as success, like -[NSURL setResourceValue:forKey:error:] does
            STAssertTrue([[error domain] isEqualToString:NSCocoaErrorDomain] && ([error code] == NSFileWriteUnknownError || // FTP has no hard way to know it was a permissions error
                                                                                 [error code] == NSFileWriteNoPermissionError),
                         @"should get error");
            [self pause];
        }];

        [self runUntilPaused];
    }
}

- (void)testBadLoginThenGoodLogin
{
    if ([self setup])
    {
        [self useResponseSet:@"bad login"];
        NSURL* url = [self URLForPath:@"/directory/intermediate/newdirectory"];
        [self.session createDirectoryAtURL:url withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
            STAssertNotNil(error, @"should get error");
            STAssertTrue([[error domain] isEqualToString:NSURLErrorDomain] && ([error code] == NSURLErrorUserAuthenticationRequired || [error code] == NSURLErrorUserCancelledAuthentication), @"should get authentication error, got %@ instead", error);

            [self.server pause];

            [self useResponseSet:@"default"];
            [self.session createDirectoryAtURL:url withIntermediateDirectories:YES openingAttributes:nil completionHandler:^(NSError *error) {
                STAssertNil(error, @"got unexpected error %@", error);
                
                [self.server pause];
            }];
        }];
    }
    
    [self runUntilPaused];
}

#endif

@end

