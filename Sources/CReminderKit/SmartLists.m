#import "ReminderKit.h"
#import <objc/message.h>

NSArray *fetchSmartLists(id store, NSRegularExpression *uuidRegex) {
    NSMutableArray *smartLists = [NSMutableArray array];

    id smartListsView = [[NSClassFromString(@"REMSmartListsDataView") alloc] initWithStore:store];
    NSError *err = nil;
    id fetched = ((id(*)(id, SEL, id*))objc_msgSend)(smartListsView,
        NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);

    if (![fetched isKindOfClass:[NSArray class]]) return smartLists;

    for (id smartList in (NSArray *)fetched) {
        NSString *name = [smartList valueForKey:@"name"];
        id objID = [smartList valueForKey:@"objectID"];
        id filterData = [smartList valueForKey:@"filterData"];
        id sorting = [smartList valueForKey:@"sortingStyle"];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (name) entry[@"name"] = name;

        if (objID) {
            NSString *desc = [[objID description]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSTextCheckingResult *match = [uuidRegex firstMatchInString:desc options:0
                range:NSMakeRange(0, desc.length)];
            if (match) entry[@"uuid"] = [desc substringWithRange:match.range];
        }

        if (sorting) {
            NSString *sortDesc = [sorting description];
            if ([sortDesc isKindOfClass:[NSString class]]) entry[@"sortingStyle"] = sortDesc;
        }

        if (filterData && [filterData length] > 0) {
            NSString *jsonStr = [[NSString alloc] initWithData:filterData
                encoding:NSUTF8StringEncoding];
            if (jsonStr) entry[@"filterData"] = jsonStr;
        }

        id customCtx = [smartList valueForKey:@"customContext"];
        if (customCtx) {
            NSString *color = colorToHex([customCtx valueForKey:@"color"]);
            if (color) entry[@"color"] = color;
        }

        NSString *icon = badgeEmoji([smartList valueForKey:@"badgeEmblem"]);
        if (icon) entry[@"icon"] = icon;

        [smartLists addObject:entry];
    }
    return smartLists;
}

NSArray *fetchListIDsOrdering(id store) {
    NSMutableArray *listIDsOrdering = [NSMutableArray array];
    NSError *acctErr = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchAccountsWithError:"), &acctErr);
    if ([accounts isKindOfClass:[NSArray class]] && [(NSArray *)accounts count] > 0) {
        id account = accounts[0];
        id ordering = [account valueForKey:@"listIDsOrdering"];
        if ([ordering respondsToSelector:@selector(array)]) {
            id arr = [ordering performSelector:@selector(array)];
            if ([arr isKindOfClass:[NSArray class]]) {
                for (NSString *uuid in (NSArray *)arr) {
                    [listIDsOrdering addObject:uuid];
                }
            }
        }
    }
    return listIDsOrdering;
}
