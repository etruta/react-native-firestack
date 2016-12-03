//
//  FirestackDatabase.m
//  Firestack
//
//  Created by Ari Lerner on 8/23/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import "Firestack.h"
#import "FirestackDatabase.h"
#import "FirestackEvents.h"

@interface FirestackDBReference : NSObject
@property RCTEventEmitter *emitter;
@property FIRDatabaseQuery *query;
@property NSString *path;
@property NSString *modifiersString;
@property NSMutableDictionary *listeners;
@property FIRDatabaseHandle childAddedHandler;
@property FIRDatabaseHandle childModifiedHandler;
@property FIRDatabaseHandle childRemovedHandler;
@property FIRDatabaseHandle childMovedHandler;
@property FIRDatabaseHandle childValueHandler;
@end

@implementation FirestackDBReference

- (id) initWithPathAndModifiers:(RCTEventEmitter *) emitter
                       database:(FIRDatabase *) database
                           path:(NSString *) path
                      modifiers:(NSArray *) modifiers
                modifiersString:(NSString *) modifiersString
{
  self = [super init];
  if (self) {
      _emitter = emitter;
      _path = path;
      _modifiersString = modifiersString;
      _query = [self buildQueryAtPathWithModifiers:database path:path modifiers:modifiers];
      _listeners = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (void) addEventHandler:(NSString *) eventName
{
    if (![self isListeningTo:eventName]) {
        id withBlock = ^(FIRDataSnapshot * _Nonnull snapshot) {
            NSDictionary *props = [self snapshotToDict:snapshot];
            [self sendJSEvent:DATABASE_DATA_EVENT
                        title:eventName
                        props: @{
                                 @"eventName": eventName,
                                 @"path": _path,
                                 @"modifiersString": _modifiersString,
                                 @"snapshot": props
                                 }];
        };
        
        id errorBlock = ^(NSError * _Nonnull error) {
            NSLog(@"Error onDBEvent: %@", [error debugDescription]);
            [self getAndSendDatabaseError:error withPath: _path];
        };
        
        int eventType = [self eventTypeFromName:eventName];
        FIRDatabaseHandle handle = [_query observeEventType:eventType
                                                  withBlock:withBlock
                                            withCancelBlock:errorBlock];
        [self setEventHandler:handle forName:eventName];
    } else {
        NSLog(@"Warning Trying to add duplicate listener for type: %@ with modifiers: %@ for path: %@", eventName, _modifiersString, _path);
    }
}

- (void) addSingleEventHandler:(RCTResponseSenderBlock) callback
{
    [_query observeSingleEventOfType:FIRDataEventTypeValue
                           withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
                               NSDictionary *props = [self snapshotToDict:snapshot];
                               callback(@[[NSNull null], @{
                                              @"eventName": @"value",
                                              @"path": _path,
                                              @"modifiersString": _modifiersString,
                                              @"snapshot": props
                                              }]);
                           }
                     withCancelBlock:^(NSError * _Nonnull error) {
                         NSLog(@"Error onDBEventOnce: %@", [error debugDescription]);
                         callback(@[@{
                                     @"error": @"onceError",
                                     @"msg": [error debugDescription]
                                     }]);
                  }];
}

- (void) removeEventHandler:(NSString *) name
{
    int eventType = [self eventTypeFromName:name];
    switch (eventType) {
        case FIRDataEventTypeValue:
            if (self.childValueHandler != nil) {
                [_query removeObserverWithHandle:self.childValueHandler];
                self.childValueHandler = nil;
            }
            break;
        case FIRDataEventTypeChildAdded:
            if (self.childAddedHandler != nil) {
                [_query removeObserverWithHandle:self.childAddedHandler];
                self.childAddedHandler = nil;
            }
            break;
        case FIRDataEventTypeChildChanged:
            if (self.childModifiedHandler != nil) {
                [_query removeObserverWithHandle:self.childModifiedHandler];
                self.childModifiedHandler = nil;
            }
            break;
        case FIRDataEventTypeChildRemoved:
            if (self.childRemovedHandler != nil) {
                [_query removeObserverWithHandle:self.childRemovedHandler];
                self.childRemovedHandler = nil;
            }
            break;
        case FIRDataEventTypeChildMoved:
            if (self.childMovedHandler != nil) {
                [_query removeObserverWithHandle:self.childMovedHandler];
                self.childMovedHandler = nil;
            }
            break;
        default:
            break;
    }
    [self unsetListeningOn:name];
}

- (NSDictionary *) snapshotToDict:(FIRDataSnapshot *) snapshot
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    [dict setValue:snapshot.key forKey:@"key"];
    NSDictionary *val = snapshot.value;
    [dict setObject:val forKey:@"value"];
    
    // Snapshot ordering
    NSMutableArray *childKeys = [NSMutableArray array];
    if (snapshot.childrenCount > 0) {
        // Since JS does not respect object ordering of keys
        // we keep a list of the keys and their ordering
        // in the snapshot event
        NSEnumerator *children = [snapshot children];
        FIRDataSnapshot *child;
        while(child = [children nextObject]) {
            [childKeys addObject:child.key];
        }
    }
    
    [dict setObject:childKeys forKey:@"childKeys"];
    [dict setValue:@(snapshot.hasChildren) forKey:@"hasChildren"];
    [dict setValue:@(snapshot.exists) forKey:@"exists"];
    [dict setValue:@(snapshot.childrenCount) forKey:@"childrenCount"];
    [dict setValue:snapshot.priority forKey:@"priority"];
    
    return dict;
}

- (NSDictionary *) getAndSendDatabaseError:(NSError *) error
                                  withPath:(NSString *) path
{
    NSDictionary *evt = @{
                          @"eventName": DATABASE_ERROR_EVENT,
                          @"path": path,
                          @"msg": [error debugDescription]
                          };
    [self sendJSEvent:DATABASE_ERROR_EVENT title:DATABASE_ERROR_EVENT props: evt];
    
    return evt;
}

- (void) sendJSEvent:(NSString *)type
               title:(NSString *)title
               props:(NSDictionary *)props
{
    @try {
        [_emitter sendEventWithName:type
                               body:@{
                                      @"eventName": title,
                                      @"body": props
                                      }];
    }
    @catch (NSException *err) {
        NSLog(@"An error occurred in sendJSEvent: %@", [err debugDescription]);
        NSLog(@"Tried to send: %@ with %@", title, props);
    }
}


- (FIRDatabaseQuery *) buildQueryAtPathWithModifiers:(FIRDatabase*) database
                                                path:(NSString*) path
                                           modifiers:(NSArray *) modifiers
{
    FIRDatabaseQuery *query = [[database reference] child:path];

    for (NSString *str in modifiers) {
        if ([str isEqualToString:@"orderByKey"]) {
            query = [query queryOrderedByKey];
        } else if ([str isEqualToString:@"orderByPriority"]) {
            query = [query queryOrderedByPriority];
        } else if ([str isEqualToString:@"orderByValue"]) {
            query = [query queryOrderedByValue];
        } else if ([str containsString:@"orderByChild"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            NSString *key = args[1];
            query = [query queryOrderedByChild:key];
        } else if ([str containsString:@"limitToLast"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            NSString *key = args[1];
            NSUInteger limit = key.integerValue;
            query = [query queryLimitedToLast:limit];
        } else if ([str containsString:@"limitToFirst"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            NSString *key = args[1];
            NSUInteger limit = key.integerValue;
            query = [query queryLimitedToFirst:limit];
        } else if ([str containsString:@"equalTo"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            int size = (int)[args count];;
            id value = [self getIdValue:args[1]];
            if (size > 2) {
                NSString *key = args[2];
                query = [query queryEqualToValue:value
                                        childKey:key];
            } else {
                query = [query queryEqualToValue:value];
            }
        } else if ([str containsString:@"endAt"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            int size = (int)[args count];;
            id value = [self getIdValue:args[1]];
            if (size > 2) {
                NSString *key = args[2];
                query = [query queryEndingAtValue:value
                                         childKey:key];
            } else {
                query = [query queryEndingAtValue:value];
            }
        } else if ([str containsString:@"startAt"]) {
            NSArray *args = [str componentsSeparatedByString:@":"];
            id value = [self getIdValue:args[1]];
            int size = (int)[args count];;
            if (size > 2) {
                NSString *key = args[2];
                query = [query queryStartingAtValue:value
                                           childKey:key];
            } else {
                query = [query queryStartingAtValue:value];
            }
        }
    }

    return query;
}

- (id) getIdValue:(NSString *) value
{
    if (value.integerValue != nil) {
        return [NSNumber numberWithInteger:value.integerValue];
    } else if ([value isEqualToString:@"true"] || [value isEqualToString:@"false"]) {
        return [NSNumber numberWithBool:value.boolValue];
    } else {
        return value;
    }
}

- (void) setEventHandler:(FIRDatabaseHandle) handle
                 forName:(NSString *) name
{
    int eventType = [self eventTypeFromName:name];
    switch (eventType) {
        case FIRDataEventTypeValue:
            self.childValueHandler = handle;
            break;
        case FIRDataEventTypeChildAdded:
            self.childAddedHandler = handle;
            break;
        case FIRDataEventTypeChildChanged:
            self.childModifiedHandler = handle;
            break;
        case FIRDataEventTypeChildRemoved:
            self.childRemovedHandler = handle;
            break;
        case FIRDataEventTypeChildMoved:
            self.childMovedHandler = handle;
            break;
        default:
            break;
    }
    [self setListeningOn:name withHandle:handle];
}

- (void) setListeningOn:(NSString *) name
             withHandle:(FIRDatabaseHandle) handle
{
    [_listeners setValue:@(handle) forKey:name];
}

- (void) unsetListeningOn:(NSString *) name
{
    [_listeners removeObjectForKey:name];
}

- (BOOL) isListeningTo:(NSString *) name
{
  return [_listeners valueForKey:name] != nil;
}

- (BOOL) hasListeners
{
    return [[_listeners allKeys] count] > 0;
}

- (NSArray *) listenerKeys
{
    return [_listeners allKeys];
}

- (int) eventTypeFromName:(NSString *)name
{
    int eventType = FIRDataEventTypeValue;

    if ([name isEqualToString:DATABASE_VALUE_EVENT]) {
        eventType = FIRDataEventTypeValue;
    } else if ([name isEqualToString:DATABASE_CHILD_ADDED_EVENT]) {
        eventType = FIRDataEventTypeChildAdded;
    } else if ([name isEqualToString:DATABASE_CHILD_MODIFIED_EVENT]) {
        eventType = FIRDataEventTypeChildChanged;
    } else if ([name isEqualToString:DATABASE_CHILD_REMOVED_EVENT]) {
        eventType = FIRDataEventTypeChildRemoved;
    } else if ([name isEqualToString:DATABASE_CHILD_MOVED_EVENT]) {
        eventType = FIRDataEventTypeChildMoved;
    }
    return eventType;
}

- (void) cleanup {
    if (self.childValueHandler > 0) {
        [self removeEventHandler:DATABASE_VALUE_EVENT];
    }
    if (self.childAddedHandler > 0) {
        [self removeEventHandler:DATABASE_CHILD_ADDED_EVENT];
    }
    if (self.childModifiedHandler > 0) {
        [self removeEventHandler:DATABASE_CHILD_MODIFIED_EVENT];
    }
    if (self.childRemovedHandler > 0) {
        [self removeEventHandler:DATABASE_CHILD_REMOVED_EVENT];
    }
    if (self.childMovedHandler > 0) {
        [self removeEventHandler:DATABASE_CHILD_MOVED_EVENT];
    }
}

@end

@implementation FirestackDatabase

RCT_EXPORT_MODULE(FirestackDatabase);

- (id) init
{
    self = [super init];
    if (self != nil) {
        _database = [FIRDatabase database];
        _dbReferences = [[NSMutableDictionary alloc] init];
    }
    return self;
}

RCT_EXPORT_METHOD(enablePersistence:(BOOL) enable
  callback:(RCTResponseSenderBlock) callback)
{

  BOOL isEnabled = _database.persistenceEnabled;
  if ( isEnabled != enable) {
      _database.persistenceEnabled = enable;
  }
  callback(@[[NSNull null], @{
                 @"result": @"success"
                 }]);
}

RCT_EXPORT_METHOD(keepSynced:(NSString *) path
  withEnable:(BOOL) enable
  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref keepSynced:enable];
    callback(@[[NSNull null], @{
                            @"status": @"success",
                            @"path": path
                            }]);
}

RCT_EXPORT_METHOD(set:(NSString *) path
                  value:(NSDictionary *)value
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];

    [ref setValue:value withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
        [self handleCallback:@"set" callback:callback databaseError:error];
    }];
}

RCT_EXPORT_METHOD(update:(NSString *) path
                  value:(NSDictionary *)value
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];

    [ref updateChildValues:value withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
        [self handleCallback:@"update" callback:callback databaseError:error];
    }];
}

RCT_EXPORT_METHOD(remove:(NSString *) path
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref removeValueWithCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
        [self handleCallback:@"remove" callback:callback databaseError:error];
    }];
}

RCT_EXPORT_METHOD(push:(NSString *) path
                  props:(NSDictionary *) props
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    FIRDatabaseReference *newRef = [ref childByAutoId];

    NSURL *url = [NSURL URLWithString:ref.URL];
    NSString *newPath = [url path];

    if ([props count] > 0) {
        [newRef setValue:props withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
            if (error != nil) {
                // Error handling
                NSDictionary *evt = @{
                                      @"errorCode": [NSNumber numberWithInt:[error code]],
                                      @"errorDetails": [error debugDescription],
                                      @"description": [error description]
                                      };

                callback(@[evt]);
            } else {
                callback(@[[NSNull null], @{
                               @"status": @"success",
                               @"ref": newPath
                               }]);
            }
        }];
    } else {
        callback(@[[NSNull null], @{
                       @"status": @"success",
                       @"ref": newPath
                       }]);
    }
}



RCT_EXPORT_METHOD(on:(NSString *) path
                  modifiersString:(NSString *) modifiersString
                  modifiers:(NSArray *) modifiers
                  name:(NSString *) eventName
                  callback:(RCTResponseSenderBlock) callback)
{
    FirestackDBReference *ref = [self getDBHandle:path modifiers:modifiers modifiersString:modifiersString];
    [ref addEventHandler:eventName];
    
    callback(@[[NSNull null], @{
                   @"status": @"success",
                   @"handle": path
                   }]);
}

RCT_EXPORT_METHOD(onOnce:(NSString *) path
         modifiersString:(NSString *) modifiersString
               modifiers:(NSArray *) modifiers
                    name:(NSString *) name
                callback:(RCTResponseSenderBlock) callback)
{
    FirestackDBReference *ref = [self getDBHandle:path modifiers:modifiers modifiersString:modifiersString];
    [ref addSingleEventHandler:callback];
}

RCT_EXPORT_METHOD(off:(NSString *)path
                  modifiersString:(NSString *) modifiersString
                  eventName:(NSString *) eventName
                  callback:(RCTResponseSenderBlock) callback)
{
    NSString *key = [self getDBListenerKey:path withModifiers:modifiersString];
    FirestackDBReference *ref = [_dbReferences objectForKey:key];
    
    if (ref != nil) {
        if (eventName == nil || [eventName isEqualToString:@""]) {
            [ref cleanup];
            [_dbReferences removeObjectForKey:key];
        } else {
            [ref removeEventHandler:eventName];
            if (![ref hasListeners]) {
                [_dbReferences removeObjectForKey:key];
            }
        }
    }
    
    callback(@[[NSNull null], @{
                   @"result": @"success",
                   @"handle": path,
                   @"modifiersString": modifiersString,
                   @"remainingListeners": [ref listenerKeys],
                   }]);
}

// On disconnect
RCT_EXPORT_METHOD(onDisconnectSetObject:(NSString *) path
                  props:(NSDictionary *) props
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref onDisconnectSetValue:props
          withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
              [self handleCallback:@"onDisconnectSetObject" callback:callback databaseError:error];
          }];
}

RCT_EXPORT_METHOD(onDisconnectSetString:(NSString *) path
                  val:(NSString *) val
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref onDisconnectSetValue:val
          withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
              [self handleCallback:@"onDisconnectSetString" callback:callback databaseError:error];
          }];
}

RCT_EXPORT_METHOD(onDisconnectRemove:(NSString *) path
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref onDisconnectRemoveValueWithCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
        [self handleCallback:@"onDisconnectRemove" callback:callback databaseError:error];
    }];
}



RCT_EXPORT_METHOD(onDisconnectCancel:(NSString *) path
                  callback:(RCTResponseSenderBlock) callback)
{
    FIRDatabaseReference *ref = [[_database reference] child:path];
    [ref cancelDisconnectOperationsWithCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
        [self handleCallback:@"onDisconnectCancel" callback:callback databaseError:error];
    }];
}

- (void) handleCallback:(NSString *) methodName
               callback:(RCTResponseSenderBlock) callback
          databaseError:(NSError *) databaseError
{
    if (databaseError != nil) {
        NSDictionary *evt = @{
                              @"errorCode": [NSNumber numberWithInt:[databaseError code]],
                              @"errorDetails": [databaseError debugDescription],
                              @"description": [databaseError description]
                              };
        callback(@[evt]);
    } else {
        callback(@[[NSNull null], @{
                       @"status": @"success",
                       @"method": methodName
                       }]);
    }
}

- (FirestackDBReference *) getDBHandle:(NSString *) path
                             modifiers:modifiers
                       modifiersString:modifiersString
{
    NSString *key = [self getDBListenerKey:path withModifiers:modifiersString];
    FirestackDBReference *ref = [_dbReferences objectForKey:key];

    if (ref == nil) {
        ref = [[FirestackDBReference alloc] initWithPathAndModifiers:self
                                                            database:_database
                                                                path:path
                                                           modifiers:modifiers
                                                     modifiersString:modifiersString];
        [_dbReferences setObject:ref forKey:key];
    }
    return ref;
}

- (NSString *) getDBListenerKey:(NSString *) path
                  withModifiers:(NSString *) modifiersString
{
    return [NSString stringWithFormat:@"%@ | %@", path, modifiersString, nil];
}

// Not sure how to get away from this... yet
- (NSArray<NSString *> *)supportedEvents {
    return @[DATABASE_DATA_EVENT, DATABASE_ERROR_EVENT];
}

@end