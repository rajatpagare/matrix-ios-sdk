/*
 Copyright 2016 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXCrypto.h"

#import "MXCrypto_Private.h"

#import "MXSession.h"
#import "MXTools.h"

#import "MXOlmDevice.h"
#import "MXUsersDevicesMap.h"
#import "MXDeviceInfo.h"
#import "MXKey.h"

#import "MXFileCryptoStore.h"
#import "MXRealmCryptoStore.h"

#import "MXMegolmSessionData.h"
#import "MXMegolmExportEncryption.h"

/**
 The store to use for crypto.
 */
//#define MXCryptoStoreClass MXFileCryptoStore
#define MXCryptoStoreClass MXRealmCryptoStore

#ifdef MX_CRYPTO

@interface MXCrypto ()
{
    // The Matrix session.
    MXSession *mxSession;

    // MXEncrypting instance for each room.
    NSMutableDictionary<NSString*, id<MXEncrypting>> *roomEncryptors;

    // A map from algorithm to MXDecrypting instance, for each room
    NSMutableDictionary<NSString* /* roomId */,
        NSMutableDictionary<NSString* /* algorithm */, id<MXDecrypting>>*> *roomDecryptors;

    // Our device keys
    MXDeviceInfo *myDevice;

    // Listener on memberships changes
    id roomMembershipEventsListener;

    // For dev
    // @TODO: could be removed
    NSDictionary *lastPublishedOneTimeKeys;

    // Timer to periodically upload keys
    NSTimer *uploadKeysTimer;

    // The operation used for crypto starting requests
    MXHTTPOperation *startOperation;

    BOOL initialDeviceListInvalidationDone;
}
@end

#endif


@implementation MXCrypto

+ (MXCrypto *)createCryptoWithMatrixSession:(MXSession *)mxSession
{
    __block MXCrypto *crypto;

#ifdef MX_CRYPTO

    dispatch_queue_t cryptoQueue = [MXCrypto dispatchQueueForUser:mxSession.matrixRestClient.credentials.userId];
    dispatch_sync(cryptoQueue, ^{

        MXCryptoStoreClass *cryptoStore = [MXCryptoStoreClass createStoreWithCredentials:mxSession.matrixRestClient.credentials];
        crypto = [[MXCrypto alloc] initWithMatrixSession:mxSession cryptoQueue:cryptoQueue andStore:cryptoStore];

    });
#endif

    return crypto;
}

+ (void)checkCryptoWithMatrixSession:(MXSession *)mxSession complete:(void (^)(MXCrypto *))complete
{
#ifdef MX_CRYPTO

    NSLog(@"[MXCrypto] checkCryptoWithMatrixSession for %@", mxSession.matrixRestClient.credentials.userId);

    dispatch_queue_t cryptoQueue = [MXCrypto dispatchQueueForUser:mxSession.matrixRestClient.credentials.userId];
    dispatch_async(cryptoQueue, ^{

        if ([MXFileCryptoStore hasDataForCredentials:mxSession.matrixRestClient.credentials])
        {
            NSLog(@"[MXCrypto] checkCryptoWithMatrixSession: Migration required for %@", mxSession.matrixRestClient.credentials);
            if (![MXFileCryptoStore migrateToMXRealmCryptoStore:mxSession.matrixRestClient.credentials])
            {
                NSLog(@"[MXCrypto] Migration failed. We cannot do nothing except asking user for logging out and in");
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionCryptoDidCorruptDataNotification
                                                                    object:mxSession.matrixRestClient.credentials.userId
                                                                  userInfo:nil];
            }
        }

        if ([MXCryptoStoreClass hasDataForCredentials:mxSession.matrixRestClient.credentials])
        {
            NSLog(@"[MXCrypto] checkCryptoWithMatrixSession: Crypto store exists");

            // If it already exists, open and init crypto
            MXCryptoStoreClass *cryptoStore = [[MXCryptoStoreClass alloc] initWithCredentials:mxSession.matrixRestClient.credentials];

            [cryptoStore open:^{

                NSLog(@"[MXCrypto] checkCryptoWithMatrixSession: Crypto store opened");

                MXCrypto *crypto = [[MXCrypto alloc] initWithMatrixSession:mxSession cryptoQueue:cryptoQueue andStore:cryptoStore];

                dispatch_async(dispatch_get_main_queue(), ^{
                    complete(crypto);
                });

            } failure:^(NSError *error) {

                NSLog(@"[MXCrypto] checkCryptoWithMatrixSession: Crypto store failed to open. Error: %@", error);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    complete(nil);
                });
            }];
        }
        else if ([MXSDKOptions sharedInstance].enableCryptoWhenStartingMXSession
                 // Without the device id provided by the hs, the crypto does not work
                 && mxSession.matrixRestClient.credentials.deviceId)
        {
            NSLog(@"[MXCrypto] checkCryptoWithMatrixSession: Need to create the store");

            // Create it
            MXCryptoStoreClass *cryptoStore = [MXCryptoStoreClass createStoreWithCredentials:mxSession.matrixRestClient.credentials];
            MXCrypto *crypto = [[MXCrypto alloc] initWithMatrixSession:mxSession cryptoQueue:cryptoQueue andStore:cryptoStore];

            dispatch_async(dispatch_get_main_queue(), ^{
                complete(crypto);
            });
        }
        else
        {
            // Else do not enable crypto
            dispatch_async(dispatch_get_main_queue(), ^{
                complete(nil);
            });
        }

    });

#else
    complete(nil);
#endif
}

+ (void)deleteStoreWithCredentials:(MXCredentials *)credentials
{
#ifdef MX_CRYPTO
    [MXCryptoStoreClass deleteStoreWithCredentials:credentials];
#endif
}

- (void)start:(void (^)())success
      failure:(void (^)(NSError *error))failure
{

#ifdef MX_CRYPTO
    NSLog(@"[MXCrypto] start");

    // The session must be initialised enough before starting this module
    if (!mxSession.myUser.userId)
    {
        NSLog(@"[MXCrypto] start. ERROR: mxSession.myUser.userId cannot be nil");
        failure(nil);
        return;
    }

    // Check if announcement must be done and to who
    NSMutableDictionary *roomsByUser = [self usersToMakeAnnouncement];

    // Start uploading user device keys
    startOperation = [self uploadKeys:5 success:^{

        if (!startOperation)
        {
            return;
        }

        NSLog(@"[MXCrypto] start ###########################################################");
        NSLog(@" uploadKeys done for %@: ", mxSession.myUser.userId);

        NSLog(@"   - device id  : %@", _store.deviceId);
        NSLog(@"   - ed25519    : %@", _olmDevice.deviceEd25519Key);
        NSLog(@"   - curve25519 : %@", _olmDevice.deviceCurve25519Key);
        NSLog(@"   - oneTimeKeys: %@", lastPublishedOneTimeKeys);     // They are
        NSLog(@"");
        NSLog(@"Store: %@", _store);
        NSLog(@"");

        // Once keys are uploaded, make sure we announce ourselves
        MXHTTPOperation *operation2 = [self makeAnnoucement:roomsByUser success:^{

            // Start periodic timer for uploading keys
            uploadKeysTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:10 * 60]
                                                       interval:10 * 60   // 10 min
                                                         target:self
                                                       selector:@selector(uploadKeys)
                                                       userInfo:nil
                                                        repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:uploadKeysTimer forMode:NSDefaultRunLoopMode];

            dispatch_async(dispatch_get_main_queue(), ^{
                startOperation = nil;
                success();
            });

        } failure:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                startOperation = nil;
                failure(error);
            });
        }];

        if (operation2)
        {
            [startOperation mutateTo:operation2];
        }

    } failure:^(NSError *error) {
        NSLog(@"[MXCrypto] start. Error in uploadKeys");
        dispatch_async(dispatch_get_main_queue(), ^{
            startOperation = nil;
            failure(error);
        });
    }];

#endif
}

- (void)close
{
#ifdef MX_CRYPTO

    NSLog(@"[MXCrypto] close. store: %@", _store);

    [mxSession removeListener:roomMembershipEventsListener];

    [startOperation cancel];
    startOperation = nil;

    dispatch_async(_cryptoQueue, ^{

        // Stop timer
        [uploadKeysTimer invalidate];
        uploadKeysTimer = nil;

        _olmDevice = nil;
        _cryptoQueue = nil;
        _store = nil;

        [roomEncryptors removeAllObjects];
        roomEncryptors = nil;

        [roomDecryptors removeAllObjects];
        roomDecryptors = nil;
        
        myDevice = nil;

        NSLog(@"[MXCrypto] close: done");
    });

#endif
}

- (MXHTTPOperation *)encryptEventContent:(NSDictionary *)eventContent withType:(MXEventTypeString)eventType inRoom:(MXRoom *)room
                                 success:(void (^)(NSDictionary *, NSString *))success
                                 failure:(void (^)(NSError *))failure
{
#ifdef MX_CRYPTO

    // Create an empty operation that will be mutated later
    MXHTTPOperation *operation = [[MXHTTPOperation alloc] init];

    // Pick the list of recipients based on the membership list.

    // TODO: there is a race condition here! What if a new user turns up
    // just as you are sending a secret message?

    // XXX what about rooms where invitees can see the content?
    NSMutableArray *roomMembers = [NSMutableArray array];
    for (MXRoomMember *roomMember in room.state.joinedMembers)
    {
        [roomMembers addObject:roomMember.userId];
    }

    dispatch_async(_cryptoQueue, ^{

        NSString *algorithm;
        id<MXEncrypting> alg = roomEncryptors[room.roomId];

        if (!alg)
        {
            // If the crypto has been enabled after the initialSync (the global one or the one for this room),
            // the algorithm has not been initialised yet. So, do it now from room state information
            algorithm = room.state.encryptionAlgorithm;
            if (algorithm)
            {
                [self setEncryptionInRoom:room.roomId withAlgorithm:algorithm];
                alg = roomEncryptors[room.roomId];
            }
        }
        else
        {
            // For log purpose
            algorithm = NSStringFromClass(alg.class);
        }

        // Sanity check (we don't expect an encrypted content here).
        if (alg && [eventType isEqualToString:kMXEventTypeStringRoomEncrypted] == NO)
        {
#ifdef DEBUG
            NSLog(@"[MXCrypto] encryptEventContent with %@: %@", algorithm, eventContent);
#endif

            MXHTTPOperation *operation2 = [alg encryptEventContent:eventContent eventType:eventType forUsers:roomMembers success:^(NSDictionary *encryptedContent) {

                dispatch_async(dispatch_get_main_queue(), ^{
                    success(encryptedContent, kMXEventTypeStringRoomEncrypted);
                });

            } failure:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    failure(error);
                });
            }];

            // Mutate the HTTP operation if an HTTP is required for the encryption
            if (operation2)
            {
                [operation mutateTo:operation2];
            }
        }
        else
        {
            NSError *error = [NSError errorWithDomain:MXDecryptingErrorDomain
                                                 code:MXDecryptingErrorUnableToEncryptCode
                                             userInfo:@{
                                                        NSLocalizedDescriptionKey: MXDecryptingErrorUnableToEncrypt,
                                                        NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:MXDecryptingErrorUnableToEncryptReason, algorithm]
                                                        }];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(error);
            });
        }
    });

    return operation;

#else
    return nil;
#endif
}

- (BOOL)decryptEvent:(MXEvent *)event inTimeline:(NSString*)timeline
{
#ifdef MX_CRYPTO

    __block BOOL result = NO;

    // @TODO: dispatch_async
    dispatch_sync(_decryptionQueue, ^{
        id<MXDecrypting> alg = [self getRoomDecryptor:event.roomId algorithm:event.content[@"algorithm"]];
        if (!alg)
        {
            NSLog(@"[MXCrypto] decryptEvent: Unable to decrypt %@", event.content[@"algorithm"]);

            event.decryptionError = [NSError errorWithDomain:MXDecryptingErrorDomain
                                                        code:MXDecryptingErrorUnableToDecryptCode
                                                    userInfo:@{
                                                               NSLocalizedDescriptionKey: MXDecryptingErrorUnableToDecrypt,
                                                               NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:MXDecryptingErrorUnableToDecryptReason, event, event.content[@"algorithm"]]
                                                               }];
            return;
        }

        // @TODO: event should not be modified on the crypto thread
        result = [alg decryptEvent:event inTimeline:timeline];
        if (!result)
        {
            NSLog(@"[MXCrypto] decryptEvent: Error: %@", event.decryptionError);
        }
    });

    return result;

#else
    return NO;
#endif
}

// This method is equivalent to the Crypto.prototype._onSyncCompleted in matrix-js-sdk
- (void)handleDeviceListsChanged:(NSArray<NSString *>*)userIds oldSyncToken:(NSString *)oldSyncToken nextSyncToken:(NSString *)nextSyncToken
{
#ifdef MX_CRYPTO

    NSLog(@"[MXCrypto] handleDeviceListsChanged: %@", userIds);

    dispatch_async(_cryptoQueue, ^{

        if (!oldSyncToken)
        {
            // an initialsync
            //[self sendNewDeviceEvents];    // TODO: To change but the current makeAnnoucement method is too much
                                             // part of the enableCrypto flow.

            // If we have a deviceSyncToken, we can tell the deviceList to
            // invalidate devices which have changed since then.
            NSString *oldDeviceSyncToken = _store.deviceSyncToken;
            if (oldDeviceSyncToken)
            {
                [self invalidateDeviceListsSince:oldDeviceSyncToken to:nextSyncToken success:^(NSArray<NSString *> *changed) {

                    initialDeviceListInvalidationDone = YES;
                    _deviceList.lastKnownSyncToken = nextSyncToken;
                    [_deviceList refreshOutdatedDeviceLists];

                } failure:^(NSError *error) {

                    // If that failed, we fall back to invalidating everyone.
                    NSLog(@"[MXCrypto] handleDeviceListsChanged: Error fetching changed device list. Error: %@", error);
                    [self invalidateDeviceListForAllActiveUsers];
                    [_deviceList refreshOutdatedDeviceLists];
                }];
            }
            else
            {
                // Otherwise, we have to invalidate all devices for all users we
                // share a room with.
                NSLog(@"[MXCrypto] handleDeviceListsChanged: Completed first initialsync; invalidating all device list caches");
                [self invalidateDeviceListForAllActiveUsers];
                initialDeviceListInvalidationDone = YES;
            }
        }

        if (initialDeviceListInvalidationDone)
        {
            // If we've got an up-to-date list of users with outdated device lists,
            // tell the device list about the new sync token (but not otherwise, because
            // otherwise we'll start thinking we're more in sync than we are.)
            _deviceList.lastKnownSyncToken = nextSyncToken;

            // Catch up on any new devices we got told about during the sync.
            [_deviceList refreshOutdatedDeviceLists];
        }


        // @TODO
        // we don't start uploading one-time keys until we've caught up with
        // to-device messages, to help us avoid throwing away one-time-keys that we
        // are about to receive messages for
        // (https://github.com/vector-im/riot-web/issues/2782).
//        if (!syncData.catchingUp) {
//            _maybeUploadOneTimeKeys(this);
//        }
    });

#endif
}

- (MXDeviceInfo *)eventDeviceInfo:(MXEvent *)event
{
    __block MXDeviceInfo *device;

#ifdef MX_CRYPTO

    if (event.isEncrypted)
    {
        // Use decryptionQueue because this is a simple read in the db
        // AND we do it synchronously
        // @TODO: dispatch_async
        dispatch_sync(_decryptionQueue, ^{

            NSString *algorithm = event.wireContent[@"algorithm"];
            device = [_deviceList deviceWithIdentityKey:event.senderKey forUser:event.sender andAlgorithm:algorithm];

        });
    }

#endif

    return device;
}

- (void)devicesForUser:(NSString*)userId complete:(void (^)(NSArray<MXDeviceInfo*> *devices))complete
{
#ifdef MX_CRYPTO
    dispatch_async(_cryptoQueue, ^{

        NSArray<MXDeviceInfo*> *devices = [self.deviceList storedDevicesForUser:userId];

        dispatch_async(dispatch_get_main_queue(), ^{
            complete(devices);
        });

    });
#else
    complete(nil);
#endif
}

- (void)setDeviceVerification:(MXDeviceVerification)verificationStatus forDevice:(NSString*)deviceId ofUser:(NSString*)userId
                      success:(void (^)())success
                      failure:(void (^)(NSError *error))failure
{
#ifdef MX_CRYPTO

    // Get all rooms with this user
    NSMutableArray<NSString*> *userRooms = [NSMutableArray array];
    for (MXRoom *room in mxSession.rooms)
    {
        if (room.state.isEncrypted)
        {
            MXRoomMember *member = [room.state memberWithUserId:userId];
            if (member && member.membership == MXMembershipJoin)
            {
                [userRooms addObject:room.roomId];
            }
        }
    }

    // Note: failure is not currently used but it would make sense the day device
    // verification will be sync'ed with the hs.
    dispatch_async(_cryptoQueue, ^{
        MXDeviceInfo *device = [_store deviceWithDeviceId:deviceId forUser:userId];

        // Sanity check
        if (!device)
        {
            NSLog(@"[MXCrypto] setDeviceVerificationForDevice: Unknown device %@:%@", userId, deviceId);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
            return;
        }

        if (device.verified != verificationStatus)
        {
            MXDeviceVerification oldVerified = device.verified;

            device.verified = verificationStatus;
            [_store storeDeviceForUser:userId device:device];

            // Report the change to all outbound sessions with this device
            for (NSString *roomId in userRooms)
            {
                id<MXEncrypting> alg = roomEncryptors[roomId];
                if (alg)
                {
                    [alg onDeviceVerification:device oldVerified:oldVerified];
                }
            }
        }

        if (success)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        }
    });
#else
    if (success)
    {
        success();
    }
#endif
}

- (void)setDevicesKnown:(MXUsersDevicesMap<MXDeviceInfo *> *)devices complete:(void (^)())complete
{
#ifdef MX_CRYPTO
    dispatch_async(_cryptoQueue, ^{

        for (NSString *userId in devices.userIds)
        {
            for (NSString *deviceID in [devices deviceIdsForUser:userId])
            {
                MXDeviceInfo *device = [devices objectForDevice:deviceID forUser:userId];

                if (device.verified == MXDeviceUnknown)
                {
                    device.verified = MXDeviceUnverified;
                    [_store storeDeviceForUser:device.userId device:device];
                }
            }
        }

        if (complete)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                complete();
            });
        }
    });
#else
    if (complete)
    {
        complete();
    }
#endif
}

- (MXHTTPOperation*)downloadKeys:(NSArray<NSString*>*)userIds
                         success:(void (^)(MXUsersDevicesMap<MXDeviceInfo*> *usersDevicesInfoMap))success
                         failure:(void (^)(NSError *error))failure
{
#ifdef MX_CRYPTO

    // Create an empty operation that will be mutated later
    MXHTTPOperation *operation = [[MXHTTPOperation alloc] init];

    dispatch_async(_cryptoQueue, ^{

        MXHTTPOperation *operation2 = [self.deviceList downloadKeys:userIds forceDownload:YES success:^(MXUsersDevicesMap<MXDeviceInfo *> *usersDevicesInfoMap) {
            if (success)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    success(usersDevicesInfoMap);
                });
            }
        } failure:^(NSError *error) {
            if (failure)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    failure(error);
                });
            }
        }];

        if (operation2)
        {
            [operation mutateTo:operation2];
        }
    });

    return operation;
#else
    if (success)
    {
        success(nil);
    }
    return nil;
#endif
}

- (void)resetReplayAttackCheckInTimeline:(NSString*)timeline
{
#ifdef MX_CRYPTO
    dispatch_async(_decryptionQueue, ^{
        [_olmDevice resetReplayAttackCheckInTimeline:timeline];
    });
#endif
}

- (NSString *)deviceCurve25519Key
{
#ifdef MX_CRYPTO
    return _olmDevice.deviceCurve25519Key;
#else
    return nil;
#endif
}

- (NSString *)deviceEd25519Key
{
#ifdef MX_CRYPTO
    return _olmDevice.deviceEd25519Key;
#else
    return nil;
#endif
}

- (NSString *)olmVersion
{
#ifdef MX_CRYPTO
    return _olmDevice.olmVersion;
#else
    return nil;
#endif
}


#pragma mark - import/export

- (void)exportRoomKeys:(void (^)(NSArray<NSDictionary *> *))success failure:(void (^)(NSError *))failure
{
#ifdef MX_CRYPTO
    dispatch_async(_decryptionQueue, ^{

        NSDate *startDate = [NSDate date];

        NSMutableArray *keys = [NSMutableArray array];

        for (MXOlmInboundGroupSession *session in [_store inboundGroupSessions])
        {
            MXMegolmSessionData *sessionData = [session exportSessionData];
            if (sessionData)
            {
                [keys addObject:sessionData.JSONDictionary];
            }
        }

        NSLog(@"[MXCrypto] exportRoomKeys: Exported %tu keys in %.0fms", keys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

        dispatch_async(dispatch_get_main_queue(), ^{

            if (success)
            {
                success(keys);
            }

        });

    });
#endif
}

- (void)exportRoomKeysWithPassword:(NSString *)password success:(void (^)(NSData *))success failure:(void (^)(NSError *))failure
{
#ifdef MX_CRYPTO

        dispatch_async(_decryptionQueue, ^{

            NSData *keyFile;
            NSError *error;

            NSDate *startDate = [NSDate date];

            // Export the keys
            NSMutableArray *keys = [NSMutableArray array];
            for (MXOlmInboundGroupSession *session in [_store inboundGroupSessions])
            {
                MXMegolmSessionData *sessionData = [session exportSessionData];
                if (sessionData)
                {
                    [keys addObject:sessionData.JSONDictionary];
                }
            }

            NSLog(@"[MXCrypto] exportRoomKeysWithPassword: Exportion of %tu keys took %.0fms", keys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

            // Convert them to JSON
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:keys
                                                               options:NSJSONWritingPrettyPrinted
                                                                 error:&error];
            if (jsonData)
            {
                // Encrypt them
                keyFile = [MXMegolmExportEncryption encryptMegolmKeyFile:jsonData withPassword:password kdfRounds:0 error:&error];
            }

            NSLog(@"[MXCrypto] exportRoomKeysWithPassword: Exported and encrypted %tu keys in %.0fms", keys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

            dispatch_async(dispatch_get_main_queue(), ^{

                if (keyFile)
                {
                    if (success)
                    {
                        success(keyFile);
                    }
                }
                else
                {
                    NSLog(@"[MXCrypto] exportRoomKeysWithPassword: Error: %@", error);
                    if (failure)
                    {
                        failure(error);
                    }
                }

            });

        });
#endif
}

- (void)importRoomKeys:(NSArray<NSDictionary *> *)keys success:(void (^)())success failure:(void (^)(NSError *))failure
{
#ifdef MX_CRYPTO
    dispatch_async(_decryptionQueue, ^{

        NSLog(@"[MXCrypto] importRoomKeys:");

        NSDate *startDate = [NSDate date];

        // Convert JSON to MXMegolmSessionData
        NSArray<MXMegolmSessionData *> *sessionDatas = [MXMegolmSessionData modelsFromJSON:keys];

        for (MXMegolmSessionData *sessionData in sessionDatas)
        {
            NSLog(@"  - importing %@|%@", sessionData.senderKey, sessionData.sessionId);

            if (!sessionData.roomId || !sessionData.algorithm)
            {
                NSLog(@"        -> ignoring session entry with missing fields: %@", sessionData);
                continue;
            }

            // Import the session
            id<MXDecrypting> alg = [self getRoomDecryptor:sessionData.roomId algorithm:sessionData.algorithm];
            [alg importRoomKey:sessionData];
        }

        NSLog(@"[MXCrypto] importRoomKeys: Imported %tu keys in %.0fms", keys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

        dispatch_async(dispatch_get_main_queue(), ^{

            if (success)
            {
                success();
            }

        });
    });
#endif
}

- (void)importRoomKeys:(NSData *)keyFile withPassword:(NSString *)password success:(void (^)())success failure:(void (^)(NSError *))failure
{
#ifdef MX_CRYPTO
    dispatch_async(_decryptionQueue, ^{

        NSLog(@"[MXCrypto] importRoomKeys:withPassord:");

        NSError *error;
        NSDate *startDate = [NSDate date];

        NSData *jsonData = [MXMegolmExportEncryption decryptMegolmKeyFile:keyFile withPassword:password error:&error];
        if(jsonData)
        {
            NSArray *keys = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
            if (keys)
            {
                [self importRoomKeys:keys success:^{

                    NSLog(@"[MXCrypto] importRoomKeys:withPassord: Imported %tu keys in %.0fms", keys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

                    if (success)
                    {
                        success();
                    }

                } failure:failure];
                return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{

            NSLog(@"[MXCrypto] importRoomKeys:withPassord: Error: %@", error);

            if (failure)
            {
                failure(error);
            }

        });

    });
#endif
}

#pragma mark - Private API

#ifdef MX_CRYPTO

- (instancetype)initWithMatrixSession:(MXSession*)matrixSession cryptoQueue:(dispatch_queue_t)theCryptoQueue andStore:(id<MXCryptoStore>)store
{
    // This method must be called on the crypto thread
    self = [super init];
    if (self)
    {
        mxSession = matrixSession;
        _cryptoQueue = theCryptoQueue;
        _store = store;

        // Default configuration
        _warnOnUnknowDevices = YES;

        _decryptionQueue = [MXCrypto dispatchQueueForUser:mxSession.matrixRestClient.credentials.userId];

        _olmDevice = [[MXOlmDevice alloc] initWithStore:_store];

        _deviceList = [[MXDeviceList alloc] initWithCrypto:self];

        // Use our own REST client that answers on the crypto thread
        _matrixRestClient = [[MXRestClient alloc] initWithCredentials:mxSession.matrixRestClient.credentials andOnUnrecognizedCertificateBlock:nil];
        _matrixRestClient.completionQueue = _cryptoQueue;

        roomEncryptors = [NSMutableDictionary dictionary];
        roomDecryptors = [NSMutableDictionary dictionary];

        initialDeviceListInvalidationDone = NO;

        // Build our device keys: they will later be uploaded
        NSString *deviceId = _store.deviceId;
        if (!deviceId)
        {
            // Generate a device id if the homeserver did not provide it or it was lost
            deviceId = [self generateDeviceId];

            NSLog(@"[MXCrypto] Warning: No device id in MXCredentials. The id %@ was created", deviceId);

            [_store storeDeviceId:deviceId];
        }

        NSString *userId = _matrixRestClient.credentials.userId;

        myDevice = [[MXDeviceInfo alloc] initWithDeviceId:deviceId];
        myDevice.userId = userId;
        myDevice.keys = @{
                          [NSString stringWithFormat:@"ed25519:%@", deviceId]: _olmDevice.deviceEd25519Key,
                          [NSString stringWithFormat:@"curve25519:%@", deviceId]: _olmDevice.deviceCurve25519Key,
                          };
        myDevice.algorithms = [[MXCryptoAlgorithms sharedAlgorithms] supportedAlgorithms];
        myDevice.verified = MXDeviceVerified;

        // Add our own deviceinfo to the store
        NSMutableDictionary *myDevices = [NSMutableDictionary dictionaryWithDictionary:[_store devicesForUser:userId]];
        myDevices[myDevice.deviceId] = myDevice;
        [_store storeDevicesForUser:userId devices:myDevices];
        
        [self registerEventHandlers];
        
    }
    return self;
}

- (MXHTTPOperation *)uploadKeys:(NSUInteger)maxKeys
                        success:(void (^)())success
                        failure:(void (^)(NSError *))failure
{
    MXHTTPOperation *operation;
    operation = [self uploadDeviceKeys:^(MXKeysUploadResponse *keysUploadResponse) {

        // We need to keep a pool of one time public keys on the server so that
        // other devices can start conversations with us. But we can only store
        // a finite number of private keys in the olm Account object.
        // To complicate things further then can be a delay between a device
        // claiming a public one time key from the server and it sending us a
        // message. We need to keep the corresponding private key locally until
        // we receive the message.
        // But that message might never arrive leaving us stuck with duff
        // private keys clogging up our local storage.
        // So we need some kind of enginering compromise to balance all of
        // these factors.

        // We first find how many keys the server has for us.
        NSUInteger keyCount = [keysUploadResponse oneTimeKeyCountsForAlgorithm:@"signed_curve25519"];

        // We then check how many keys we can store in the Account object.
        CGFloat maxOneTimeKeys = _olmDevice.maxNumberOfOneTimeKeys;

        // Try to keep at most half that number on the server. This leaves the
        // rest of the slots free to hold keys that have been claimed from the
        // server but we haven't recevied a message for.
        // If we run out of slots when generating new keys then olm will
        // discard the oldest private keys first. This will eventually clean
        // out stale private keys that won't receive a message.
        NSUInteger keyLimit = floor(maxOneTimeKeys / 2);

        // We work out how many new keys we need to create to top up the server
        // If there are too many keys on the server then we don't need to
        // create any more keys.
        NSUInteger numberToGenerate = MAX(keyLimit - keyCount, 0);

        if (maxKeys)
        {
            // Creating keys can be an expensive operation so we limit the
            // number we generate in one go to avoid blocking the application
            // for too long.
            numberToGenerate = MIN(numberToGenerate, maxKeys);

            // Ask olm to generate new one time keys, then upload them to synapse.
            [_olmDevice generateOneTimeKeys:numberToGenerate];
            MXHTTPOperation *operation2 = [self uploadOneTimeKeys:success failure:failure];

            // Mutate MXHTTPOperation so that the user can cancel this new operation
            [operation mutateTo:operation2];
        }
        else
        {
            // If we don't need to generate any keys then we are done.
            success();
        }

        if (numberToGenerate <= 0) {
            return;
        }

    } failure:^(NSError *error) {
        NSLog(@"[MXCrypto] uploadDeviceKeys fails.");
        failure(error);
    }];

    return operation;
}

- (void)uploadKeys
{
    NSLog(@"[MXCrypto] Periodic uploadKeys");

    [self uploadKeys:5 success:^{
    } failure:^(NSError *error) {
        NSLog(@"[MXCrypto] Periodic uploadKeys failed.");
    }];
}

- (MXDeviceInfo *)eventSenderDeviceOfEvent:(MXEvent *)event
{
    NSString *senderKey = event.senderKey;
    NSString *algorithm = event.wireContent[@"algorithm"];

    if (!senderKey || !algorithm)
    {
        return nil;
    }

    // senderKey is the Curve25519 identity key of the device which the event
    // was sent from. In the case of Megolm, it's actually the Curve25519
    // identity key of the device which set up the Megolm session.
    MXDeviceInfo *device = [_deviceList deviceWithIdentityKey:senderKey forUser:event.sender andAlgorithm:algorithm];
    if (!device)
    {
        // we haven't downloaded the details of this device yet.
        return nil;
    }

    // So far so good, but now we need to check that the sender of this event
    // hadn't advertised someone else's Curve25519 key as their own. We do that
    // by checking the Ed25519 claimed by the event (or, in the case of megolm,
    // the event which set up the megolm session), to check that it matches the
    // fingerprint of the purported sending device.
    //
    // (see https://github.com/vector-im/vector-web/issues/2215)
    NSString *claimedKey = event.keysClaimed[@"ed25519"];
    if (!claimedKey)
    {
        NSLog(@"[MXCrypto] eventSenderDeviceOfEvent: Event %@ claims no ed25519 key. Cannot verify sending device", event.eventId);
        return nil;
    }

    if (![claimedKey isEqualToString:device.fingerprint])
    {
        NSLog(@"[MXCrypto] eventSenderDeviceOfEvent: Event %@ claims ed25519 key %@. Cannot verify sending device but sender device has key %@", event.eventId, claimedKey, device.fingerprint);
        return nil;
    }
    
    return device;
}

-(BOOL)setEncryptionInRoom:(NSString*)roomId withAlgorithm:(NSString*)algorithm
{
    // If we already have encryption in this room, we should ignore this event
    // (for now at least. Maybe we should alert the user somehow?)
    NSString *existingAlgorithm = [_store algorithmForRoom:roomId];
    if (existingAlgorithm && ![existingAlgorithm isEqualToString:algorithm])
    {
        NSLog(@"[MXCrypto] setEncryptionInRoom: Ignoring m.room.encryption event which requests a change of config in %@", roomId);
        return NO;
    }

    Class encryptionClass = [[MXCryptoAlgorithms sharedAlgorithms] encryptorClassForAlgorithm:algorithm];
    if (!encryptionClass)
    {
        NSLog(@"[MXCrypto] setEncryptionInRoom: Unable to encrypt with %@", algorithm);
        return NO;
    }

    if (!existingAlgorithm)
    {
        [_store storeAlgorithmForRoom:roomId algorithm:algorithm];
    }

    id<MXEncrypting> alg = [[encryptionClass alloc] initWithCrypto:self andRoom:roomId];

    roomEncryptors[roomId] = alg;

    return YES;
}

- (MXHTTPOperation*)ensureOlmSessionsForUsers:(NSArray*)users
                                      success:(void (^)(MXUsersDevicesMap<MXOlmSessionResult*> *results))success
                                      failure:(void (^)(NSError *error))failure
{
    NSLog(@"[MXCrypto] ensureOlmSessionsForUsers: %@", users);

    NSMutableDictionary<NSString* /* userId */, NSMutableArray<MXDeviceInfo*>*> *devicesByUser = [NSMutableDictionary dictionary];

    for (NSString *userId in users)
    {
        devicesByUser[userId] = [NSMutableArray array];

        NSArray<MXDeviceInfo *> *devices = [self.deviceList storedDevicesForUser:userId];
        for (MXDeviceInfo *device in devices)
        {
            NSString *key = device.identityKey;

            if ([key isEqualToString:_olmDevice.deviceCurve25519Key])
            {
                // Don't bother setting up session to ourself
                continue;
            }

            if (device.verified == MXDeviceBlocked) {
                // Don't bother setting up sessions with blocked users
                continue;
            }

            [devicesByUser[userId] addObject:device];
        }
    }

    return [self ensureOlmSessionsForDevices:devicesByUser success:success failure:failure];
}

- (MXHTTPOperation*)ensureOlmSessionsForDevices:(NSDictionary<NSString* /* userId */, NSArray<MXDeviceInfo*>*>*)devicesByUser
                                        success:(void (^)(MXUsersDevicesMap<MXOlmSessionResult*> *results))success
                                        failure:(void (^)(NSError *error))failure

{
    NSMutableArray<MXDeviceInfo*> *devicesWithoutSession = [NSMutableArray array];

    MXUsersDevicesMap<MXOlmSessionResult*> *results = [[MXUsersDevicesMap alloc] init];

    NSUInteger count = 0;
    for (NSString *userId in devicesByUser)
    {
        count += devicesByUser[userId].count;

        for (MXDeviceInfo *deviceInfo in devicesByUser[userId])
        {
            NSString *deviceId = deviceInfo.deviceId;
            NSString *key = deviceInfo.identityKey;

            NSString *sessionId = [_olmDevice sessionIdForDevice:key];
            if (!sessionId)
            {
                [devicesWithoutSession addObject:deviceInfo];
            }

            MXOlmSessionResult *olmSessionResult = [[MXOlmSessionResult alloc] initWithDevice:deviceInfo andOlmSession:sessionId];
            [results setObject:olmSessionResult forUser:userId andDevice:deviceId];
        }
    }

    NSLog(@"[MXCrypto] ensureOlmSessionsForDevices (users count: %tu - devices: %tu)", devicesByUser.count, count);

    if (devicesWithoutSession.count == 0)
    {
        success(results);
        return nil;
    }

    NSString *oneTimeKeyAlgorithm = kMXKeySignedCurve25519Type;

    // Prepare the request for claiming one-time keys
    MXUsersDevicesMap<NSString*> *usersDevicesToClaim = [[MXUsersDevicesMap<NSString*> alloc] init];
    for (MXDeviceInfo *device in devicesWithoutSession)
    {
        [usersDevicesToClaim setObject:oneTimeKeyAlgorithm forUser:device.userId andDevice:device.deviceId];
    }

    // TODO: this has a race condition - if we try to send another message
    // while we are claiming a key, we will end up claiming two and setting up
    // two sessions.
    //
    // That should eventually resolve itself, but it's poor form.

    NSLog(@"[MXCrypto] ensureOlmSessionsForDevices: claimOneTimeKeysForUsersDevices (users count: %tu - devices: %tu)",
          usersDevicesToClaim.map.count, usersDevicesToClaim.count);

    return [_matrixRestClient claimOneTimeKeysForUsersDevices:usersDevicesToClaim success:^(MXKeysClaimResponse *keysClaimResponse) {

        NSLog(@"[MXCrypto] keysClaimResponse.oneTimeKeys (users count: %tu - devices: %tu): %@",
              keysClaimResponse.oneTimeKeys.map.count, keysClaimResponse.oneTimeKeys.count, keysClaimResponse.oneTimeKeys);

        for (NSString *userId in devicesByUser)
        {
            for (MXDeviceInfo *deviceInfo in devicesByUser[userId])
            {
                MXKey *oneTimeKey;
                for (NSString *deviceId in [keysClaimResponse.oneTimeKeys deviceIdsForUser:userId])
                {
                    MXOlmSessionResult *olmSessionResult = [results objectForDevice:deviceId forUser:userId];
                    if (olmSessionResult.sessionId)
                    {
                        // We already have a result for this device
                        continue;
                    }

                    MXKey *key = [keysClaimResponse.oneTimeKeys objectForDevice:deviceId forUser:userId];
                    if ([key.type isEqualToString:oneTimeKeyAlgorithm])
                    {
                        oneTimeKey = key;
                    }

                    if (!oneTimeKey)
                    {
                        NSLog(@"[MXCrypto] No one-time keys (alg=%@)for device %@:%@", oneTimeKeyAlgorithm, userId, deviceId);
                        continue;
                    }

                    NSString *sid = [self verifyKeyAndStartSession:oneTimeKey userId:userId deviceInfo:deviceInfo];

                    // Update the result for this device in results
                    olmSessionResult.sessionId = sid;
                }
            }
        }

        success(results);

    } failure:^(NSError *error) {

        NSLog(@"[MXCrypto] ensureOlmSessionsForUsers: claimOneTimeKeysForUsersDevices request failed.");
        failure(error);
    }];
}

- (NSString*)verifyKeyAndStartSession:(MXKey*)oneTimeKey userId:(NSString*)userId deviceInfo:(MXDeviceInfo*)deviceInfo
{
    NSString *sessionId;

    NSString *deviceId = deviceInfo.deviceId;
    NSString *signKeyId = [NSString stringWithFormat:@"ed25519:%@", deviceId];
    NSString *signature = [oneTimeKey.signatures objectForDevice:signKeyId forUser:userId];

    // Check one-time key signature
    NSError *error;
    if ([_olmDevice verifySignature:deviceInfo.fingerprint JSON:oneTimeKey.signalableJSONDictionary signature:signature error:&error])
    {
        // Update the result for this device in results
        sessionId = [_olmDevice createOutboundSession:deviceInfo.identityKey theirOneTimeKey:oneTimeKey.value];

        if (sessionId)
        {
            NSLog(@"[MXCrypto] Started new sessionid %@ for device %@ (theirOneTimeKey: %@)", sessionId, deviceInfo, oneTimeKey.value);
        }
        else
        {
            // Possibly a bad key
            NSLog(@"[MXCrypto]Error starting session with device %@:%@", userId, deviceId);
        }
    }
    else
    {
        NSLog(@"[MXCrypto] Unable to verify signature on one-time key for device %@:%@.", userId, deviceId);
    }

    return sessionId;
}

- (NSDictionary*)encryptMessage:(NSDictionary*)payloadFields forDevices:(NSArray<MXDeviceInfo*>*)devices
{
    NSMutableDictionary *ciphertext = [NSMutableDictionary dictionary];
    for (MXDeviceInfo *recipientDevice in devices)
    {
        NSString *sessionId = [_olmDevice sessionIdForDevice:recipientDevice.identityKey];
        if (sessionId)
        {
            NSMutableDictionary *payloadJson = [NSMutableDictionary dictionaryWithDictionary:payloadFields];
            payloadJson[@"sender"] = _matrixRestClient.credentials.userId;
            payloadJson[@"sender_device"] = _store.deviceId;

            // Include the Ed25519 key so that the recipient knows what
            // device this message came from.
            // We don't need to include the curve25519 key since the
            // recipient will already know this from the olm headers.
            // When combined with the device keys retrieved from the
            // homeserver signed by the ed25519 key this proves that
            // the curve25519 key and the ed25519 key are owned by
            // the same device.
            payloadJson[@"keys"] = @{
                                     @"ed25519": _olmDevice.deviceEd25519Key
                                     };

            // Include the recipient device details in the payload,
            // to avoid unknown key attacks, per
            // https://github.com/vector-im/vector-web/issues/2483
            payloadJson[@"recipient"] = recipientDevice.userId;
            payloadJson[@"recipient_keys"] = @{
                                               @"ed25519": recipientDevice.fingerprint
                                               };

            NSData *payloadData = [NSJSONSerialization  dataWithJSONObject:payloadJson options:0 error:nil];
            NSString *payloadString = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];

            NSLog(@"[MXCrypto] encryptMessage: %@\nUsing sessionid %@ for device %@", payloadJson, sessionId, recipientDevice.identityKey);
            ciphertext[recipientDevice.identityKey] = [_olmDevice encryptMessage:recipientDevice.identityKey sessionId:sessionId payloadString:payloadString];
        }
    }

    return @{
             @"algorithm": kMXCryptoOlmAlgorithm,
             @"sender_key": _olmDevice.deviceCurve25519Key,
             @"ciphertext": ciphertext
             };
};


#pragma mark - Private methods
/**
 Get or create the GCD queue for a given user.

 @param userId the user id.
 @return the dispatch queue to use to handle the crypto for this user.
 */
+ (dispatch_queue_t)dispatchQueueForUser:(NSString*)userId
{
    static NSMutableDictionary <NSString*, dispatch_queue_t> *dispatchQueues;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatchQueues = [NSMutableDictionary dictionary];
    });

    dispatch_queue_t queue = dispatchQueues[userId];
    if (!queue)
    {
        @synchronized (dispatchQueues)
        {
            NSLog(@"[MXCrypto] Create dispatch queue for %@'s crypto", userId);
            queue = dispatch_queue_create([NSString stringWithFormat:@"MXCrypto-%@", userId].UTF8String, DISPATCH_QUEUE_SERIAL);
            dispatchQueues[userId] = queue;
        }
    }

    return queue;
}

- (NSString*)generateDeviceId
{
    return [[[MXTools generateSecret] stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:10];
}

/**
 * Ask the server which users have new devices since a given token,
 * and invalidate them
 *
 * @param {String} oldSyncToken
 * @param {String} lastKnownSyncToken
 *
 * @returns {Promise} resolves once the query is complete. Rejects if the
 *   keyChange query fails.
 */
- (void)invalidateDeviceListsSince:(NSString*)oldSyncToken to:(NSString*)lastKnownSyncToken
                           success:(void (^)(NSArray<NSString*> *changed))success
                           failure:(void (^)(NSError *error))failure
{
    [_matrixRestClient keyChangesFrom:oldSyncToken to:lastKnownSyncToken success:^(NSArray<NSString *> *changed) {

        if (changed.count)
        {
            // Only invalidate users we share an e2e room with - we don't
            // care about users in non-e2e rooms.
            NSArray<NSString*> *filteredUserIds = self.e2eRoomMembers.allKeys;
            for (NSString *changedUser in changed)
            {
                if ([filteredUserIds containsObject:changedUser])
                {
                    [_deviceList invalidateUserDeviceList:changedUser];
                }
            }
        }

        success(changed);

    } failure:failure];
}

/**
 Invalidate any stored device list for any users we share an e2e room with
 */
- (void)invalidateDeviceListForAllActiveUsers
{
    for (NSString *userId in self.e2eRoomMembers.allKeys)
    {
        [_deviceList invalidateUserDeviceList:userId];
    }
}

/**
 Get a list of the e2e-enabled rooms we are members of.
 
 @returns an MXRoom array.
 */
- (NSArray<MXRoom*>*)e2eRooms
{
    NSMutableArray<MXRoom*> *e2eRooms = [NSMutableArray array];
    
    // TODO: mxSession.rooms should be accessed from the main thread
    NSArray *rooms = mxSession.rooms;
    for (MXRoom *room in rooms)
    {
        // Check for rooms with encryption enabled
        if (!room.state.isEncrypted)
        {
            continue;
        }

        // Ignore any rooms which we have left
        MXRoomMember *me = [room.state memberWithUserId:_matrixRestClient.credentials.userId];
        if (!me || (me.membership != MXMembershipJoin && me.membership !=MXMembershipInvite))
        {
            continue;
        }

        [e2eRooms addObject:room];
    }

    return e2eRooms;
}

/**
 Get the users we share an e2e-enabled room with.

 @return the list of rooms ids ordered by user id.
 */
- (NSMutableDictionary<NSString*, NSMutableArray*> *)e2eRoomMembers
{
    NSMutableDictionary<NSString*, NSMutableArray*> *roomsByUser = [NSMutableDictionary dictionary];

    // TODO: self.e2eRooms, room.state should be accessed from the main thread
    for (MXRoom *room in self.e2eRooms)
    {
        for (MXRoomMember *member in room.state.joinedMembers)
        {
            if (!roomsByUser[member.userId])
            {
                roomsByUser[member.userId] = [NSMutableArray array];
            }
            [roomsByUser[member.userId] addObject:room.roomId];
        }
    }

    return roomsByUser;
};

/**
 Listen to events that change the signatures chain.
 */
- (void)registerEventHandlers
{
    dispatch_async(dispatch_get_main_queue(), ^{

        // Observe incoming to-device events
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onToDeviceEvent:) name:kMXSessionOnToDeviceEventNotification object:mxSession];

        // Observe membership changes
        roomMembershipEventsListener = [mxSession listenToEventsOfTypes:@[kMXEventTypeStringRoomEncryption, kMXEventTypeStringRoomMember] onEvent:^(MXEvent *event, MXTimelineDirection direction, id customObject) {

            if (direction == MXTimelineDirectionForwards)
            {
                if (event.eventType == MXEventTypeRoomEncryption)
                {
                    [self onCryptoEvent:event];
                }
                if (event.eventType == MXEventTypeRoomMember)
                {
                    [self onRoomMembership:event];
                }
            }
        }];

    });
}

/**
 Get the list of users and rooms where to announce a new device.
 
 @return the list of rooms ids ordered by user id. nil if annoucement is not required.
 */
- (NSMutableDictionary<NSString*, NSMutableArray*> *)usersToMakeAnnouncement
{
    // Following operations must be called from the main thread
    NSParameterAssert([NSThread currentThread].isMainThread);

    if (_store.deviceAnnounced)
    {
        NSLog(@"[MXCrypto] usersToMakeAnnouncement: Device announcement already done");
        return nil;
    }

    // We need to tell all the devices in all the rooms we are members of that
    // we have arrived.
    // Build a list of rooms for each user.
    return self.e2eRoomMembers;
}

/**
 Make device annoucement if required.

 Send m.new_device messages to any devices we share a room with.

 (TODO: we can get rid of this once a suitable number of homeservers and
 clients support the more reliable device list update stream mechanism)
 
 @param roomsByUser the rooms and users to announce the device to.
 
 @param success A block object called when the operation succeeds.
 @param failure A block object called when the operation fails.
 */
- (MXHTTPOperation*)makeAnnoucement:(NSMutableDictionary<NSString*, NSMutableArray*> *)roomsByUser
                            success:(void (^)())success
                            failure:(void (^)(NSError *error))failure
{
    // This method is called when the initialSync was done or the session was resumed

    if (!roomsByUser)
    {
        // Catch up on any m.new_device events which arrived during the initial sync.
        [_deviceList refreshOutdatedDeviceLists];

        NSLog(@"[MXCrypto] makeAnnoucementTo: Already done");
        success();
        return nil;
    }

    // Catch up on any m.new_device events which arrived during the initial sync.
    // And force download all devices keys the user already has.
    [_deviceList invalidateUserDeviceList:myDevice.userId];
    [_deviceList refreshOutdatedDeviceLists];

    // Build a per-device message for each user
    MXUsersDevicesMap<NSDictionary*> *contentMap = [[MXUsersDevicesMap alloc] init];
    for (NSString *userId in roomsByUser)
    {
        [contentMap setObjects:@{
                                 @"*": @{
                                         @"device_id": myDevice.deviceId,
                                         @"rooms": roomsByUser[userId],
                                         }
                                 } forUser:userId];
    }

    NSLog(@"[MXCrypto] checkDeviceAnnounced: Make annoucements to %tu users and %tu devices: %@", contentMap.userIds.count, contentMap.count, contentMap);

    if (contentMap.userIds.count)
    {
        return [_matrixRestClient sendToDevice:kMXEventTypeStringNewDevice contentMap:contentMap success:^{

            NSLog(@"[MXCrypto] checkDeviceAnnounced: Annoucements done");

            [_store storeDeviceAnnounced];
            success();

        } failure:^(NSError *error) {
            NSLog(@"[MXCrypto] checkDeviceAnnounced: Annoucements failed.");
            failure(error);
        }];
    }
    else
    {
        NSLog(@"[MXCrypto] checkDeviceAnnounced: Annoucements done 2");
        [_store storeDeviceAnnounced];
    }
    
    success();
    return nil;
}

/**
 Handle a to-device event.

 @param notification the notification containing the to-device event.
 */
- (void)onToDeviceEvent:(NSNotification *)notification
{
    MXEvent *event = notification.userInfo[kMXSessionNotificationEventKey];

    NSLog(@"[MXCrypto] onToDeviceEvent %@:%@: %@", _matrixRestClient.credentials.userId, _store.deviceId, event);

    if (_cryptoQueue)
    {
        switch (event.eventType)
        {
            case MXEventTypeRoomKey:
            {
                // Room key is used for decryption. Switch to the associated queue
                dispatch_async(_decryptionQueue, ^{
                    [self onRoomKeyEvent:event];
                });
                break;
            }

            case MXEventTypeNewDevice:
            {
                dispatch_async(_cryptoQueue, ^{
                    [self onNewDeviceEvent:event];
                });
                break;
            }

            default:
                break;
        }
    }
}

/**
 Handle a key event.

 @param event the key event.
 */
- (void)onRoomKeyEvent:(MXEvent*)event
{
    if (!event.content[@"room_id"] || !event.content[@"algorithm"])
    {
        NSLog(@"[MXCrypto] onRoomKeyEvent: ERROR: Key event is missing fields");
        return;
    }

    id<MXDecrypting> alg = [self getRoomDecryptor:event.content[@"room_id"] algorithm:event.content[@"algorithm"]];
    if (!alg)
    {
        NSLog(@"[MXCrypto] onRoomKeyEvent: ERROR: Unable to handle keys for %@", event.content[@"algorithm"]);
        return;
    }

    [alg onRoomKeyEvent:event];
}

/**
 Called when a new device announces itself.

 @param event the announcement event.
 */
- (void)onNewDeviceEvent:(MXEvent*)event
{
    NSString *userId = event.sender;
    NSString *deviceId = event.content[@"device_id"];
    NSArray<NSString*> *rooms = event.content[@"rooms"];

    if (!rooms || !deviceId)
    {
        NSLog(@"[MXCrypto] onNewDeviceEvent: new_device event missing keys");
        return;
    }

    NSLog(@"[MXCrypto] onNewDeviceEvent: m.new_device event from %@:%@ for rooms %@", userId, deviceId, rooms);

    if ([_store deviceWithDeviceId:deviceId forUser:userId])
    {
        NSLog(@"[MXCrypto] onNewDeviceEvent: known device; ignoring");
        return;
    }

    [_deviceList invalidateUserDeviceList:userId];

    // We delay handling these until the intialsync has completed, so that we
    // can do all of them together.
    if (mxSession.state == MXSessionStateRunning)
    {
        [_deviceList refreshOutdatedDeviceLists];
    }
}

/**
 Handle an m.room.encryption event.

 @param event the encryption event.
 */
- (void)onCryptoEvent:(MXEvent*)event
{
    if (_cryptoQueue)
    {
        dispatch_async(_cryptoQueue, ^{
            [self setEncryptionInRoom:event.roomId withAlgorithm:event.content[@"algorithm"]];
        });
    }
};

/**
 Handle a change in the membership state of a member of a room.
 
 @param event the membership event causing the change
 */
- (void)onRoomMembership:(MXEvent*)event
{
    id<MXEncrypting> alg = roomEncryptors[event.roomId];
    if (!alg)
    {
        // No encrypting in this room
        return;
    }

    NSString *userId = event.stateKey;
    MXRoomMember *roomMember = [[mxSession roomWithRoomId:event.roomId].state memberWithUserId:userId];

    if (roomMember)
    {
        MXRoomMemberEventContent *roomMemberPrevContent = [MXRoomMemberEventContent modelFromJSON:event.prevContent];
        MXMembership oldMembership = [MXTools membership:roomMemberPrevContent.membership];
        MXMembership newMembership = roomMember.membership;

        if (_cryptoQueue)
        {
            dispatch_async(_cryptoQueue, ^{
                [alg onRoomMembership:userId oldMembership:oldMembership newMembership:newMembership];
            });
        }
    }
    else
    {
        NSLog(@"[MXCrypto] onRoomMembership: Error cannot find the room member in event: %@", event);
    }
}

/**
 Upload my user's device keys.
 */
- (MXHTTPOperation *)uploadDeviceKeys:(void (^)(MXKeysUploadResponse *keysUploadResponse))success failure:(void (^)(NSError *))failure
{
    // Sanity check
    if (!_matrixRestClient.credentials.userId)
    {
        NSLog(@"[MXCrypto] uploadDeviceKeys. ERROR: _matrixRestClient.credentials.userId cannot be nil");
        failure(nil);
        return nil;
    }

    // Prepare the device keys data to send
    // Sign it
    NSString *signature = [_olmDevice signJSON:myDevice.signalableJSONDictionary];
    myDevice.signatures = @{
                            _matrixRestClient.credentials.userId: @{
                                    [NSString stringWithFormat:@"ed25519:%@", myDevice.deviceId]: signature
                                    }
                            };

    // For now, we set the device id explicitly, as we may not be using the
    // same one as used in login.
    return [_matrixRestClient uploadKeys:myDevice.JSONDictionary oneTimeKeys:nil forDevice:myDevice.deviceId success:success failure:failure];
}

/**
 Upload my user's one time keys.
 */
- (MXHTTPOperation *)uploadOneTimeKeys:(void (^)(MXKeysUploadResponse *keysUploadResponse))success failure:(void (^)(NSError *))failure
{
    NSDictionary *oneTimeKeys = _olmDevice.oneTimeKeys;
    NSMutableDictionary *oneTimeJson = [NSMutableDictionary dictionary];

    for (NSString *keyId in oneTimeKeys[@"curve25519"])
    {
        // Sign each one-time key
        NSMutableDictionary *k = [NSMutableDictionary dictionary];
        k[@"key"] = oneTimeKeys[@"curve25519"][keyId];

        k[@"signatures"] = @{
                             myDevice.userId: @{
                                     [NSString stringWithFormat:@"ed25519:%@", myDevice.deviceId]: [_olmDevice signJSON:k]
                                     }
                             };

        oneTimeJson[[NSString stringWithFormat:@"signed_curve25519:%@", keyId]] = k;
    }

    // For now, we set the device id explicitly, as we may not be using the
    // same one as used in login.
    return [_matrixRestClient uploadKeys:nil oneTimeKeys:oneTimeJson forDevice:myDevice.deviceId success:^(MXKeysUploadResponse *keysUploadResponse) {

        lastPublishedOneTimeKeys = oneTimeKeys;
        [_olmDevice markOneTimeKeysAsPublished];
        success(keysUploadResponse);

    } failure:^(NSError *error) {
        NSLog(@"[MXCrypto] uploadOneTimeKeys fails.");
        failure(error);
    }];
}

/**
 Get a decryptor for a given room and algorithm.
 
 If we already have a decryptor for the given room and algorithm, return
 it. Otherwise try to instantiate it.
 
 @param {string?} roomId   room id for decryptor. If undefined, a temporary
 decryptor is instantiated.
 
 @param {string} algorithm  crypto algorithm
 
 @return {module:crypto.algorithms.base.DecryptionAlgorithm}
 
 @raises {module:crypto.algorithms.DecryptionError} if the algorithm is
 unknown
 */
- (id<MXDecrypting>)getRoomDecryptor:(NSString*)roomId algorithm:(NSString*)algorithm
{
    id<MXDecrypting> alg;

    if (roomId)
    {
        if (!roomDecryptors[roomId])
        {
            roomDecryptors[roomId] = [NSMutableDictionary dictionary];
        }

        alg = roomDecryptors[roomId][algorithm];
        if (alg)
        {
            return alg;
        }
    }

    Class algClass = [[MXCryptoAlgorithms sharedAlgorithms] decryptorClassForAlgorithm:algorithm];
    if (algClass)
    {
        alg = [[algClass alloc] initWithCrypto:self];

        if (roomId)
        {
            roomDecryptors[roomId][algorithm] = alg;
        }
    }

    return alg;
};

#endif

@end
