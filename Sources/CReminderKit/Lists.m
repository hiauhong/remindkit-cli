#import "ReminderKit.h"
#import <objc/message.h>

NSDictionary *fetchGroups(id store) {
    NSMutableDictionary *groupMap = [NSMutableDictionary dictionary];
    NSError *acctErr = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchAccountsWithError:"), &acctErr);
    id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
    if (!acct) return groupMap;

    id groupCtx = [acct valueForKey:@"groupContext"];
    SEL fetchGrp = NSSelectorFromString(@"fetchGroupsWithError:");
    if (![groupCtx respondsToSelector:fetchGrp]) return groupMap;

    NSError *err = nil;
    id groups = ((id(*)(id, SEL, id*))objc_msgSend)(groupCtx, fetchGrp, &err);
    if (![groups isKindOfClass:[NSArray class]]) return groupMap;

    for (id g in (NSArray *)groups) {
        NSString *uuid = extractUUID([g valueForKey:@"objectID"]);
        NSString *name = [g valueForKey:@"name"];
        if (uuid && [name isKindOfClass:[NSString class]])
            groupMap[uuid] = name;
    }
    return groupMap;
}

NSArray *fetchLists(id store, id groups) {
    NSMutableArray *listEntries = [NSMutableArray array];

    [store enumerateAllListsWithBlock:^(id list, BOOL *sp) {
        NSString *uuid = extractUUID([list valueForKey:@"objectID"]);
        if (!uuid) return;
        NSString *name = [[list valueForKey:@"name"] isKindOfClass:[NSString class]]
            ? [list valueForKey:@"name"] : @"";

        NSString *parentUUID = extractUUID([list valueForKey:@"parentListID"]);
        NSString *groupName = nil;
        if (parentUUID) groupName = groups[parentUUID];

        // sections
        NSMutableArray *sections = [NSMutableArray array];
        @try {
            id lsdv = [[NSClassFromString(@"REMListSectionsDataView") alloc] initWithStore:store];
            if (lsdv) {
                NSError *secErr = nil;
                SEL fetchSel = NSSelectorFromString(@"fetchListSectionsWithListObjectID:error:");
                id secs = ((id(*)(id, SEL, id, id*))objc_msgSend)(lsdv, fetchSel,
                    [list valueForKey:@"objectID"], &secErr);
                if ([secs respondsToSelector:@selector(count)]) {
                    NSInteger count = ((NSInteger(*)(id, SEL))objc_msgSend)(secs, @selector(count));
                    for (NSInteger i = 0; i < count; i++) {
                        id secObj = ((id(*)(id, SEL, NSInteger))objc_msgSend)(secs, @selector(objectAtIndex:), i);
                        NSArray *names = parseSectionNames(secObj);
                        if (names.count > 0) [sections addObjectsFromArray:names];
                    }
                }
            }
        } @catch (NSException *e) {}

        NSString *icon = badgeEmoji([list valueForKey:@"badgeEmblem"]);
        NSString *colorStr = colorToHex([list valueForKey:@"color"]);

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"uuid"] = uuid;
        entry[@"name"] = name;
        entry[@"isGroup"] = @NO;
        if (icon) entry[@"icon"] = icon;
        if (colorStr) entry[@"color"] = colorStr;
        if (groupName) entry[@"group"] = groupName;
        if (sections.count > 0) entry[@"sections"] = sections;
        entry[@"parentUUID"] = parentUUID ?: [NSNull null];
        [listEntries addObject:entry];
    }];

    // groups as list entries
    for (NSString *uuid in groups) {
        [listEntries addObject:@{
            @"uuid": uuid, @"name": groups[uuid], @"isGroup": @YES
        }];
    }

    return listEntries;
}

NSSet *collectSectionedListUUIDs(NSArray *listEntries) {
    NSMutableSet *set = [NSMutableSet set];
    for (NSDictionary *le in listEntries) {
        if ([le[@"sections"] count] > 0 && le[@"uuid"]) {
            [set addObject:le[@"uuid"]];
        }
    }
    return set;
}
