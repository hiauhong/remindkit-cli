#import "ReminderKit.h"
#import <dlfcn.h>
#import <objc/message.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW);

        // Write mode: `fetch-remindkit write` reads a JSON request on stdin
        // (op: add/complete/delete/move) and writes via the private framework.
        if (argc > 1 && strcmp(argv[1], "write") == 0) {
            NSData *in = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            id req = in.length > 0 ? [NSJSONSerialization JSONObjectWithData:in options:0 error:NULL] : nil;
            if (![req isKindOfClass:[NSDictionary class]]) {
                printf("{\"ok\":false,\"error\":\"bad request\"}");
                return 1;
            }
            id store = ((id(*)(id, SEL, BOOL))objc_msgSend)([NSClassFromString(@"REMStore") alloc],
                NSSelectorFromString(@"initUserInteractive:"), YES);
            NSDictionary *result = executeWriteRequest(store, req);
            NSData *out = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
            printf("%s", out ? [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] UTF8String] : "{}");
            return 0;
        }

        id store = [[NSClassFromString(@"REMStore") alloc] init];

        // Per-reminder section lookup is the slow part of a full dump
        // (~4ms × number of reminders in sectioned lists, serialized through
        // remindd). Commands that don't need the section field (show/search/
        // count/…) pass --no-sections to skip it entirely.
        BOOL includeSections = YES;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--no-sections") == 0) includeSections = NO;
        }

        NSRegularExpression *uuidRegex = [NSRegularExpression regularExpressionWithPattern:
            @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
            options:0 error:NULL];

        // 1) Smart lists + list ordering
        NSArray *smartLists = fetchSmartLists(store, uuidRegex);
        NSArray *listIDsOrdering = fetchListIDsOrdering(store);

        // 2) Groups + lists + sections
        NSDictionary *groups = fetchGroups(store);
        NSArray *listEntries = fetchLists(store, groups);
        NSSet *sectionedListUUIDs = includeSections ? collectSectionedListUUIDs(listEntries) : nil;

        // 3) Reminder enumeration
        NSMutableArray *reminderEntries = [NSMutableArray array];
        fetchReminders(store, sectionedListUUIDs, reminderEntries);

        // 4) Build output
        NSDictionary *output = @{
            @"smartLists": smartLists,
            @"listIDsOrdering": listIDsOrdering,
            @"lists": listEntries,
            @"reminders": reminderEntries,
        };

        NSError *jsonErr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:&jsonErr];
        if (json) {
            printf("%s", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
        } else {
            printf("{}");
        }
    }
    return 0;
}
