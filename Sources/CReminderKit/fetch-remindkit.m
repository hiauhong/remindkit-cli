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
        BOOL listsOnly = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--no-sections") == 0) includeSections = NO;
            if (strcmp(argv[i], "--lists-only") == 0) listsOnly = YES;
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

        // 3) Reminder enumeration (skipped in --lists-only mode: `setup`'s
        // default evaluates from structure alone and never touches contents)
        NSMutableArray *reminderEntries = [NSMutableArray array];
        if (!listsOnly) {
            NSString *fetchError = nil;
            if (!fetchReminders(store, sectionedListUUIDs, reminderEntries, &fetchError)) {
                NSDictionary *failure = @{
                    @"ok": @NO,
                    @"error": fetchError ?: @"failed to fetch reminders",
                };
                NSData *failureJSON = [NSJSONSerialization dataWithJSONObject:failure options:0 error:NULL];
                printf("%s", failureJSON
                    ? [[[NSString alloc] initWithData:failureJSON encoding:NSUTF8StringEncoding] UTF8String]
                    : "{\"ok\":false,\"error\":\"failed to fetch reminders\"}");
                return 1;
            }
        }

        // 4) Build output
        NSDictionary *output = @{
            @"ok": @YES,
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
