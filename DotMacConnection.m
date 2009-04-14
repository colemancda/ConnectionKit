/*
 Copyright (c) 2004-2006 Karelia Software. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, 
 are permitted provided that the following conditions are met:
 
 
 Redistributions of source code must retain the above copyright notice, this list 
 of conditions and the following disclaimer.
 
 Redistributions in binary form must reproduce the above copyright notice, this 
 list of conditions and the following disclaimer in the documentation and/or other 
 materials provided with the distribution.
 
 Neither the name of Karelia Software nor the names of its contributors may be used to 
 endorse or promote products derived from this software without specific prior 
 written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY 
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
 OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT 
 SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED 
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
 BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY 
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

#import "DotMacConnection.h"
#import "AbstractConnection.h"
#import "DAVDirectoryContentsRequest.h"
#import "DAVCreateDirectoryRequest.h"
#import "DAVUploadFileRequest.h"
#import "DAVDeleteRequest.h"
#import "DAVResponse.h"
#import "DAVDirectoryContentsResponse.h"
#import "DAVCreateDirectoryResponse.h"
#import "DAVUploadFileResponse.h"
#import "DAVDeleteResponse.h"
#import "NSData+Connection.h"
#import <Security/Security.h>
#import "ConnectionThreadManager.h"
#import "NSString+Connection.h"
#import "CKInternalTransferRecord.h"
#import "CKTransferRecord.h"

@interface WebDAVConnection (DotMac)
- (void)processResponse:(DAVResponse *)response;
- (void)processFileCheckingQueue;
@end

@implementation DotMacConnection

#pragma mark class methods

+ (void)load	// registration of this class
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSDictionary *port = [NSDictionary dictionaryWithObjectsAndKeys:@"80", ACTypeValueKey, ACPortTypeKey, ACTypeKey, nil];
	NSDictionary *url = [NSDictionary dictionaryWithObjectsAndKeys:@"http://", ACTypeValueKey, ACURLTypeKey, ACTypeKey, nil];
	[AbstractConnection registerConnectionClass:[DotMacConnection class] forTypes:[NSArray arrayWithObjects:port, url, nil]];
	[pool release];
}

+ (NSString *)name
{
	return @"MobileMe";
}

+ (id)connectionToHost:(NSString *)host
				  port:(NSString *)port
			  username:(NSString *)username
			  password:(NSString *)password
				 error:(NSError **)error
{
	DotMacConnection *c = [[self alloc] initWithHost:host
                                                port:port
                                            username:username
                                            password:password
											   error:error];
	return [c autorelease];
}

+ (NSString *)urlScheme
{
	return @"dotmac";
}

#pragma mark init methods

- (BOOL)getDotMacAccountName:(NSString **)account password:(NSString **)password
{
	BOOL result = NO;
	
	NSString *accountName = [[NSUserDefaults standardUserDefaults] objectForKey:@"iToolsMember"];
	if (accountName)
	{
		SecKeychainItemRef item = nil;
		OSStatus theStatus = noErr;
		char *buffer;
		UInt32 passwordLen;
		
		char *utf8 = (char *)[accountName UTF8String];
		theStatus = SecKeychainFindGenericPassword(NULL,
												   6,
												   "iTools",
												   strlen(utf8),
												   utf8,
												   &passwordLen,
												   (void *)&buffer,
												   &item);
		
		if (noErr == theStatus)
		{
			if (passwordLen > 0)
			{
				*password = [[[NSString alloc] initWithBytes:buffer length:passwordLen encoding:[NSString defaultCStringEncoding]] autorelease];
			}
			else
			{
				*password = @""; // if we have noErr but also no length, password is empty
			}

			// release buffer allocated by SecKeychainFindGenericPassword
			(void) SecKeychainItemFreeContent(NULL, buffer);
			
			*account = accountName;
			result = YES;
		}
	}
	
	return result;
}

- (id)initWithHost:(NSString *)host
              port:(NSString *)port
          username:(NSString *)user
          password:(NSString *)pass
             error:(NSError **)error
{
	NSString *username = nil;
	NSString *password = nil;
	
	if (user && password)
	{
		if (self = [super initWithHost:@"idisk.mac.com" port:@"80" username:user password:pass error:error])
		{
			myCurrentDirectory = [[NSString stringWithFormat:@"/%@/", user] retain];
		}
	}
	else
	{
		if (![self getDotMacAccountName:&username password:&password])
		{
			if (error)
			{
				NSError *err = [NSError errorWithDomain:WebDAVErrorDomain
												   code:ConnectionNoUsernameOrPassword
											   userInfo:[NSDictionary dictionaryWithObject:LocalizedStringInConnectionKitBundle(@"Failed to retrieve MobileMe account details", @"No MobileMe account or password")
																					forKey:NSLocalizedDescriptionKey]];
				*error = err;
			}
			[self release];
			return nil;
		}
		
		if (self = [super initWithHost:@"idisk.mac.com" port:@"80" username:username password:password error:error])
		{
			myCurrentDirectory = [[NSString stringWithFormat:@"/%@/", username] retain];
		}
	}

	return self;
}

#pragma mark -
#pragma mark WebDAV Overrides

- (void)processResponse:(DAVResponse *)response
{
	KTLog(ProtocolDomain, KTLogDebug, @"%@", response);
	switch (GET_STATE)
	{
		case ConnectionAwaitingDirectoryContentsState:
		{
			DAVDirectoryContentsResponse *dav = (DAVDirectoryContentsResponse *)response;
			NSString *err = nil;
			switch ([dav code])
			{
				case 200:
				case 207: //multi-status
				{
					if (_flags.directoryContents)
					{
						NSArray *contents = [dav directoryContents];
						[self cacheDirectory:[dav path] withContents:contents];
						[_forwarder connection:self 
							didReceiveContents:contents
								   ofDirectory:[[dav path] stringByDeletingFirstPathComponent]];
					}
					break;
				}
				case 404:
				{		
					err = [NSString stringWithFormat:@"%@: %@", LocalizedStringInConnectionKitBundle(@"There is no MobileMe access to the directory", @"MobileMe Directory Contents Error"), [dav path]];
					break;
				}
				default: 
				{
					err = @"Unknown Error Occurred";
				}
			}
			if (err)
			{
				if (_flags.error)
				{
					NSMutableDictionary *ui = [NSMutableDictionary dictionaryWithObject:err forKey:NSLocalizedDescriptionKey];
					[ui setObject:[dav className] forKey:@"DAVResponseClass"];
					NSError *error = [NSError errorWithDomain:WebDAVErrorDomain
														 code:[dav code]
													 userInfo:ui];
					[_forwarder connection:self didReceiveError:error];
				}
			}				
			[self setState:ConnectionIdleState];
			break;
		}
		case ConnectionCreateDirectoryState:
		{
			DAVCreateDirectoryResponse *dav = (DAVCreateDirectoryResponse *)response;
			NSString *err = nil;
			NSMutableDictionary *ui = [NSMutableDictionary dictionary];
			
			switch ([dav code])
			{
				case 201: 
				{
					if (_flags.createDirectory)
					{
						[_forwarder connection:self 
							didCreateDirectory:[[dav directory] stringByDeletingFirstPathComponent]];
					}
					break;
				}
				case 403:
				{		
					err = LocalizedStringInConnectionKitBundle(@"The server does not allow the creation of directories at the current location", @"MobileMe Create Directory Error");
						//we fake the directory exists as this is usually the case if it is the root directory
					[ui setObject:[NSNumber numberWithBool:YES] forKey:ConnectionDirectoryExistsKey];
					break;
				}
				case 405:
				{		
					if (_flags.isRecursiveUploading)
					{
						err = LocalizedStringInConnectionKitBundle(@"The directory already exists", @"MobileMe Create Directory Error");
						[ui setObject:[NSNumber numberWithBool:YES] forKey:ConnectionDirectoryExistsKey];
					}
					break;
				}
				case 409:
				{
					err = LocalizedStringInConnectionKitBundle(@"An intermediate directory does not exist and needs to be created before the current directory", @"MobileMe Create Directory Error");
					break;
				}
				case 415:
				{
					err = LocalizedStringInConnectionKitBundle(@"The body of the request is not supported", @"MobileMe Create Directory Error");
					break;
				}
				case 507:
				{
					err = LocalizedStringInConnectionKitBundle(@"Insufficient storage space available", @"MobileMe Create Directory Error");
					break;
				}
				default: 
				{
					err = LocalizedStringInConnectionKitBundle(@"An unknown error occured", @"MobileMe Create Directory Error");
					break;
				}
			}
			if (err)
			{
				if (_flags.error)
				{
					[ui setObject:err forKey:NSLocalizedDescriptionKey];
					[ui setObject:[dav className] forKey:@"DAVResponseClass"];
					[ui setObject:[[dav request] description] forKey:@"DAVRequest"];
					[ui setObject:[(DAVCreateDirectoryRequest *)[dav request] path] forKey:@"directory"];
					NSError *error = [NSError errorWithDomain:WebDAVErrorDomain
														 code:[dav code]
													 userInfo:ui];
					[_forwarder connection:self didReceiveError:error];
				}
			}
			[self setState:ConnectionIdleState];
			break;
		}
		case ConnectionUploadingFileState:
		{
			DAVUploadFileResponse *dav = (DAVUploadFileResponse *)response;
			switch ([dav code])
			{
				case 200:
				case 201:
				case 204:
				{
					if (_flags.uploadFinished)
					{
						[_forwarder connection:self
							   uploadDidFinish:[[self currentUpload] remotePath]];
					}
					break;
				}
				case 409:
				{		
					if (_flags.error)
					{
						NSMutableDictionary *ui = [NSMutableDictionary dictionaryWithObject:LocalizedStringInConnectionKitBundle(@"Parent Folder does not exist", @"MobileMe File Uploading Error")
																					 forKey:NSLocalizedDescriptionKey];
						[ui setObject:[dav className] forKey:@"DAVResponseClass"];
						
						NSError *err = [NSError errorWithDomain:WebDAVErrorDomain
														   code:[dav code]
													   userInfo:ui];
						[_forwarder connection:self didReceiveError:err];
					}
				}
					break;
			}
			[self dequeueUpload];
			[self setState:ConnectionIdleState];
			break;
		}
		case ConnectionDeleteFileState:
		{
			DAVDeleteResponse *dav = (DAVDeleteResponse *)response;
			switch ([dav code])
			{
				case 200:
				case 201:
				case 204:
				{
					if (_flags.deleteFile)
					{
						[_forwarder connection:self 
								 didDeleteFile:[[self currentDeletion] stringByDeletingFirstPathComponent]];
					}
					break;
				}
				default:
				{
					if (_flags.error)
					{
						NSMutableDictionary *ui = [NSMutableDictionary dictionary];
						[ui setObject:[NSString stringWithFormat:@"%@: %@", LocalizedStringInConnectionKitBundle(@"Failed to delete file", @"MobileMe file deletion error"), [[self currentDeletion] stringByDeletingFirstPathComponent]] forKey:NSLocalizedDescriptionKey];
						[ui setObject:[[dav request] description] forKey:@"DAVRequest"];
						[ui setObject:[dav className] forKey:@"DAVResponseClass"];
						
						NSError *err = [NSError errorWithDomain:WebDAVErrorDomain
														   code:[dav code]
													   userInfo:ui];
						[_forwarder connection:self didReceiveError:err];
					}
				}
			}
			[self dequeueDeletion];
			[self setState:ConnectionIdleState];
			break;
		}
		case ConnectionDeleteDirectoryState:
		{
			DAVDeleteResponse *dav = (DAVDeleteResponse *)response;
			switch ([dav code])
			{
				case 200:
				case 201:
				case 204:
				{
					if (_flags.deleteDirectory)
					{
						[_forwarder connection:self 
							didDeleteDirectory:[[self currentDeletion] stringByDeletingFirstPathComponent]];
					}
					break;
				}
				default:
				{
					if (_flags.error)
					{
						NSMutableDictionary *ui = [NSMutableDictionary dictionary];
						[ui setObject:[NSString stringWithFormat:@"%@: %@", LocalizedStringInConnectionKitBundle(@"Failed to delete directory", @"MobileMe Directory Deletion Error"), [[self currentDeletion] stringByDeletingFirstPathComponent]] 
							   forKey:NSLocalizedDescriptionKey];
						[ui setObject:[[dav request] description] forKey:@"DAVRequest"];
						[ui setObject:[dav className] forKey:@"DAVResponseClass"];
						
						NSError *err = [NSError errorWithDomain:WebDAVErrorDomain
														   code:[dav code]
													   userInfo:ui];
						[_forwarder connection:self didReceiveError:err];
					}
				}
			}
			[self dequeueDeletion];
			[self setState:ConnectionIdleState];
			break;
		}
		default: [super processResponse:response];
	}
}

- (void)stream:(id<OutputStream>)stream readBytesOfLength:(unsigned)length
{
	if (length == 0) return;
	if (GET_STATE == ConnectionDownloadingFileState)
	{
		CKInternalTransferRecord *download = [self currentDownload];
		bytesTransferred += length;
		if (bytesToTransfer > 0) // intel gives a crash for div by 0
		{
			int percent = (bytesTransferred * 100) / bytesToTransfer;
			
			if (_flags.downloadPercent)
			{
				[_forwarder connection:self 
							  download:[[download remotePath] stringByDeletingFirstPathComponent]
						  progressedTo:[NSNumber numberWithInt:percent]];
			}
			
			if ([download delegateRespondsToTransferProgressedTo])
			{
				[[download delegate] transfer:[download userInfo] progressedTo:[NSNumber numberWithInt:percent]];
			}
		}
		
		
		if (_flags.downloadProgressed)
		{
			[_forwarder connection:self
						  download:[[download remotePath] stringByDeletingFirstPathComponent]
			  receivedDataOfLength:length];
		}
		if ([download delegateRespondsToTransferTransferredData])
		{
			[[download delegate] transfer:[download userInfo] transferredDataOfLength:length];
		}
	}
}

- (void)stream:(id<OutputStream>)stream sentBytesOfLength:(unsigned)length
{
	if (length == 0) return;
	if (GET_STATE == ConnectionUploadingFileState)
	{
		if (transferHeaderLength > 0)
		{
			if (length <= transferHeaderLength)
			{
				transferHeaderLength -= length;
			}
			else
			{
				length -= transferHeaderLength;
				transferHeaderLength = 0;
				bytesTransferred += length;
			}
		}
		else
		{
			bytesTransferred += length;
		}
		
		CKInternalTransferRecord *upload = [self currentUpload];
		
		if (bytesToTransfer > 0) // intel gives a crash for div by 0
		{
			int percent = (bytesTransferred * 100) / bytesToTransfer;
			if (_flags.uploadPercent)
			{
				[_forwarder connection:self 
								upload:[upload remotePath]
						  progressedTo:[NSNumber numberWithInt:percent]];
			}
			if ([upload delegateRespondsToTransferProgressedTo])
			{
				[[upload delegate] transfer:[upload userInfo] progressedTo:[NSNumber numberWithInt:percent]];
			}
		}
		if (_flags.uploadProgressed)
		{
			[_forwarder connection:self 
							upload:[upload remotePath]
				  sentDataOfLength:length];
		}
		if ([upload delegateRespondsToTransferTransferredData])
		{
			[[upload delegate] transfer:[upload userInfo] transferredDataOfLength:length];
		}
	}
}

#pragma mark -
#pragma mark Protocol Overrides

- (void)changeToDirectory:(NSString *)dirPath
{
	[super changeToDirectory:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:dirPath]];
}

- (void)davDidChangeToDirectory:(NSString *)dirPath
{
	[myCurrentDirectory autorelease];
	myCurrentDirectory = [dirPath copy];
	if (_flags.changeDirectory)
	{
		[_forwarder connection:self didChangeToDirectory:[dirPath stringByDeletingFirstPathComponent]];
	}
	[myCurrentRequest release];
	myCurrentRequest = nil;
	[self setState:ConnectionIdleState];
}

- (NSString *)currentDirectory
{
	return [[super currentDirectory] stringByDeletingFirstPathComponent];
}

- (NSDictionary *)currentDownload
{
	CKInternalTransferRecord *returnValue = [[super currentDownload] copy];
	
	[returnValue setRemotePath:[[returnValue remotePath] stringByDeletingFirstPathComponent]];
	
	return [returnValue autorelease];
}

- (CKInternalTransferRecord *)currentUpload
{
	CKInternalTransferRecord *returnValue = [[super currentUpload] copy];
  
	[returnValue setRemotePath:[[returnValue remotePath] stringByDeletingFirstPathComponent]];
  
	return [returnValue autorelease];
}

- (NSString *)rootDirectory
{
	return [[super rootDirectory] stringByDeletingFirstPathComponent];
}

- (void)createDirectory:(NSString *)dirPath
{
	[super createDirectory:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:dirPath]];
}

- (void)createDirectory:(NSString *)dirPath permissions:(unsigned long)permissions
{
	[self createDirectory:dirPath];
}

- (void)setPermissions:(unsigned long)permissions forFile:(NSString *)path
{
	[super setPermissions:permissions
				  forFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:path]];
}

- (void)rename:(NSString *)fromPath to:(NSString *)toPath
{
	NSString *from = [[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:fromPath];
	NSString *to = [[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:toPath];
	[super rename:from to:to];
}

- (void)deleteFile:(NSString *)path
{
	[super deleteFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:path]];
}

- (void)deleteDirectory:(NSString *)dirPath
{
	[super deleteDirectory:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:dirPath]];
}

- (void)uploadFile:(NSString *)localPath
{
	[super uploadFile: localPath
             toFile: [myCurrentDirectory stringByAppendingPathComponent:[localPath lastPathComponent]]];
}

- (void)uploadFile:(NSString *)localPath toFile:(NSString *)remotePath
{
	[self uploadFile:localPath toFile:remotePath checkRemoteExistence:NO delegate:nil];
}

- (CKTransferRecord *)uploadFile:(NSString *)localPath 
						  toFile:(NSString *)remotePath 
			checkRemoteExistence:(BOOL)flag 
						delegate:(id)delegate
{	
	return [super uploadFile:localPath
					  toFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:remotePath]
		checkRemoteExistence:flag
					delegate:delegate];
}

- (CKTransferRecord *)resumeUploadFile:(NSString *)localPath 
								toFile:(NSString *)remotePath 
							fileOffset:(unsigned long long)offset
							  delegate:(id)delegate
{
	return [self uploadFile:localPath
					 toFile:remotePath
	   checkRemoteExistence:NO
				   delegate:delegate];
}

- (void)uploadFromData:(NSData *)data toFile:(NSString *)remotePath
{
	[self uploadFromData:data toFile:remotePath checkRemoteExistence:NO delegate:nil];
}

- (CKTransferRecord *)uploadFromData:(NSData *)data
							  toFile:(NSString *)remotePath 
				checkRemoteExistence:(BOOL)flag
							delegate:(id)delegate
{	
	return [super uploadFromData:data
						  toFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:remotePath]
			checkRemoteExistence:flag
						delegate:delegate];
}

- (CKTransferRecord *)resumeUploadFromData:(NSData *)data
									toFile:(NSString *)remotePath 
								fileOffset:(unsigned long long)offset
								  delegate:(id)delegate
{
	return [super resumeUploadFromData:data
								toFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:remotePath]
							fileOffset:offset
							  delegate:delegate];
}

- (void)downloadFile:(NSString *)remotePath toDirectory:(NSString *)dirPath overwrite:(BOOL)flag
{
	[super downloadFile:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:remotePath]
			toDirectory:dirPath
			  overwrite:flag];
}

- (void)resumeDownloadFile:(NSString *)remotePath toDirectory:(NSString *)dirPath fileOffset:(unsigned long long)offset
{
	[self downloadFile:remotePath
		   toDirectory:dirPath
			 overwrite:YES];
}

- (void)contentsOfDirectory:(NSString *)dirPath
{
	[super contentsOfDirectory:[[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:dirPath]];
}

- (void)checkExistenceOfPath:(NSString *)path
{
	NSAssert(path && ![path isEqualToString:@""], @"no path specified");
	NSString *dir = [[NSString stringWithFormat:@"/%@", [self username]] stringByAppendingPathComponent:[path stringByDeletingLastPathComponent]];
	
	//if we pass in a relative path (such as xxx.tif), then the last path is @"", with a length of 0, so we need to add the current directory
	//according to docs, passing "/" to stringByDeletingLastPathComponent will return "/", conserving a 1 size
	
	if (!dir || [dir length] == 0)
	{
		path = [[self currentDirectory] stringByAppendingPathComponent:path];
	}
	
	[self queueFileCheck:path];
	[[[ConnectionThreadManager defaultManager] prepareWithInvocationTarget:self] processFileCheckingQueue];
}

- (void)connection:(id <AbstractConnectionProtocol>)con didReceiveContents:(NSArray *)contents ofDirectory:(NSString *)dirPath;
{
	if (_flags.fileCheck) {
		NSString *name = [_fileCheckInFlight lastPathComponent];
		NSEnumerator *e = [contents objectEnumerator];
		NSDictionary *cur;
		BOOL foundFile = NO;
		
		while (cur = [e nextObject]) 
		{
			if ([[cur objectForKey:cxFilenameKey] isEqualToString:name]) 
			{
				[_forwarder connection:self checkedExistenceOfPath:_fileCheckInFlight pathExists:YES];
				foundFile = YES;
				break;
			}
		}
		if (!foundFile)
		{
			[_forwarder connection:self checkedExistenceOfPath:_fileCheckInFlight pathExists:NO];
		}
	}
	[self dequeueFileCheck];
	[_fileCheckInFlight autorelease];
	_fileCheckInFlight = nil;
	[self performSelector:@selector(processFileCheckingQueue) withObject:nil afterDelay:0.0];
}

@end
