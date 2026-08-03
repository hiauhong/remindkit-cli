#import "ReminderKit.h"
#import <objc/message.h>

// 系统智能列表（虚拟视图）的 smartListType 与显示名。
// 「计划」没有实体 smartList（派生视图），remindkit 用 scheduled 命令覆盖。
static NSDictionary *systemSmartListNames(void) {
    return @{
        @"com.apple.reminders.smartlist.today": @"今天",
        @"com.apple.reminders.smartlist.flagged": @"旗标",
        @"com.apple.reminders.smartlist.completed": @"已完成",
        @"com.apple.reminders.smartlist.assigned": @"已分配",
    };
}

// 单个 smartList 对象 → JSON 条目。type 为 "custom" 或系统类型短名（today/flagged/…）。
static NSMutableDictionary *smartListEntry(id smartList, NSRegularExpression *uuidRegex, NSString *type) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (type) entry[@"type"] = type;

    NSString *name = [smartList valueForKey:@"name"];
    if (name) entry[@"name"] = name;

    id objID = [smartList valueForKey:@"objectID"];
    if (objID) {
        NSString *desc = [[objID description]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSTextCheckingResult *match = [uuidRegex firstMatchInString:desc options:0
            range:NSMakeRange(0, desc.length)];
        if (match) entry[@"uuid"] = [desc substringWithRange:match.range];
    }

    id sorting = [smartList valueForKey:@"sortingStyle"];
    if (sorting) {
        NSString *sortDesc = [sorting description];
        if ([sortDesc isKindOfClass:[NSString class]]) entry[@"sortingStyle"] = sortDesc;
    }

    id filterData = [smartList valueForKey:@"filterData"];
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

    return entry;
}

NSArray *fetchSmartLists(id store, NSRegularExpression *uuidRegex) {
    NSMutableArray *smartLists = [NSMutableArray array];

    id smartListsView = [[NSClassFromString(@"REMSmartListsDataView") alloc] initWithStore:store];

    // 1) 自定义智能列表（fetchCustomSmartListsWithError: 只枚举用户自定义的）。
    NSError *err = nil;
    id fetched = ((id(*)(id, SEL, id*))objc_msgSend)(smartListsView,
        NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
    if ([fetched isKindOfClass:[NSArray class]]) {
        for (id smartList in (NSArray *)fetched) {
            [smartLists addObject:smartListEntry(smartList, uuidRegex, @"custom")];
        }
    }

    // 2) 系统智能列表：今天 / 旗标 / 已完成 / 已分配。
    //    fetchNonCustomSmartListWithSmartListType:createIfNeeded:error: 按类型取
    //    （createIfNeeded:NO 只读，不创建）。系统列表无 name，用映射显示名。
    NSDictionary *systemNames = systemSmartListNames();
    for (NSString *smartListType in systemNames) {
        NSError *sysErr = nil;
        id sys = ((id(*)(id, SEL, id, BOOL, id*))objc_msgSend)(smartListsView,
            NSSelectorFromString(@"fetchNonCustomSmartListWithSmartListType:createIfNeeded:error:"),
            smartListType, NO, &sysErr);
        if (sys && ![sys isKindOfClass:[NSNull class]]) {
            NSMutableDictionary *entry = smartListEntry(sys, uuidRegex, smartListType);
            if (!entry[@"name"]) entry[@"name"] = systemNames[smartListType];
            [smartLists addObject:entry];
        }
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
