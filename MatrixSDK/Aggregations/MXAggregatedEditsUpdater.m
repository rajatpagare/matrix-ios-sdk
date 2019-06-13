/*
 Copyright 2019 The Matrix.org Foundation C.I.C

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

#import "MXAggregatedEditsUpdater.h"

#import "MXSession.h"

#import "MXEventRelations.h"
#import "MXEventReplace.h"
#import "MXEventEditsListener.h"

@interface MXAggregatedEditsUpdater ()

@property (nonatomic, weak) MXSession *mxSession;
@property (nonatomic) NSString *myUserId;
@property (nonatomic, weak) id<MXStore> matrixStore;
@property (nonatomic) NSMutableArray<MXEventEditsListener*> *listeners;

@end

@implementation MXAggregatedEditsUpdater

- (instancetype)initWithMatrixSession:(MXSession *)mxSession
                     aggregationStore:(id<MXAggregationsStore>)store
                          matrixStore:(id<MXStore>)matrixStore
{
    self = [super init];
    if (self)
    {
        self.mxSession = mxSession;
        self.myUserId = mxSession.matrixRestClient.credentials.userId;
        self.matrixStore = matrixStore;

        self.listeners = [NSMutableArray array];
    }
    return self;
}


#pragma mark - Requests

- (MXHTTPOperation*)replaceTextMessageEvent:(MXEvent*)event
                            withTextMessage:(nullable NSString*)text
                              formattedText:(nullable NSString*)formattedText
//                          localEcho:(MXEvent**)localEcho                      // TODO
                                    success:(void (^)(NSString *eventId))success
                                    failure:(void (^)(NSError *error))failure;
{
    //    NSDictionary *content = @{
    //                              @"msgtype": kMXMessageTypeText,
    //                              @"body": [NSString stringWithFormat:@"* %@", event.content[@"body"]],
    //                              @"m.new_content": @{
    //                                      @"msgtype": kMXMessageTypeText,
    //                                      @"body": text
    //                                      }
    //                              };
    //
    //    // TODO: manage a sent state like when using classic /send
    //    return [self.mxSession.matrixRestClient sendRelationToEvent:event.eventId
    //                                                         inRoom:event.roomId
    //                                                   relationType:MXEventRelationTypeReplace
    //                                                      eventType:kMXEventTypeStringRoomMessage
    //                                                     parameters:nil
    //                                                        content:content
    //                                                        success:success failure:failure];

    // Directly send a room message instead of using the `/send_relation` API to simplify local echo management for the moment.
    return [self replaceTextMessageEventUsingHack:event withTextMessage:text
                                    formattedText:formattedText
                                        localEcho:nil success:success failure:failure];
}

- (MXHTTPOperation*)replaceTextMessageEventUsingHack:(MXEvent*)event
                                     withTextMessage:(nullable NSString*)text
                                       formattedText:(nullable NSString*)formattedText
                                           localEcho:(MXEvent**)localEcho
                                             success:(void (^)(NSString *eventId))success
                                             failure:(void (^)(NSError *error))failure
{
    NSLog(@"[MXAggregations] replaceTextMessageEvent using hack");

    NSString *roomId = event.roomId;
    MXRoom *room = [self.mxSession roomWithRoomId:roomId];
    if (!room)
    {
        NSLog(@"[MXAggregations] replaceTextMessageEvent using hack Error: Unknown room: %@", roomId);
        failure(nil);
        return nil;
    }

    NSString *messageType = event.content[@"msgtype"];

    if (![messageType isEqualToString:kMXMessageTypeText])
    {
        NSLog(@"[MXAggregations] replaceTextMessageEvent using hack. Error: Only message type %@ is supported", kMXMessageTypeText);
        failure(nil);
        return nil;
    }

    NSMutableDictionary *content = [NSMutableDictionary new];
    NSMutableDictionary *compatibilityContent = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                                @"msgtype": kMXMessageTypeText,
                                                                                                @"body": [NSString stringWithFormat:@"* %@", text]
                                                                                                }];

    NSMutableDictionary *newContent = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"msgtype": kMXMessageTypeText,
                                                                                      @"body": text
                                                                                      }];


    if (formattedText)
    {
        // Send the HTML formatted string

        [compatibilityContent addEntriesFromDictionary:@{
                                                         @"formatted_body": [NSString stringWithFormat:@"* %@", formattedText],
                                                         @"format": kMXRoomMessageFormatHTML
                                                         }];


        [newContent addEntriesFromDictionary:@{
                                               @"formatted_body": formattedText,
                                               @"format": kMXRoomMessageFormatHTML
                                               }];
    }


    [content addEntriesFromDictionary:compatibilityContent];

    content[@"m.new_content"] = newContent;

    content[@"m.relates_to"] = @{
                                 @"rel_type" : @"m.replace",
                                 @"event_id": event.eventId
                                 };

    return [room sendEventOfType:kMXEventTypeStringRoomMessage content:content localEcho:nil success:success failure:failure];
}


#pragma mark - Data update listener

- (id)listenToEditsUpdateInRoom:(NSString *)roomId block:(void (^)(MXEvent* replaceEvent))block
{
    MXEventEditsListener *listener = [MXEventEditsListener new];
    listener.roomId = roomId;
    listener.notificationBlock = block;
    
    [self.listeners addObject:listener];
    
    return listener;
}

- (void)removeListener:(id)listener
{
    [self.listeners removeObject:listener];
}

#pragma mark - Data update

- (void)handleReplace:(MXEvent *)replaceEvent
{
    NSString *roomId = replaceEvent.roomId;
    MXEvent *event = [self.matrixStore eventWithEventId:replaceEvent.relatesTo.eventId inRoom:roomId];
    
    if (![event.unsignedData.relations.replace.eventId isEqualToString:replaceEvent.eventId])
    {
        MXEvent *editedEvent = [event editedEventFromReplacementEvent:replaceEvent];
        
        if (editedEvent)
        {
            [self.matrixStore replaceEvent:editedEvent inRoom:roomId];
            [self notifyEventEditsListenersOfRoom:roomId replaceEvent:replaceEvent];
        }
    }
}

//- (void)handleRedaction:(MXEvent *)event
//{
//}

#pragma mark - Private

- (void)notifyEventEditsListenersOfRoom:(NSString*)roomId replaceEvent:(MXEvent*)replaceEvent
{
    for (MXEventEditsListener *listener in self.listeners)
    {
        if ([listener.roomId isEqualToString:roomId])
        {
            listener.notificationBlock(replaceEvent);
        }
    }
}

@end
