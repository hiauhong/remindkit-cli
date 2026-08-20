#import "ReminderKit.h"
#import <objc/message.h>

// Cache: reminder objectID → section name for sectioned lists.
// Reminders are enumerated in display order (grouped by list + section),
// so consecutive reminders in the same section benefit from the cache.
@interface SectionCache : NSObject
@property (nonatomic, strong) NSCache *cache;
@property (nonatomic, strong) id dataView;
@property (nonatomic, assign) SEL lookupSel;
- (instancetype)initWithStore:(id)store;
- (NSString *)sectionForReminder:(id)reminder listUUID:(NSString *)listUUID;
@end

@implementation SectionCache
- (instancetype)initWithStore:(id)store {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 256;
        _dataView = [[NSClassFromString(@"REMListSectionsDataView") alloc] initWithStore:store];
        _lookupSel = NSSelectorFromString(@"fetchListSectionWithReminderID:error:");
    }
    return self;
}

- (NSString *)sectionForReminder:(id)reminder listUUID:(NSString *)listUUID {
    id objID = [reminder valueForKey:@"objectID"];
    if (!objID) return nil;

    NSString *desc = [[objID description] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", listUUID, desc];

    NSString *cached = [self.cache objectForKey:cacheKey];
    if (cached) return cached;

    @try {
        NSError *err = nil;
        id secObj = ((id(*)(id, SEL, id, id*))objc_msgSend)(self.dataView, self.lookupSel,
            objID, &err);
        if (secObj) {
            NSArray *names = parseSectionNames(secObj);
            NSString *name = names.firstObject;
            if (name) {
                [self.cache setObject:name forKey:cacheKey];
                return name;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}
@end

// MARK: - Conversions

static NSNumber *componentsToEpoch(NSDateComponents *comp, NSTimeZone *fallbackTZ) {
    if (![comp isKindOfClass:[NSDateComponents class]]) return nil;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSTimeZone *tz = comp.timeZone ?: fallbackTZ;
    if ([tz isKindOfClass:[NSString class]]) {
        tz = [NSTimeZone timeZoneWithName:(NSString *)tz];
    }
    if ([tz isKindOfClass:[NSTimeZone class]]) cal.timeZone = tz;
    NSDate *date = [cal dateFromComponents:comp];
    if (!date) return nil;
    return @(date.timeIntervalSince1970);
}

// Encode REMRecurrenceRule array as the same JSON shape EventKit produced
// for EKRecurrenceRule, so the unified schema stays stable.
static NSString *encodeRecurrenceRules(NSArray *rules) {
    if (![rules isKindOfClass:[NSArray class]] || rules.count == 0) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (id rule in rules) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        NSNumber *freq = [rule valueForKey:@"frequency"];
        NSNumber *interval = [rule valueForKey:@"interval"];
        if ([freq isKindOfClass:[NSNumber class]]) dict[@"frequency"] = freq;
        if ([interval isKindOfClass:[NSNumber class]]) dict[@"interval"] = interval;

        id dow = [rule valueForKey:@"daysOfTheWeek"];
        if ([dow isKindOfClass:[NSArray class]] && [dow count] > 0) {
            NSMutableArray *days = [NSMutableArray array];
            for (id d in dow) {
                NSNumber *day = [d valueForKey:@"dayOfTheWeek"];
                NSNumber *week = [d valueForKey:@"weekNumber"];
                NSMutableDictionary *dd = [NSMutableDictionary dictionary];
                if ([day isKindOfClass:[NSNumber class]]) dd[@"dayOfTheWeek"] = day;
                if ([week isKindOfClass:[NSNumber class]]) dd[@"weekNumber"] = week;
                if (dd.count > 0) [days addObject:dd];
            }
            if (days.count > 0) dict[@"daysOfTheWeek"] = days;
        }

        for (NSString *k in @[@"daysOfTheMonth", @"monthsOfTheYear",
                              @"weeksOfTheYear", @"daysOfTheYear", @"setPositions"]) {
            id v = [rule valueForKey:k];
            if ([v isKindOfClass:[NSArray class]] && [v count] > 0) dict[k] = v;
        }

        NSNumber *fdow = [rule valueForKey:@"firstDayOfTheWeek"];
        // 0 = unspecified in REMRecurrenceRule; omit rather than emit a
        // meaningless zero (EventKit reports its derived default instead).
        if ([fdow isKindOfClass:[NSNumber class]] && [fdow intValue] != 0) dict[@"firstDayOfTheWeek"] = fdow;

        id end = [rule valueForKey:@"recurrenceEnd"];
        if (end) {
            NSMutableDictionary *endDict = [NSMutableDictionary dictionary];
            NSDate *endDate = [end valueForKey:@"endDate"];
            if ([endDate isKindOfClass:[NSDate class]]) endDict[@"endDate"] = @(endDate.timeIntervalSince1970);
            NSNumber *occ = [end valueForKey:@"occurrenceCount"];
            if ([occ isKindOfClass:[NSNumber class]] && [occ intValue] > 0) endDict[@"occurrenceCount"] = occ;
            if (endDict.count > 0) dict[@"recurrenceEnd"] = endDict;
        }

        [result addObject:dict];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// MARK: - Reminder enumeration

// fetchRemindersForEventKitBridgingWithListIDs: is the one call that returns
// EVERY reminder including subtasks — enumerateAllRemindersWithBlock: only
// yields top-level reminders and silently drops children (verified: 1066 vs
// 1072, the 6 missing were all subtasks).
BOOL fetchReminders(id store, NSSet *sectionedListUUIDs,
                    NSMutableArray *reminderEntries, NSString **errorMessage) {
    NSMutableArray *listIDs = [NSMutableArray array];
    void (^listBlock)(id, BOOL *) = ^(id list, BOOL *sp) {
        id oid = [list valueForKey:@"objectID"];
        if (oid) [listIDs addObject:oid];
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store,
        NSSelectorFromString(@"enumerateAllListsWithBlock:"), listBlock);

    SectionCache *secCache = nil;
    if (sectionedListUUIDs.count > 0) {
        secCache = [[SectionCache alloc] initWithStore:store];
    }

    NSError *err = nil;
    NSArray *reminders = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchRemindersForEventKitBridgingWithListIDs:error:"),
        listIDs, &err);
    if (![reminders isKindOfClass:[NSArray class]]) {
        if (errorMessage) {
            NSString *detail = [err localizedDescription];
            *errorMessage = detail.length > 0
                ? detail
                : @"ReminderKit did not return a reminders array";
        }
        return NO;
    }

    int reminderIdx = 0;
    for (id r in reminders) {
        NSString *title = [r valueForKey:@"titleAsString"];
        if (![title isKindOfClass:[NSString class]]) title = @"";
        NSString *extId = [r valueForKey:@"daCalendarItemUniqueIdentifier"];
        NSString *extIdStr = [extId isKindOfClass:[NSString class]] ? extId : @"";
        NSString *rListUUID = extractUUID([r valueForKey:@"listID"]);
        NSTimeZone *tz = nil;
        id tzVal = [r valueForKey:@"timeZone"];
        if ([tzVal isKindOfClass:[NSTimeZone class]]) {
            tz = tzVal;
        } else if ([tzVal isKindOfClass:[NSString class]]) {
            tz = [NSTimeZone timeZoneWithName:(NSString *)tzVal];
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"externalIdentifier"] = extIdStr;
        entry[@"listID"] = rListUUID ?: @"";
        if (title.length > 0) entry[@"title"] = title;

        NSString *notes = [r valueForKey:@"notesAsString"];
        if ([notes isKindOfClass:[NSString class]] && notes.length > 0) entry[@"notes"] = notes;

        NSNumber *priority = [r valueForKey:@"priority"];
        entry[@"priority"] = [priority isKindOfClass:[NSNumber class]] ? priority : @0;
        entry[@"completed"] = @([[r valueForKey:@"completed"] boolValue]);

        NSDate *creationDate = [r valueForKey:@"creationDate"];
        if ([creationDate isKindOfClass:[NSDate class]]) entry[@"creationDate"] = @(creationDate.timeIntervalSince1970);
        NSDate *completionDate = [r valueForKey:@"completionDate"];
        if ([completionDate isKindOfClass:[NSDate class]]) entry[@"completionDate"] = @(completionDate.timeIntervalSince1970);

        NSNumber *due = componentsToEpoch([r valueForKey:@"dueDateComponents"], tz);
        if (due) entry[@"dueDate"] = due;
        NSNumber *start = componentsToEpoch([r valueForKey:@"startDateComponents"], tz);
        if (start) entry[@"startDate"] = start;

        entry[@"allDay"] = @([[r valueForKey:@"allDay"] boolValue]);
        if ([tz isKindOfClass:[NSTimeZone class]]) entry[@"timeZone"] = tz.name;

        NSString *recur = encodeRecurrenceRules([r valueForKey:@"recurrenceRules"]);
        if (recur) entry[@"recurrenceRules"] = recur;

        entry[@"order"] = @(reminderIdx++);

        // section mapping (with cache for consecutive same-section reminders)
        if (rListUUID && extIdStr.length > 0 && [sectionedListUUIDs containsObject:rListUUID]) {
            NSString *secName = [secCache sectionForReminder:r listUUID:rListUUID];
            if (secName) entry[@"section"] = secName;
        }

        entry[@"flagged"] = @([[r valueForKey:@"flagged"] boolValue]);
        entry[@"urgent"] = @([[r valueForKey:@"isUrgentStateEnabledForCurrentUser"] boolValue]);

        // alarms (提前提醒 / 位置提醒)
        NSArray *alarms = [r valueForKey:@"alarms"];
        if ([alarms isKindOfClass:[NSArray class]] && alarms.count > 0) {
            NSMutableArray *alarmList = [NSMutableArray array];
            for (id a in alarms) {
                id trigger = nil;
                @try { trigger = [a valueForKey:@"trigger"]; } @catch (NSException *e) {}
                if (!trigger) continue;
                NSString *tClass = NSStringFromClass([trigger class]);
                NSMutableDictionary *al = [NSMutableDictionary dictionary];
                if ([tClass isEqualToString:@"REMAlarmDateTrigger"]) {
                    NSNumber *epoch = componentsToEpoch([trigger valueForKey:@"dateComponents"], tz);
                    al[@"type"] = @"date";
                    if (epoch) al[@"date"] = epoch;
                } else if ([tClass isEqualToString:@"REMAlarmTimeIntervalTrigger"]) {
                    NSNumber *ti = [trigger valueForKey:@"timeInterval"];
                    al[@"type"] = @"interval";
                    if (ti) al[@"interval"] = ti;
                } else if ([tClass isEqualToString:@"REMAlarmDueDateDeltaAlertTrigger"]) {
                    NSNumber *delta = [trigger valueForKey:@"dueDateDelta"];
                    al[@"type"] = @"dueDateDelta";
                    if (delta) al[@"delta"] = delta;
                } else if ([tClass isEqualToString:@"REMAlarmLocationTrigger"]) {
                    NSNumber *prox = [trigger valueForKey:@"proximity"];
                    id loc = [trigger valueForKey:@"structuredLocation"];
                    al[@"type"] = @"location";
                    if (prox) al[@"proximity"] = prox;
                    if (loc) {
                        NSMutableDictionary *ld = [NSMutableDictionary dictionary];
                        id lt = [loc valueForKey:@"title"];
                        if ([lt isKindOfClass:[NSString class]]) ld[@"title"] = lt;
                        NSNumber *lat = [loc valueForKey:@"latitude"];
                        NSNumber *lon = [loc valueForKey:@"longitude"];
                        if (lat) ld[@"latitude"] = lat;
                        if (lon) ld[@"longitude"] = lon;
                        if (ld.count > 0) al[@"location"] = ld;
                    }
                } else if ([tClass isEqualToString:@"REMAlarmContactTrigger"]) {
                    al[@"type"] = @"contact";
                } else {
                    al[@"type"] = tClass;
                }
                [alarmList addObject:al];
            }
            if (alarmList.count > 0) entry[@"alarms"] = alarmList;
        }

        // url + attachments (URL 存在 attachments 里, 类型 REMURLAttachment)
        NSArray *attachments = [r valueForKey:@"attachments"];
        if ([attachments isKindOfClass:[NSArray class]] && attachments.count > 0) {
            for (id att in attachments) {
                NSString *attClass = NSStringFromClass([att class]);
                if ([attClass isEqualToString:@"REMURLAttachment"]) {
                    id url = [att valueForKey:@"url"];
                    NSString *urlStr = nil;
                    if ([url isKindOfClass:[NSString class]]) urlStr = url;
                    else if ([url isKindOfClass:[NSURL class]]) urlStr = [url absoluteString];
                    if (urlStr.length > 0) entry[@"url"] = urlStr;
                    break;
                }
            }
        }


        NSString *parentUUID = extractUUID([r valueForKey:@"parentReminderID"]);
        if (parentUUID) entry[@"parentId"] = parentUUID;

        // tags
        NSArray *hashtags = [r valueForKey:@"hashtags"];
        if ([hashtags respondsToSelector:@selector(count)] && [hashtags count] > 0) {
            NSMutableArray *tagNames = [NSMutableArray array];
            for (id h in hashtags) {
                NSString *name = [h valueForKey:@"name"];
                if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                    [tagNames addObject:name];
                }
            }
            if (tagNames.count > 0) entry[@"tags"] = tagNames;
        }

        [reminderEntries addObject:entry];
    }
    return YES;
}
