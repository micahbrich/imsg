//
//  IMsgInjected.m
//  IMsgHelper - Injectable dylib for Messages.app
//
//  This dylib is injected into Messages.app via DYLD_INSERT_LIBRARIES
//  to gain access to IMCore's chat registry and messaging functions.
//  It provides a Unix socket server for IPC with the CLI.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

#pragma mark - Constants

// File-based IPC paths (in container for sandbox compatibility)
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
static dispatch_source_t fileWatchSource = nil;
static NSTimer *fileWatchTimer = nil;
static int lockFd = -1;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Use container path which Messages.app can write to
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-ready"];
    }
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
- (id)chatForIMHandles:(NSArray *)handles;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (id)messageForGUID:(NSString *)guid;
- (void)sendMessage:(id)message;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (NSString *)displayName;
- (void)_setDisplayName:(NSString *)name;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
@end

@interface IMServiceImpl : NSObject
+ (instancetype)iMessageService;
+ (instancetype)smsService;
@end

@interface IMAccount : NSObject
- (id)imHandleWithID:(NSString *)handleID;
@end

@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
- (id)bestAccountForService:(id)service;
@end

#pragma mark - Runtime Method Injection

// Provide missing isEditedMessageHistory method for IMMessageItem compatibility
static BOOL IMMessageItem_isEditedMessageHistory(id self, SEL _cmd) {
    // Return NO as default - this message is not an edited message history item
    return NO;
}

static void injectCompatibilityMethods(void) {
    SEL selector = @selector(isEditedMessageHistory);

    // Add isEditedMessageHistory to IMMessageItem if it doesn't exist
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (IMMessageItemClass) {
        if (![IMMessageItemClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageItemClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessageItem");
        }
    }

    // Also add to IMMessage class (different from IMMessageItem)
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    if (IMMessageClass) {
        if (![IMMessageClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessage");
        }
    }
}

#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Chat Resolution

// Try multiple methods to find a chat, similar to BlueBubbles approach
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-plus] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-plus] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;

    // Method 1: Try existingChatWithGUID: (BlueBubbles approach)
    // This expects full GUID like "iMessage;-;email@example.com"
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        // If identifier already looks like a GUID, use it directly
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes
        NSArray *prefixes = @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;"];
        for (NSString *prefix in prefixes) {
            NSString *fullGUID = [prefix stringByAppendingString:identifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-plus] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
    }

    // Method 3: Iterate all chats and match by participant (exact matching only)
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) {
            NSLog(@"[imsg-plus] allExistingChats returned nil");
            return nil;
        }
        NSLog(@"[imsg-plus] Searching %lu chats for identifier: %@", (unsigned long)allChats.count, identifier);

        // Normalize the search identifier (strip non-digit chars for phone numbers)
        NSString *normalizedIdentifier = nil;
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[identifier characterAtIndex:0]]) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < identifier.length; i++) {
                unichar c = [identifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID — exact match only
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier — exact match only
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants — exact or normalized phone match
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                if (!participants) {
                    continue;
                }
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        // Exact match
                        if ([handleID isEqualToString:identifier]) {
                            NSLog(@"[imsg-plus] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match (compare digits only)
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                [handleDigits hasSuffix:normalizedIdentifier] ||
                                [normalizedIdentifier hasSuffix:handleDigits]) {
                                NSLog(@"[imsg-plus] Found chat by normalized phone match: %@ ~ %@", handleID, identifier);
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-plus] Chat not found for identifier: %@", identifier);
    return nil;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Check if chat supports typing indicators
        BOOL supportsTyping = YES;
        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
            NSLog(@"[imsg-plus] Chat supports typing indicators: %@", supportsTyping ? @"YES" : @"NO");
        }

        // Use setLocalUserIsTyping: (simpler and more reliable)
        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            if (!sig) {
                return errorResponse(requestId, @"Could not get method signature for setLocalUserIsTyping:");
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            NSLog(@"[imsg-plus] Called setLocalUserIsTyping:%@ for %@", typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing),
                @"supports_typing": @(supportsTyping)
            });
        }

        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSLog(@"[imsg-plus] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

// Helper to write a response dictionary to the response file (for async handlers)
static void writeResponseToFile(NSDictionary *response) {
    initFilePaths();
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
    [responseData writeToFile:kResponseFile atomically:YES];
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[imsg-plus] Wrote async response to file");
}

// Map reaction type to verb string for summary text
static NSString* reactionVerb(long long reactionType) {
    // For removals (3000+), use the same verb as the base type
    long long baseType = reactionType >= 3000 ? reactionType - 1000 : reactionType;
    switch (baseType) {
        case 2000: return @"Loved ";
        case 2001: return @"Liked ";
        case 2002: return @"Disliked ";
        case 2003: return @"Laughed at ";
        case 2004: return @"Emphasized ";
        case 2005: return @"Questioned ";
        default:   return @"Reacted to ";
    }
}

// handleReact returns nil when it handles the response asynchronously
static NSDictionary* handleReact(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];
    NSString *emoji = params[@"emoji"];  // Custom emoji string (for type 2006/3006)
    NSNumber *partIndexNum = params[@"partIndex"];
    int partIndex = partIndexNum ? [partIndexNum intValue] : 0;

    if (!handle || !messageGUID || !type) {
        return errorResponse(requestId, @"Missing required parameters: handle, guid, type");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Get IMChatHistoryController to load the message by GUID asynchronously
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ via IMChatHistoryController (async)...", messageGUID);

    // Capture values for the completion block
    long long reactionType = [type longLongValue];

    // Build and invoke the async load call
    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    // The completion block receives the loaded IMMessage
    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] loadMessageWithGUID completion fired, message=%@, class=%@",
                  message, message ? [message class] : @"nil");

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Get IMMessageItem and chat items from the message
                id messageItem = [message valueForKey:@"_imMessageItem"];
                NSLog(@"[imsg-plus] messageItem class: %@", messageItem ? [messageItem class] : @"nil");

                id items = nil;
                if (messageItem && [messageItem respondsToSelector:@selector(_newChatItems)]) {
                    items = [messageItem performSelector:@selector(_newChatItems)];
                } else if (messageItem) {
                    items = [messageItem valueForKey:@"_newChatItems"];
                }
                NSLog(@"[imsg-plus] _newChatItems: %@ (class: %@)", items, items ? [items class] : @"nil");

                // Find the IMMessagePartChatItem at partIndex
                id partItem = nil;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *itemArray = (NSArray *)items;
                    NSLog(@"[imsg-plus] Got %lu chat items from message", (unsigned long)itemArray.count);
                    for (id item in itemArray) {
                        // Look for IMMessagePartChatItem or IMTextMessagePartChatItem
                        NSString *className = NSStringFromClass([item class]);
                        if ([className containsString:@"MessagePartChatItem"] ||
                            [className containsString:@"TextMessagePartChatItem"]) {
                            // Check if this is the right part index
                            if ([item respondsToSelector:@selector(index)]) {
                                NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                if (idx == partIndex) {
                                    partItem = item;
                                    break;
                                }
                            } else if (partIndex == 0) {
                                // Default: use first matching item
                                partItem = item;
                                break;
                            }
                        }
                    }
                    // Fallback: if no specific part found, use first item
                    if (!partItem && itemArray.count > 0) {
                        partItem = itemArray[partIndex < (int)itemArray.count ? partIndex : 0];
                    }
                } else if (items) {
                    partItem = items;
                }

                NSLog(@"[imsg-plus] partItem: %@ (class: %@)", partItem, partItem ? [partItem class] : @"nil");

                // Get text for the summary
                NSAttributedString *itemText = nil;
                if (partItem && [partItem respondsToSelector:@selector(text)]) {
                    itemText = [partItem performSelector:@selector(text)];
                }
                if (!itemText && [message respondsToSelector:@selector(text)]) {
                    itemText = [message performSelector:@selector(text)];
                }
                NSString *summaryText = itemText ? itemText.string : @"";
                if (!summaryText) summaryText = @"";
                NSLog(@"[imsg-plus] summaryText: %@", summaryText);

                // Build the associated GUID: p:PARTINDEX/MESSAGE_GUID
                NSString *associatedGuid = [NSString stringWithFormat:@"p:%d/%@", partIndex, messageGUID];
                NSLog(@"[imsg-plus] associatedGuid: %@", associatedGuid);

                // Build message summary info
                NSMutableDictionary *messageSummary = [@{@"amc": @1, @"ams": summaryText} mutableCopy];
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    messageSummary[@"ame"] = emoji;
                }

                // Build the reaction text
                NSString *reactionString;
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    // Custom emoji: "Reacted 🎉 to "message text""
                    reactionString = [NSString stringWithFormat:@"Reacted %@ to \u201c%@\u201d", emoji, summaryText];
                } else {
                    // Standard tapback: "Loved "message text""
                    NSString *verb = reactionVerb(reactionType);
                    reactionString = [verb stringByAppendingString:
                        [NSString stringWithFormat:@"\u201c%@\u201d", summaryText]];
                }
                NSMutableAttributedString *reactionText =
                    [[NSMutableAttributedString alloc] initWithString:reactionString];

                // Get messagePartRange from the part item
                NSRange partRange = NSMakeRange(0, summaryText.length);
                if (partItem) {
                    SEL rangeSel = @selector(messagePartRange);
                    if ([partItem respondsToSelector:rangeSel]) {
                        NSMethodSignature *sig = [partItem methodSignatureForSelector:rangeSel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:rangeSel];
                        [inv setTarget:partItem];
                        [inv invoke];
                        [inv getReturnValue:&partRange];
                        NSLog(@"[imsg-plus] messagePartRange: {%lu, %lu}",
                              (unsigned long)partRange.location, (unsigned long)partRange.length);
                    }
                }

                // Create the IMMessage for the reaction using the long init method
                Class IMMessageClass = NSClassFromString(@"IMMessage");
                if (!IMMessageClass) {
                    writeResponseToFile(errorResponse(requestId, @"IMMessage class not found"));
                    return;
                }

                id reactionMessage = [IMMessageClass alloc];

                // The init selector with associated message fields
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);

                if (![reactionMessage respondsToSelector:initSel]) {
                    NSLog(@"[imsg-plus] Long init selector not available, dumping IMMessage init methods...");
                    unsigned int methodCount;
                    Method *methods = class_copyMethodList(IMMessageClass, &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name hasPrefix:@"initWith"]) {
                            NSLog(@"[imsg-plus]   %@", name);
                        }
                    }
                    free(methods);
                    writeResponseToFile(errorResponse(requestId,
                        @"IMMessage initWithSender:time:text:...associatedMessage... selector not found"));
                    return;
                }

                // Use objc_msgSend with the correct type signature
                // Args: self, _cmd, sender(id), time(id), text(id), messageSubject(id),
                //        fileTransferGUIDs(id), flags(unsigned long long), error(id),
                //        guid(id), subject(id), associatedMessageGUID(id),
                //        associatedMessageType(long long), associatedMessageRange(NSRange),
                //        messageSummaryInfo(id)
                typedef id (*InitMsgSendType)(id, SEL,
                    id,                  // sender
                    id,                  // time
                    id,                  // text
                    id,                  // messageSubject
                    id,                  // fileTransferGUIDs
                    unsigned long long,  // flags
                    id,                  // error
                    id,                  // guid
                    id,                  // subject
                    id,                  // associatedMessageGUID
                    long long,           // associatedMessageType
                    NSRange,             // associatedMessageRange
                    id                   // messageSummaryInfo
                );

                InitMsgSendType initMsgSend = (InitMsgSendType)objc_msgSend;
                reactionMessage = initMsgSend(reactionMessage, initSel,
                    nil,                     // sender
                    nil,                     // time
                    reactionText,            // text
                    nil,                     // messageSubject
                    nil,                     // fileTransferGUIDs
                    (unsigned long long)0x5, // flags
                    nil,                     // error
                    nil,                     // guid
                    nil,                     // subject
                    associatedGuid,          // associatedMessageGUID
                    reactionType,            // associatedMessageType
                    partRange,               // associatedMessageRange
                    messageSummary           // messageSummaryInfo
                );

                if (!reactionMessage) {
                    writeResponseToFile(errorResponse(requestId, @"Failed to create reaction IMMessage (init returned nil)"));
                    return;
                }

                NSLog(@"[imsg-plus] Created reaction message: %@ (class: %@)", reactionMessage, [reactionMessage class]);

                // Set associated emoji for custom emoji reactions (type 2006/3006)
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    @try {
                        [reactionMessage setValue:emoji forKey:@"associatedMessageEmoji"];
                        NSLog(@"[imsg-plus] Set associatedMessageEmoji = %@", emoji);
                    } @catch (NSException *e) {
                        NSLog(@"[imsg-plus] ⚠️ Could not set associatedMessageEmoji via KVC: %@", e.reason);
                        // Try underscore-prefixed ivar as fallback
                        @try {
                            [reactionMessage setValue:emoji forKey:@"_associatedMessageEmoji"];
                            NSLog(@"[imsg-plus] Set _associatedMessageEmoji = %@", emoji);
                        } @catch (NSException *e2) {
                            NSLog(@"[imsg-plus] ⚠️ Could not set _associatedMessageEmoji either: %@", e2.reason);
                        }
                    }
                }

                // Send the reaction message
                SEL sendSel = @selector(sendMessage:);
                if (![chat respondsToSelector:sendSel]) {
                    writeResponseToFile(errorResponse(requestId, @"Chat does not respond to sendMessage:"));
                    return;
                }

                [chat performSelector:sendSel withObject:reactionMessage];
                NSLog(@"[imsg-plus] ✅ Sent reaction message via sendMessage:");

                NSMutableDictionary *resultDict = [@{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"partIndex": @(partIndex),
                    @"action": reactionType >= 3000 ? @"removed" : @"added",
                    @"method": @"createMessage_BlueBubbles"
                } mutableCopy];
                if (emoji) {
                    resultDict[@"emoji"] = emoji;
                }
                writeResponseToFile(successResponse(requestId, resultDict));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in react completion: %@\n%@", exception.reason, exception.callStackSymbols);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed in react completion: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    NSLog(@"[imsg-plus] loadMessageWithGUID invoked, waiting for async completion...");

    // Set a 5-second timeout: if the completion block never fires (e.g. invalid GUID),
    // write an error response so the CLI doesn't hang indefinitely.
    __block BOOL completionFired = NO;
    // Patch the completion block to track if it fired
    void (^originalBlock)(id) = completionBlock;
    completionBlock = nil; // Release our reference; loadInv already retained it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Check if response file has been written (completion fired)
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ React completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: message GUID not found or completion never fired: %@", messageGUID]));
        }
    });

    // Return nil to signal async handling — processCommandFile will check for this
    return nil;
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    BOOL hasAccountController = (NSClassFromString(@"IMAccountController") != nil);
    BOOL hasServiceImpl = (NSClassFromString(@"IMServiceImpl") != nil);
    BOOL canCreateChat = hasRegistry && hasAccountController && hasServiceImpl;

    NSMutableDictionary *result = [@{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"tapback_available": @(hasRegistry),
        @"create_chat_available": @(canCreateChat),
        @"rename_chat_available": @(hasRegistry),
        @"send_message_available": @(hasRegistry),
        @"thread_reply_available": @(hasRegistry),
        @"edit_message_available": @(hasRegistry),
        @"unsend_message_available": @(hasRegistry)
    } mutableCopy];
    return successResponse(requestId, result);
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

static NSDictionary* handleCreateChat(NSInteger requestId, NSDictionary *params) {
    NSArray *addresses = params[@"addresses"];
    NSString *name = params[@"name"];
    NSString *text = params[@"text"];
    NSString *serviceHint = params[@"service"] ?: @"imessage";

    if (!addresses || ![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing required parameter: addresses (array of phone/email)");
    }

    @try {
        // Get the appropriate service
        Class serviceClass = NSClassFromString(@"IMServiceImpl");
        if (!serviceClass) {
            return errorResponse(requestId, @"IMServiceImpl class not found");
        }

        id service = nil;
        if ([serviceHint isEqualToString:@"sms"]) {
            service = [serviceClass performSelector:@selector(smsService)];
        } else {
            service = [serviceClass performSelector:@selector(iMessageService)];
        }
        if (!service) {
            return errorResponse(requestId, @"Could not get service instance");
        }

        // Get account for the service
        Class accountControllerClass = NSClassFromString(@"IMAccountController");
        if (!accountControllerClass) {
            return errorResponse(requestId, @"IMAccountController class not found");
        }

        id accountController = [accountControllerClass performSelector:@selector(sharedInstance)];
        if (!accountController) {
            return errorResponse(requestId, @"Could not get IMAccountController instance");
        }

        id account = [accountController performSelector:@selector(bestAccountForService:) withObject:service];
        if (!account) {
            return errorResponse(requestId, @"Could not get account for service");
        }

        // Resolve addresses to IMHandles
        NSMutableArray *handles = [NSMutableArray array];
        for (NSString *address in addresses) {
            id handle = [account performSelector:@selector(imHandleWithID:) withObject:address];
            if (handle) {
                [handles addObject:handle];
            } else {
                NSLog(@"[imsg-plus] Warning: could not resolve handle for %@", address);
            }
        }

        if (handles.count == 0) {
            return errorResponse(requestId, @"Could not resolve any handles from the provided addresses");
        }

        // Get or create chat via IMChatRegistry
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (!registryClass) {
            return errorResponse(requestId, @"IMChatRegistry class not found");
        }

        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if (!registry) {
            return errorResponse(requestId, @"Could not get IMChatRegistry instance");
        }

        SEL chatForHandlesSel = @selector(chatForIMHandles:);
        if (![registry respondsToSelector:chatForHandlesSel]) {
            return errorResponse(requestId, @"chatForIMHandles: not available on this macOS version");
        }

        id chat = [registry performSelector:chatForHandlesSel withObject:handles];
        if (!chat) {
            return errorResponse(requestId, @"Failed to create/find chat for the given handles");
        }

        // Optionally set display name
        if (name && [name length] > 0) {
            SEL setNameSel = @selector(_setDisplayName:);
            if ([chat respondsToSelector:setNameSel]) {
                [chat performSelector:setNameSel withObject:name];
                NSLog(@"[imsg-plus] Set chat display name to: %@", name);
            } else {
                // Fallback: try setValue:forChatProperty:
                SEL propSel = @selector(setValue:forChatProperty:);
                if ([chat respondsToSelector:propSel]) {
                    NSMethodSignature *sig = [chat methodSignatureForSelector:propSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:propSel];
                    [inv setTarget:chat];
                    NSString *propName = @"GroupName";
                    [inv setArgument:&name atIndex:2];
                    [inv setArgument:&propName atIndex:3];
                    [inv invoke];
                }
            }
        }

        // Optionally send first message
        if (text && [text length] > 0) {
            Class IMMessageClass = NSClassFromString(@"IMMessage");
            if (IMMessageClass) {
                NSAttributedString *attrText = [[NSAttributedString alloc] initWithString:text];
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:);
                if ([IMMessageClass instancesRespondToSelector:initSel]) {
                    typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id);
                    InitType initFunc = (InitType)objc_msgSend;
                    id msg = [IMMessageClass alloc];
                    msg = initFunc(msg, initSel, nil, nil, attrText, nil, nil, 0x5, nil, nil, nil);
                    if (msg) {
                        SEL sendSel = @selector(sendMessage:);
                        if ([chat respondsToSelector:sendSel]) {
                            [chat performSelector:sendSel withObject:msg];
                            NSLog(@"[imsg-plus] Sent initial message to new chat");
                        }
                    }
                }
            }
        }

        // Build response
        NSString *chatGuid = @"";
        if ([chat respondsToSelector:@selector(guid)]) {
            chatGuid = [chat performSelector:@selector(guid)] ?: @"";
        }
        NSString *chatIdentifier = @"";
        if ([chat respondsToSelector:@selector(chatIdentifier)]) {
            chatIdentifier = [chat performSelector:@selector(chatIdentifier)] ?: @"";
        }
        NSMutableArray *participantIDs = [NSMutableArray array];
        if ([chat respondsToSelector:@selector(participants)]) {
            NSArray *participants = [chat performSelector:@selector(participants)];
            for (id handle in participants) {
                if ([handle respondsToSelector:@selector(ID)]) {
                    [participantIDs addObject:[handle performSelector:@selector(ID)] ?: @""];
                }
            }
        }

        return successResponse(requestId, @{
            @"guid": chatGuid,
            @"identifier": chatIdentifier,
            @"participants": participantIDs,
            @"name": name ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to create chat: %@", exception.reason]);
    }
}

static NSDictionary* handleRenameChat(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *name = params[@"name"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!name) {
        return errorResponse(requestId, @"Missing required parameter: name");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL setNameSel = @selector(_setDisplayName:);
        if ([chat respondsToSelector:setNameSel]) {
            [chat performSelector:setNameSel withObject:name];
            NSLog(@"[imsg-plus] Renamed chat %@ to: %@", handle, name);
        } else {
            // Fallback: try setValue:forChatProperty:
            SEL propSel = @selector(setValue:forChatProperty:);
            if ([chat respondsToSelector:propSel]) {
                NSMethodSignature *sig = [chat methodSignatureForSelector:propSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:propSel];
                [inv setTarget:chat];
                NSString *propName = @"GroupName";
                [inv setArgument:&name atIndex:2];
                [inv setArgument:&propName atIndex:3];
                [inv invoke];
            } else {
                return errorResponse(requestId, @"_setDisplayName: and setValue:forChatProperty: not available");
            }
        }

        return successResponse(requestId, @{
            @"handle": handle,
            @"name": name
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to rename chat: %@", exception.reason]);
    }
}

static NSDictionary* handleRemoveParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSArray *addresses = params[@"addresses"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!addresses || ![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing required parameter: addresses");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Get account to resolve addresses to IMHandles
        Class serviceClass = NSClassFromString(@"IMServiceImpl");
        Class accountControllerClass = NSClassFromString(@"IMAccountController");
        if (!serviceClass || !accountControllerClass) {
            return errorResponse(requestId, @"IMServiceImpl or IMAccountController not found");
        }

        id service = [serviceClass performSelector:@selector(iMessageService)];
        id accountController = [accountControllerClass performSelector:@selector(sharedInstance)];
        id account = [accountController performSelector:@selector(bestAccountForService:) withObject:service];

        if (!account) {
            return errorResponse(requestId, @"Could not get account");
        }

        NSMutableArray *handles = [NSMutableArray array];
        for (NSString *address in addresses) {
            id imHandle = [account performSelector:@selector(imHandleWithID:) withObject:address];
            if (imHandle) {
                [handles addObject:imHandle];
            }
        }

        if (handles.count == 0) {
            return errorResponse(requestId, @"Could not resolve any handles");
        }

        SEL removeSel = @selector(removeParticipants:reason:);
        if ([chat respondsToSelector:removeSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:removeSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:removeSel];
            [inv setTarget:chat];
            [inv setArgument:&handles atIndex:2];
            NSString *reason = @"";
            [inv setArgument:&reason atIndex:3];
            [inv invoke];
            NSLog(@"[imsg-plus] Removed %lu participants from %@", (unsigned long)handles.count, handle);
        } else {
            // Fallback: try removeIMHandles:
            SEL altSel = @selector(removeIMHandles:);
            if ([chat respondsToSelector:altSel]) {
                [chat performSelector:altSel withObject:handles];
            } else {
                return errorResponse(requestId, @"removeParticipants: and removeIMHandles: not available");
            }
        }

        return successResponse(requestId, @{
            @"handle": handle,
            @"removed": @(handles.count)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to remove participants: %@", exception.reason]);
    }
}

static NSDictionary* handleSendRichMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *attributedTextBase64 = params[@"attributed_text"];
    NSString *plainText = params[@"text"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!attributedTextBase64 && !plainText) {
        return errorResponse(requestId, @"Missing required parameter: attributed_text or text");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        NSAttributedString *messageText = nil;

        if (attributedTextBase64) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:attributedTextBase64 options:0];
            if (data) {
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    id unarchived = [NSUnarchiver unarchiveObjectWithData:data];
                    #pragma clang diagnostic pop
                    if ([unarchived isKindOfClass:[NSAttributedString class]]) {
                        messageText = (NSAttributedString *)unarchived;
                    }
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Failed to unarchive attributed text: %@", e.reason);
                }
            }
        }

        if (!messageText && plainText) {
            messageText = [[NSAttributedString alloc] initWithString:plainText];
        }

        if (!messageText) {
            return errorResponse(requestId, @"Could not construct message text");
        }

        Class IMMessageClass = NSClassFromString(@"IMMessage");
        if (!IMMessageClass) {
            return errorResponse(requestId, @"IMMessage class not found");
        }

        // Generate a unique message GUID
        NSString *guid = [[NSUUID UUID] UUIDString];

        // Check for thread reply
        NSString *replyToGuid = params[@"reply_to_guid"];
        NSString *effectId = params[@"effect_id"];

        id msg = nil;

        if (replyToGuid) {
            // Thread replies use r:RANGE:INDEX:GUID format for threadIdentifier
            NSString *threadId = [NSString stringWithFormat:@"r:0:0:0:%@", replyToGuid];

            if (effectId) {
                // Use the init with both expressiveSendStyleID and threadIdentifier
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:);
                if ([IMMessageClass instancesRespondToSelector:initSel]) {
                    typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id, id, id, id);
                    InitType initFunc = (InitType)objc_msgSend;
                    msg = [IMMessageClass alloc];
                    msg = initFunc(msg, initSel,
                        nil,                  // sender
                        [NSDate date],        // time
                        messageText,          // text
                        nil,                  // messageSubject
                        nil,                  // fileTransferGUIDs
                        (unsigned long long)0x100005,  // flags
                        nil,                  // error
                        guid,                 // guid
                        nil,                  // subject
                        nil,                  // balloonBundleID
                        nil,                  // payloadData
                        effectId,             // expressiveSendStyleID
                        threadId);            // threadIdentifier
                }
            }

            if (!msg) {
                // Use the simpler init with threadIdentifier
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:);
                if ([IMMessageClass instancesRespondToSelector:initSel]) {
                    typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id);
                    InitType initFunc = (InitType)objc_msgSend;
                    msg = [IMMessageClass alloc];
                    msg = initFunc(msg, initSel,
                        nil,                  // sender
                        [NSDate date],        // time
                        messageText,          // text
                        nil,                  // messageSubject
                        nil,                  // fileTransferGUIDs
                        (unsigned long long)0x100005,  // flags
                        nil,                  // error
                        guid,                 // guid
                        nil,                  // subject
                        threadId);            // threadIdentifier
                } else {
                    return errorResponse(requestId, @"IMMessage initWithSender:...:threadIdentifier: not available");
                }
            }
        } else {
            // No thread reply — use standard init
            SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:);
            if (![IMMessageClass instancesRespondToSelector:initSel]) {
                return errorResponse(requestId, @"IMMessage init selector not available");
            }

            typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id);
            InitType initFunc = (InitType)objc_msgSend;
            msg = [IMMessageClass alloc];
            msg = initFunc(msg, initSel,
                nil,                  // sender
                [NSDate date],        // time
                messageText,          // text
                nil,                  // messageSubject
                nil,                  // fileTransferGUIDs
                (unsigned long long)0x100005,  // flags
                nil,                  // error
                guid,                 // guid
                nil);                 // subject
        }

        if (!msg) {
            return errorResponse(requestId, @"Failed to create IMMessage");
        }

        // Set expressive send effect if provided (for non-reply messages, or if reply+effect init wasn't used)
        if (effectId && !replyToGuid) {
            @try {
                [msg setValue:effectId forKey:@"expressiveSendStyleID"];
            } @catch (NSException *e) {
                NSLog(@"[imsg-plus] Could not set expressiveSendStyleID: %@", e.reason);
            }
        }

        if (replyToGuid) {
            // Thread reply: send through CKConversation (same path the UI uses)
            // The UI sends via CKConversation.sendMessage:newComposition: with composition=nil
            // and threadIdentifier in r:0:0:PART:GUID format

            // First, try to find the CKConversation for this chat
            Class ckConvClass = NSClassFromString(@"CKConversation");
            id ckConversation = nil;

            if (ckConvClass) {
                // Get CKConversation from chat via the conversation property
                @try {
                    ckConversation = [chat valueForKey:@"conversation"];
                } @catch (NSException *e) { }

                if (!ckConversation) {
                    // Try CKConversationList
                    @try {
                        Class ckListClass = NSClassFromString(@"CKConversationList");
                        if (ckListClass) {
                            id ckList = [ckListClass performSelector:@selector(sharedConversationList)];
                            if (ckList) {
                                SEL convForChatSel = @selector(conversationForExistingChat:);
                                if ([ckList respondsToSelector:convForChatSel]) {
                                    ckConversation = [ckList performSelector:convForChatSel withObject:chat];
                                }
                                if (!ckConversation) {
                                    SEL convForChatSel2 = @selector(conversationForChat:);
                                    if ([ckList respondsToSelector:convForChatSel2]) {
                                        ckConversation = [ckList performSelector:convForChatSel2 withObject:chat];
                                    }
                                }
                            }
                        }
                    } @catch (NSException *e) { }
                }
            }

            // Send via CKConversation if available, else fall back to IMChat
            SEL ckSendSel = @selector(sendMessage:newComposition:);
            if (ckConversation && [ckConversation respondsToSelector:ckSendSel]) {
                typedef void (*CKSendType)(id, SEL, id, id);
                CKSendType ckSendFunc = (CKSendType)objc_msgSend;
                ckSendFunc(ckConversation, ckSendSel, msg, nil);

                return successResponse(requestId, @{@"handle": handle, @"sent": @YES});
            } else {
                // Fallback: send via IMChat.sendMessage:
                SEL sendSel = @selector(sendMessage:);
                if (![chat respondsToSelector:sendSel]) {
                    return errorResponse(requestId, @"Chat does not respond to sendMessage:");
                }
                [chat performSelector:sendSel withObject:msg];
                return successResponse(requestId, @{@"handle": handle, @"sent": @YES});
            }
        }

        // Non-reply path
        SEL sendSel = @selector(sendMessage:);
        if (![chat respondsToSelector:sendSel]) {
            return errorResponse(requestId, @"Chat does not respond to sendMessage:");
        }
        [chat performSelector:sendSel withObject:msg];

        return successResponse(requestId, @{
            @"handle": handle,
            @"sent": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to send message: %@", exception.reason]);
    }
}

#pragma mark - Edit and Unsend

static NSDictionary* handleEditMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSString *newText = params[@"text"];
    NSString *attributedTextBase64 = params[@"attributed_text"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!messageGUID) {
        return errorResponse(requestId, @"Missing required parameter: guid");
    }
    if (!newText && !attributedTextBase64) {
        return errorResponse(requestId, @"Missing required parameter: text or attributed_text");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Load message via IMChatHistoryController (async)
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ for edit...", messageGUID);

    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] edit: loadMessageWithGUID completion fired, message=%@", message);

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Build the new attributed string
                NSAttributedString *newAttrText = nil;
                if (attributedTextBase64) {
                    NSData *data = [[NSData alloc] initWithBase64EncodedString:attributedTextBase64 options:0];
                    if (data) {
                        @try {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            id unarchived = [NSUnarchiver unarchiveObjectWithData:data];
                            #pragma clang diagnostic pop
                            if ([unarchived isKindOfClass:[NSAttributedString class]]) {
                                newAttrText = (NSAttributedString *)unarchived;
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[imsg-plus] Failed to unarchive attributed text for edit: %@", e.reason);
                        }
                    }
                }
                if (!newAttrText && newText) {
                    newAttrText = [[NSAttributedString alloc] initWithString:newText];
                }
                if (!newAttrText) {
                    writeResponseToFile(errorResponse(requestId, @"Could not construct edit text"));
                    return;
                }

                // Get the IMMessageItem from the IMMessage
                id messageItem = nil;
                @try {
                    messageItem = [message valueForKey:@"_imMessageItem"];
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Could not get _imMessageItem: %@", e.reason);
                }
                if (!messageItem) {
                    writeResponseToFile(errorResponse(requestId, @"Could not get IMMessageItem from message"));
                    return;
                }
                NSLog(@"[imsg-plus] Got IMMessageItem: %@ (class: %@)", messageItem, [messageItem class]);

                // Build backward-compat plain text
                NSAttributedString *backwardText = [[NSAttributedString alloc] initWithString:newAttrText.string];

                // Try edit selectors in priority order
                BOOL edited = NO;
                NSString *methodUsed = nil;

                // 1. editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:
                SEL sel1 = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
                if (!edited && [chat respondsToSelector:sel1]) {
                    NSLog(@"[imsg-plus] Trying editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:");
                    typedef void (*EditType)(id, SEL, id, NSInteger, id, id);
                    EditType editFunc = (EditType)[chat methodForSelector:sel1];
                    editFunc(chat, sel1, messageItem, 0, newAttrText, backwardText);
                    edited = YES;
                    methodUsed = @"editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:";
                }

                // 2. editMessage:atPartIndex:withAttributedString: (fallback)
                SEL sel2 = @selector(editMessage:atPartIndex:withAttributedString:);
                if (!edited && [chat respondsToSelector:sel2]) {
                    NSLog(@"[imsg-plus] Trying editMessage:atPartIndex:withAttributedString:");
                    typedef void (*EditType)(id, SEL, id, NSInteger, id);
                    EditType editFunc = (EditType)[chat methodForSelector:sel2];
                    editFunc(chat, sel2, message, 0, newAttrText);
                    edited = YES;
                    methodUsed = @"editMessage:atPartIndex:withAttributedString:";
                }

                if (!edited) {
                    // Dump available edit methods for discovery
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([chat class], &methodCount);
                    NSMutableArray *editMethods = [NSMutableArray array];
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name.lowercaseString containsString:@"edit"]) {
                            [editMethods addObject:name];
                        }
                    }
                    free(methods);
                    NSLog(@"[imsg-plus] Available edit methods on IMChat: %@", editMethods);
                    writeResponseToFile(errorResponse(requestId,
                        [NSString stringWithFormat:@"No known edit selector found. Available: %@", editMethods]));
                    return;
                }

                NSLog(@"[imsg-plus] ✅ Edited message %@ via %@", messageGUID, methodUsed);
                writeResponseToFile(successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"method": methodUsed
                }));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in edit completion: %@", exception.reason);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed to edit message: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    // 5-second timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ Edit completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: edit completion never fired for: %@", messageGUID]));
        }
    });

    return nil;
}

static NSDictionary* handleUnsendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *partIndexNum = params[@"part_index"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!messageGUID) {
        return errorResponse(requestId, @"Missing required parameter: guid");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Load message via IMChatHistoryController (async)
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ for unsend...", messageGUID);

    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] unsend: loadMessageWithGUID completion fired, message=%@", message);

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Get IMMessageItem and then chat items (same pattern as react handler)
                id messageItem = nil;
                @try {
                    messageItem = [message valueForKey:@"_imMessageItem"];
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Could not get _imMessageItem: %@", e.reason);
                }

                // Get chat items to find the part to retract
                id partItem = nil;
                if (messageItem) {
                    id items = nil;
                    if ([messageItem respondsToSelector:@selector(_newChatItems)]) {
                        items = [messageItem performSelector:@selector(_newChatItems)];
                    } else {
                        @try { items = [messageItem valueForKey:@"_newChatItems"]; }
                        @catch (NSException *e) {}
                    }

                    if ([items isKindOfClass:[NSArray class]]) {
                        NSArray *itemArray = (NSArray *)items;
                        NSLog(@"[imsg-plus] Got %lu chat items from message", (unsigned long)itemArray.count);
                        for (id item in itemArray) {
                            NSString *className = NSStringFromClass([item class]);
                            if ([className containsString:@"MessagePartChatItem"] ||
                                [className containsString:@"TextMessagePartChatItem"]) {
                                if ([item respondsToSelector:@selector(index)]) {
                                    NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                    if (idx == partIndex) {
                                        partItem = item;
                                        break;
                                    }
                                } else if (partIndex == 0) {
                                    partItem = item;
                                    break;
                                }
                            }
                        }
                        if (!partItem && itemArray.count > 0) {
                            partItem = itemArray[partIndex < (int)itemArray.count ? partIndex : 0];
                        }
                    } else if (items) {
                        partItem = items;
                    }
                }

                NSLog(@"[imsg-plus] partItem for unsend: %@ (class: %@)",
                      partItem, partItem ? [partItem class] : @"nil");

                BOOL unsent = NO;
                NSString *methodUsed = nil;

                // 1. retractMessagePart: (takes a chat item / message part)
                SEL sel1 = @selector(retractMessagePart:);
                if (!unsent && partItem && [chat respondsToSelector:sel1]) {
                    NSLog(@"[imsg-plus] Trying retractMessagePart: with partItem");
                    [chat performSelector:sel1 withObject:partItem];
                    unsent = YES;
                    methodUsed = @"retractMessagePart:";
                }

                // 2. retractMessage:atPartIndex: (fallback)
                SEL sel2 = @selector(retractMessage:atPartIndex:);
                if (!unsent && [chat respondsToSelector:sel2]) {
                    NSLog(@"[imsg-plus] Trying retractMessage:atPartIndex:");
                    typedef void (*UnsendType)(id, SEL, id, NSInteger);
                    UnsendType unsendFunc = (UnsendType)[chat methodForSelector:sel2];
                    unsendFunc(chat, sel2, message, partIndex);
                    unsent = YES;
                    methodUsed = @"retractMessage:atPartIndex:";
                }

                // 3. _unsendMessage:atPartIndex: (fallback)
                SEL sel3 = @selector(_unsendMessage:atPartIndex:);
                if (!unsent && [chat respondsToSelector:sel3]) {
                    NSLog(@"[imsg-plus] Trying _unsendMessage:atPartIndex:");
                    typedef void (*UnsendType)(id, SEL, id, NSInteger);
                    UnsendType unsendFunc = (UnsendType)[chat methodForSelector:sel3];
                    unsendFunc(chat, sel3, message, partIndex);
                    unsent = YES;
                    methodUsed = @"_unsendMessage:atPartIndex:";
                }

                if (!unsent) {
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([chat class], &methodCount);
                    NSMutableArray *unsendMethods = [NSMutableArray array];
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        NSString *lower = name.lowercaseString;
                        if ([lower containsString:@"retract"] || [lower containsString:@"unsend"]) {
                            [unsendMethods addObject:name];
                        }
                    }
                    free(methods);
                    NSLog(@"[imsg-plus] Available unsend/retract methods on IMChat: %@", unsendMethods);
                    writeResponseToFile(errorResponse(requestId,
                        [NSString stringWithFormat:@"No known unsend selector found. Available: %@", unsendMethods]));
                    return;
                }

                NSLog(@"[imsg-plus] ✅ Unsent message %@ via %@", messageGUID, methodUsed);
                writeResponseToFile(successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"part_index": @(partIndex),
                    @"method": methodUsed
                }));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in unsend completion: %@", exception.reason);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed to unsend message: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    // 5-second timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ Unsend completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: unsend completion never fired for: %@", messageGUID]));
        }
    });

    return nil;
}

#pragma mark - Command Router

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-plus] Processing command: %@ (id=%ld)", action, (long)requestId);

    if ([action isEqualToString:@"typing"]) {
        return handleTyping(requestId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(requestId, params);
    } else if ([action isEqualToString:@"react"]) {
        return handleReact(requestId, params);
    } else if ([action isEqualToString:@"status"]) {
        return handleStatus(requestId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(requestId, params);
    } else if ([action isEqualToString:@"create_chat"]) {
        return handleCreateChat(requestId, params);
    } else if ([action isEqualToString:@"rename_chat"]) {
        return handleRenameChat(requestId, params);
    } else if ([action isEqualToString:@"remove_participant"]) {
        return handleRemoveParticipant(requestId, params);
    } else if ([action isEqualToString:@"send_message"]) {
        return handleSendRichMessage(requestId, params);
    } else if ([action isEqualToString:@"edit_message"]) {
        return handleEditMessage(requestId, params);
    } else if ([action isEqualToString:@"unsend_message"]) {
        return handleUnsendMessage(requestId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(requestId, @{@"pong": @YES});
    } else {
        return errorResponse(requestId, [NSString stringWithFormat:@"Unknown action: %@", action]);
    }
}

#pragma mark - Socket Server

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        // Read command file
        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        // Parse JSON
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData options:0 error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        // Timer runs on main run loop, so we're already on the main thread for IMCore access
        NSDictionary *result = processCommand(command);

        if (result != nil) {
            // Synchronous response — write it now
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];

            // Clear command file to indicate we processed it
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

            NSLog(@"[imsg-plus] Processed command, wrote response");
        } else {
            // Async handler (e.g., react) will write its own response
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[imsg-plus] Command dispatched async, response pending");
        }
    }
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-plus] Starting file-based IPC");
    NSLog(@"[imsg-plus] Command file: %@", kCommandFile);
    NSLog(@"[imsg-plus] Response file: %@", kResponseFile);

    // Create/clear command and response files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file to indicate we're ready
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY, 0644);
    if (lockFd >= 0) {
        // Write PID to lock file
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }

    // Watch command file for changes using NSTimer on the main run loop.
    // dispatch_source timers get deallocated in injected dylib contexts,
    // but NSTimer tied to the main run loop survives reliably.
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                // Check if file has content
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {  // More than just "{}"
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;  // Prevent deallocation
    fileWatchSource = nil;   // No longer using dispatch_source

    NSLog(@"[imsg-plus] File watcher started, ready for commands");
}


#pragma mark - Dylib Entry Point

__attribute__((constructor))
static void injectedInit(void) {
    NSLog(@"[imsg-plus] Dylib injected into %@", [[NSProcessInfo processInfo] processName]);

    // Inject compatibility methods for IMCore
    injectCompatibilityMethods();

    // Connect to IMDaemon for full IMCore access
    Class daemonClass = NSClassFromString(@"IMDaemonController");
    if (daemonClass) {
        id daemon = [daemonClass performSelector:@selector(sharedInstance)];
        if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
            [daemon performSelector:@selector(connectToDaemon)];
            NSLog(@"[imsg-plus] ✅ Connected to IMDaemon");
        } else {
            NSLog(@"[imsg-plus] ⚠️ IMDaemonController available but couldn't connect");
        }
    } else {
        NSLog(@"[imsg-plus] ⚠️ IMDaemonController class not found");
    }

    // Delay initialization to let Messages.app fully start
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSLog(@"[imsg-plus] Initializing after delay...");

        // Log IMCore status
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass) {
            id registry = [registryClass performSelector:@selector(sharedInstance)];
            if ([registry respondsToSelector:@selector(allExistingChats)]) {
                NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                NSLog(@"[imsg-plus] IMChatRegistry available with %lu chats", (unsigned long)chats.count);
            }
        } else {
            NSLog(@"[imsg-plus] IMChatRegistry NOT available");
        }

        // Start file watcher for IPC
        startFileWatcher();
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    NSLog(@"[imsg-plus] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (fileWatchSource) {
        dispatch_source_cancel(fileWatchSource);
        fileWatchSource = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    // Clean up files
    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
