#import "ReminderKit.h"
#import <objc/message.h>

// MARK: - Lookups

// Hierarchy-write helpers (implemented after opUpdateList).
static NSDictionary *fetchAllGroups(id store);
static id resolveGroup(id store, NSString *groupID, NSString *groupName, NSDictionary **error);
static id findSectionInList(id store, id list, NSString *sectionName);
static NSDictionary *setReminderSection(id store, id saveReq, id list, id remCI, NSString *sectionName);

static NSArray *findListsNamed(id store, NSString *name) {
    NSMutableArray *matches = [NSMutableArray array];
    void (^lb)(id, BOOL *) = ^(id list, BOOL *sp) {
        if ([[list valueForKey:@"name"] isEqualToString:name]) {
            [matches addObject:[list retain]];  // non-ARC: retain, caller releases
        }
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"enumerateAllListsWithBlock:"), lb);
    return matches;
}

/// Find lists matching a full UUID or an unambiguous ≥8-char UUID prefix.
static NSArray *findListsByIDOrPrefix(id store, NSString *uuidStr) {
    NSMutableArray *matches = [NSMutableArray array];
    void (^blk)(id, BOOL *) = ^(id list, BOOL *sp) {
        NSString *u = extractUUID([list valueForKey:@"objectID"]);
        if (u && ([u isEqualToString:uuidStr] ||
                  (uuidStr.length >= 8 && [u.lowercaseString hasPrefix:uuidStr.lowercaseString]))) {
            [matches addObject:[list retain]];  // non-ARC: retain, caller releases
        }
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"enumerateAllListsWithBlock:"), blk);
    return matches;
}

/// 候选列表描述：带分组归属，如「数码（理财消费）[B1D35ED8-…]」「数码（顶层）[18713335-…]」，
/// 让 agent 一眼区分同名列表，无需再查分组。
static NSString *describeListCandidates(id store, NSArray *lists) {
    NSDictionary *groups = fetchGroups(store);
    NSMutableArray *parts = [NSMutableArray array];
    for (id l in lists) {
        NSString *name = [[l valueForKey:@"name"] isKindOfClass:[NSString class]]
            ? [l valueForKey:@"name"] : @"";
        NSString *parentUUID = extractUUID([l valueForKey:@"parentListID"]);
        NSString *groupName = parentUUID ? groups[parentUUID] : nil;
        NSString *uuid = extractUUID([l valueForKey:@"objectID"]) ?: @"";
        NSString *groupLabel = ([groupName isKindOfClass:[NSString class]] && groupName.length > 0)
            ? groupName : @"顶层";
        [parts addObject:[NSString stringWithFormat:@"%@（%@）[%@]", name, groupLabel, uuid]];
    }
    return [parts componentsJoinedByString:@", "];
}

/// Resolve a list: --list-id (or --list) 接受完整 UUID / ≥8 位前缀，--list 再按精确名称。
/// 名称重名时返回结构化错误列出候选 ID（agent 用 --list-id 精确定位）。
static id resolveList(id store, NSString *listID, NSString *name, NSDictionary **error) {
    NSString *target = listID.length > 0 ? listID : name;
    if (target.length > 0) {
        NSArray *idMatches = findListsByIDOrPrefix(store, target);
        if (idMatches.count == 1) return idMatches[0];
        if (idMatches.count > 1) {
            NSMutableArray *ids = [NSMutableArray array];
            for (id l in idMatches) {
                NSString *u = extractUUID([l valueForKey:@"objectID"]);
                if (u) [ids addObject:u];
            }
            *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:
                @"ID「%@」匹配到 %lu 个列表（ID 前缀重复），请用完整 UUID 精确定位：%@",
                target, (unsigned long)idMatches.count, describeListCandidates(store, idMatches)]};
            return nil;
        }
    }
    // 仅按名称解析（显式 --list-id 不走名称匹配）
    if (listID.length == 0 && name.length > 0) {
        NSArray *matches = findListsNamed(store, name);
        if (matches.count > 1) {
            *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:
                @"列表名「%@」匹配到 %lu 个列表（名称重复），请用 --list-id 精确定位：%@",
                name, (unsigned long)matches.count, describeListCandidates(store, matches)]};
            return nil;
        }
        if (matches.count == 1) return matches[0];
    }
    *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到列表：%@", target]};
    return nil;
}

static id findReminderByExtId(id store, NSString *extId) {
    __block id found = nil;
    // enumerateAllRemindersWithBlock: only yields top-level reminders and
    // silently drops subtasks — use fetchRemindersForEventKitBridgingWithListIDs:
    // which returns EVERY reminder including children, then match by id.
    NSMutableArray *listIDs = [NSMutableArray array];
    void (^listBlock)(id, BOOL *) = ^(id list, BOOL *sp) {
        id oid = [list valueForKey:@"objectID"];
        if (oid) [listIDs addObject:oid];
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store,
        NSSelectorFromString(@"enumerateAllListsWithBlock:"), listBlock);
    NSError *err = nil;
    NSArray *reminders = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchRemindersForEventKitBridgingWithListIDs:error:"),
        listIDs, &err);
    if (![reminders isKindOfClass:[NSArray class]]) return nil;
    for (id r in reminders) {
        id e = [r valueForKey:@"daCalendarItemUniqueIdentifier"];
        if ([e isKindOfClass:[NSString class]] && [e isEqualToString:extId]) {
            found = [r retain];
            break;
        }
    }
    return found;
}

static NSString *listNameOfReminder(id reminder) {
    id list = [reminder valueForKey:@"list"];
    return [list valueForKey:@"name"];
}

// MARK: - Save request plumbing

static id makeSaveRequest(id store, NSString *author) {
    id req = ((id(*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"REMSaveRequest") alloc],
        NSSelectorFromString(@"initWithStore:"), store);
    if (req) {
        ((void(*)(id, SEL, id))objc_msgSend)(req, NSSelectorFromString(@"setAuthor:"), author ?: @"remindkit");
        // Sync to CloudKit so writes propagate to other devices via iCloud.
        // (Previously NO — that silently disabled iCloud sync for every write.)
        ((void(*)(id, SEL, BOOL))objc_msgSend)(req, NSSelectorFromString(@"setSyncToCloudKit:"), YES);
    }
    return req;
}

static BOOL saveRequest(id req, NSError **err) {
    return ((BOOL(*)(id, SEL, id*))objc_msgSend)(req, NSSelectorFromString(@"saveSynchronouslyWithError:"), err);
}

static NSDictionary *saveError(id req, NSError *err) {
    return @{@"ok": @NO, @"error": err ? [err description] : @"save failed"};
}

// MARK: - Field setters

static id makeHashtag(id accountID, id reminderObjectID, NSString *name) {
    id htObjID = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
        NSSelectorFromString(@"initWithUUID:entityName:"), [NSUUID UUID], @"REMCDHashtag");
    return ((id(*)(id, SEL, id, id, id, NSUInteger, id))objc_msgSend)([NSClassFromString(@"REMHashtag") alloc],
        NSSelectorFromString(@"initWithObjectID:accountID:reminderID:type:name:"),
        htObjID, accountID, reminderObjectID, 0, name);
}

static NSDateComponents *epochToComponents(NSNumber *epoch) {
    if (!epoch) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch.doubleValue];
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = NSTimeZone.localTimeZone;
    return [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                             NSCalendarUnitHour | NSCalendarUnitMinute)
                  fromDate:date];
}

// MARK: - Operations

static void applyEditableFields(id store, id reminder, id remCI, NSDictionary *req, NSMutableDictionary *changes);

static NSDictionary *opAdd(id store, NSDictionary *req) {
    NSString *listName = req[@"listName"];
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], listName, &listErr);
    if (!list) return listErr;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
    id remCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"addReminderWithTitle:toListChangeItem:"), req[@"title"] ?: @"", listCI);

    NSDateComponents *due = epochToComponents(req[@"due"]);
    if (due) { [remCI setValue:due forKey:@"dueDateComponents"]; }
    NSDateComponents *start = epochToComponents(req[@"start"]);
    if (start) { [remCI setValue:start forKey:@"startDateComponents"]; }

    NSString *notes = req[@"notes"];
    if (notes.length > 0) { [remCI setValue:notes forKey:@"notesAsString"]; }

    NSNumber *priority = req[@"priority"];
    if (priority) { [remCI setValue:priority forKey:@"priority"]; }
    NSNumber *flagged = req[@"flagged"];
    if (flagged) { [remCI setValue:flagged forKey:@"flagged"]; }
    NSNumber *urgent = req[@"urgent"];
    if (urgent) { [remCI setValue:urgent forKey:@"isUrgentStateEnabledForCurrentUser"]; }
    NSNumber *completed = req[@"completed"];
    if (completed.boolValue) {
        [remCI setValue:@YES forKey:@"completed"];
        [remCI setValue:[NSDate date] forKey:@"completionDate"];
    }

    NSArray *tags = req[@"tags"];
    if ([tags isKindOfClass:[NSArray class]] && tags.count > 0) {
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        NSMutableSet *hts = [NSMutableSet set];
        for (id t in tags) {
            if ([t isKindOfClass:[NSString class]] && [t length] > 0) {
                [hts addObject:makeHashtag(acctObjID, remObjID, t)];
            }
        }
        if (hts.count > 0) { [remCI setValue:hts forKey:@"hashtags"]; }
    }

    NSString *parentId = req[@"parentId"];
    if (parentId.length > 0) {
        id parent = findReminderByExtId(store, parentId);
        if (!parent) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到父提醒：%@", parentId]};
        [remCI setValue:[parent valueForKey:@"objectID"] forKey:@"parentReminderID"];
    }

    NSDictionary *recur = req[@"recurrence"];
    if ([recur isKindOfClass:[NSDictionary class]]) {
        NSUInteger freq = [recur[@"frequency"] unsignedIntegerValue];
        NSUInteger interval = [recur[@"interval"] unsignedIntegerValue];
        id days = nil;
        if ([recur[@"days"] isKindOfClass:[NSArray class]] && [recur[@"days"] count] > 0) {
            NSMutableArray *dows = [NSMutableArray array];
            for (id d in recur[@"days"]) {
                NSUInteger dayNum = 0;
                NSInteger weekNum = 0;
                if ([d isKindOfClass:[NSNumber class]]) {
                    dayNum = [d unsignedIntegerValue];
                } else if ([d isKindOfClass:[NSDictionary class]]) {
                    dayNum = [d[@"day"] unsignedIntegerValue];
                    weekNum = [d[@"week"] integerValue];
                }
                [dows addObject:((id(*)(id, SEL, NSUInteger, NSInteger))objc_msgSend)(
                    [NSClassFromString(@"REMRecurrenceDayOfWeek") alloc],
                    NSSelectorFromString(@"initWithDayOfTheWeek:weekNumber:"), dayNum, weekNum)];
            }
            days = dows;
        }
        id end = nil;
        if (recur[@"until"]) {
            end = ((id(*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"REMRecurrenceEnd") alloc],
                NSSelectorFromString(@"initWithEndDate:"),
                [NSDate dateWithTimeIntervalSince1970:[recur[@"until"] doubleValue]]);
        }
        // complex fields: daysOfTheMonth / monthsOfTheYear / setPositions
        NSArray *dom = recur[@"daysOfTheMonth"];
        NSArray *moy = recur[@"monthsOfTheYear"];
        NSArray *setPos = recur[@"setPositions"];
        if ([dom isKindOfClass:[NSArray class]] && dom.count == 0) dom = nil;
        if ([moy isKindOfClass:[NSArray class]] && moy.count == 0) moy = nil;
        if ([setPos isKindOfClass:[NSArray class]] && setPos.count == 0) setPos = nil;
        ((void(*)(id, SEL, NSUInteger, NSUInteger, id, id, id, id, id, id, id))objc_msgSend)(remCI,
            NSSelectorFromString(@"addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:"),
            freq, interval, days, dom, moy, nil, nil, setPos, end);
    }

    // url (REMURLAttachment in attachments)
    NSString *urlStr = req[@"url"];
    if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        id attObjID = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
            NSSelectorFromString(@"initWithUUID:entityName:"), [NSUUID UUID], @"REMCDURLAttachment");
        id att = ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)([NSClassFromString(@"REMURLAttachment") alloc],
            NSSelectorFromString(@"initWithObjectID:accountID:reminderID:url:metadata:"),
            attObjID, acctObjID, remObjID, [NSURL URLWithString:urlStr], nil);
        NSArray *existing = [remCI valueForKey:@"attachments"] ?: @[];
        [remCI setValue:[existing arrayByAddingObject:att] forKey:@"attachments"];
    }

    // alarms (提前提醒 / 位置提醒)
    NSArray *alarms = req[@"alarms"];
    if ([alarms isKindOfClass:[NSArray class]] && alarms.count > 0) {
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        for (NSDictionary *al in alarms) {
            NSString *atype = al[@"type"];
            if ([atype isEqualToString:@"date"]) {
                NSDateComponents *dc = epochToComponents(al[@"date"]);
                if (dc) {
                    id trigger = ((id(*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"REMAlarmDateTrigger") alloc],
                        NSSelectorFromString(@"initWithDateComponents:"), dc);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            } else if ([atype isEqualToString:@"interval"]) {
                NSNumber *ti = al[@"interval"];
                if (ti) {
                    id trigger = ((id(*)(id, SEL, NSTimeInterval))objc_msgSend)([NSClassFromString(@"REMAlarmTimeIntervalTrigger") alloc],
                        NSSelectorFromString(@"initWithTimeInterval:"), ti.doubleValue);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            } else if ([atype isEqualToString:@"dueDateDelta"]) {
                NSNumber *delta = al[@"delta"];
                if (delta) {
                    id ctx = [remCI valueForKey:@"dueDateDeltaAlertContext"];
                    ((void(*)(id, SEL, id))objc_msgSend)(ctx, NSSelectorFromString(@"addDueDateDeltaAlertWithDueDateDelta:"), delta);
                }
            } else if ([atype isEqualToString:@"location"]) {
                NSString *title = al[@"title"];
                NSNumber *lat = al[@"latitude"];
                NSNumber *lon = al[@"longitude"];
                NSNumber *radius = al[@"radius"] ?: @100;
                NSInteger proximity = [al[@"proximity"] integerValue] ?: 1; // default: arrive
                if (title.length > 0 && lat && lon) {
                    id loc = ((id(*)(id, SEL, id, id, double, double, double, id, id, id, id, id))objc_msgSend)(
                        [NSClassFromString(@"REMStructuredLocation") alloc],
                        NSSelectorFromString(@"initWithTitle:locationUID:latitude:longitude:radius:address:routing:referenceFrameString:contactLabel:mapKitHandle:"),
                        title, nil, lat.doubleValue, lon.doubleValue, radius.doubleValue, nil, nil, nil, nil, nil);
                    id trigger = ((id(*)(id, SEL, id, NSInteger))objc_msgSend)([NSClassFromString(@"REMAlarmLocationTrigger") alloc],
                        NSSelectorFromString(@"initWithStructuredLocation:proximity:"), loc, proximity);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            }
        }
    }

    NSString *sectionName = req[@"section"];
    NSDictionary *secErr = nil;
    if ([sectionName isKindOfClass:[NSString class]] && sectionName.length > 0) {
        secErr = setReminderSection(store, saveReq, list, remCI, sectionName);
        if (secErr) return secErr;
    }

    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    id newId = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"daCalendarItemUniqueIdentifier"));
    // 回显落点：listTitle + section，agent 无需再 query 验证
    NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES,
        @"id": [newId isKindOfClass:[NSString class]] ? newId : @"",
        @"listTitle": ([[list valueForKey:@"name"] isKindOfClass:[NSString class]]
                        ? [list valueForKey:@"name"] : @""),
    }];
    if ([sectionName isKindOfClass:[NSString class]] && sectionName.length > 0) {
        resp[@"section"] = sectionName;
    }
    return resp;
}

static NSDictionary *opComplete(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    id reminder = findReminderByExtId(store, extId);
    if (!reminder) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到提醒：%@", extId]};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), reminder);
    BOOL completed = [req[@"completed"] boolValue];
    [remCI setValue:@(completed) forKey:@"completed"];
    [remCI setValue:completed ? [NSDate date] : nil forKey:@"completionDate"];
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extId, @"completed": @(completed)};
}

static NSDictionary *opUpdate(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    id reminder = findReminderByExtId(store, extId);
    if (!reminder) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到提醒：%@", extId]};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), reminder);
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    applyEditableFields(store, reminder, remCI, req, changes);
    NSString *sectionName = req[@"section"];
    NSDictionary *secErr = nil;
    if ([sectionName isKindOfClass:[NSString class]] && sectionName.length > 0) {
        id list = [reminder valueForKey:@"list"];
        secErr = setReminderSection(store, saveReq, list, remCI, sectionName);
        if (secErr) return secErr;
        changes[@"section"] = sectionName;
    }
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extId, @"changes": changes};
}

// Apply editable fields to an existing reminder's change item. Mirrors
// opAdd's field logic; shared by opUpdate so both paths stay in sync.
static void applyEditableFields(id store, id reminder, id remCI, NSDictionary *req, NSMutableDictionary *changes) {
    if ([req[@"title"] isKindOfClass:[NSString class]]) {
        [remCI setValue:req[@"title"] forKey:@"titleAsString"];
        changes[@"title"] = req[@"title"];
    }
    if ([req[@"notes"] isKindOfClass:[NSString class]]) {
        [remCI setValue:req[@"notes"] forKey:@"notesAsString"];
        changes[@"notes"] = req[@"notes"];
    }
    NSDateComponents *due = epochToComponents(req[@"due"]);
    if (due) { [remCI setValue:due forKey:@"dueDateComponents"]; changes[@"due"] = req[@"due"]; }
    NSDateComponents *start = epochToComponents(req[@"start"]);
    if (start) { [remCI setValue:start forKey:@"startDateComponents"]; changes[@"start"] = req[@"start"]; }
    NSNumber *priority = req[@"priority"];
    if (priority) { [remCI setValue:priority forKey:@"priority"]; changes[@"priority"] = priority; }
    if (req[@"flagged"] != nil) {
        BOOL flagged = [req[@"flagged"] boolValue];
        [remCI setValue:@(flagged) forKey:@"flagged"];
        changes[@"flagged"] = @(flagged);
    }
    if (req[@"urgent"] != nil) {
        BOOL urgent = [req[@"urgent"] boolValue];
        [remCI setValue:@(urgent) forKey:@"isUrgentStateEnabledForCurrentUser"];
        changes[@"urgent"] = @(urgent);
    }
    if (req[@"completed"] != nil) {
        BOOL completed = [req[@"completed"] boolValue];
        [remCI setValue:@(completed) forKey:@"completed"];
        [remCI setValue:completed ? [NSDate date] : nil forKey:@"completionDate"];
        changes[@"completed"] = @(completed);
    }
    NSArray *tags = req[@"tags"];
    if ([tags isKindOfClass:[NSArray class]] && tags.count > 0) {
        id list = [reminder valueForKey:@"list"];
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        NSMutableSet *hts = [NSMutableSet set];
        for (id t in tags) {
            if ([t isKindOfClass:[NSString class]] && [t length] > 0) {
                [hts addObject:makeHashtag(acctObjID, remObjID, t)];
            }
        }
        if (hts.count > 0) { [remCI setValue:hts forKey:@"hashtags"]; changes[@"tags"] = tags; }
    }
    NSDictionary *recur = req[@"recurrence"];
    if ([recur isKindOfClass:[NSDictionary class]]) {
        NSUInteger freq = [recur[@"frequency"] unsignedIntegerValue];
        NSUInteger interval = [recur[@"interval"] unsignedIntegerValue];
        id days = nil;
        if ([recur[@"days"] isKindOfClass:[NSArray class]] && [recur[@"days"] count] > 0) {
            NSMutableArray *dows = [NSMutableArray array];
            for (id d in recur[@"days"]) {
                NSUInteger dayNum = 0;
                NSInteger weekNum = 0;
                if ([d isKindOfClass:[NSNumber class]]) {
                    dayNum = [d unsignedIntegerValue];
                } else if ([d isKindOfClass:[NSDictionary class]]) {
                    dayNum = [d[@"day"] unsignedIntegerValue];
                    weekNum = [d[@"week"] integerValue];
                }
                [dows addObject:((id(*)(id, SEL, NSUInteger, NSInteger))objc_msgSend)(
                    [NSClassFromString(@"REMRecurrenceDayOfWeek") alloc],
                    NSSelectorFromString(@"initWithDayOfTheWeek:weekNumber:"), dayNum, weekNum)];
            }
            days = dows;
        }
        id end = nil;
        if (recur[@"until"]) {
            end = ((id(*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"REMRecurrenceEnd") alloc],
                NSSelectorFromString(@"initWithEndDate:"),
                [NSDate dateWithTimeIntervalSince1970:[recur[@"until"] doubleValue]]);
        }
        NSArray *dom = recur[@"daysOfTheMonth"];
        NSArray *moy = recur[@"monthsOfTheYear"];
        NSArray *setPos = recur[@"setPositions"];
        if ([dom isKindOfClass:[NSArray class]] && dom.count == 0) dom = nil;
        if ([moy isKindOfClass:[NSArray class]] && moy.count == 0) moy = nil;
        if ([setPos isKindOfClass:[NSArray class]] && setPos.count == 0) setPos = nil;
        ((void(*)(id, SEL, NSUInteger, NSUInteger, id, id, id, id, id, id, id))objc_msgSend)(remCI,
            NSSelectorFromString(@"addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:"),
            freq, interval, days, dom, moy, nil, nil, setPos, end);
        changes[@"recurrence"] = @YES;
    }
    NSString *urlStr = req[@"url"];
    if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
        id list = [reminder valueForKey:@"list"];
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        id attObjID = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
            NSSelectorFromString(@"initWithUUID:entityName:"), [NSUUID UUID], @"REMCDURLAttachment");
        id att = ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)([NSClassFromString(@"REMURLAttachment") alloc],
            NSSelectorFromString(@"initWithObjectID:accountID:reminderID:url:metadata:"),
            attObjID, acctObjID, remObjID, [NSURL URLWithString:urlStr], nil);
        NSArray *existing = [remCI valueForKey:@"attachments"] ?: @[];
        [remCI setValue:[existing arrayByAddingObject:att] forKey:@"attachments"];
        changes[@"url"] = urlStr;
    }
    NSArray *alarms = req[@"alarms"];
    if ([alarms isKindOfClass:[NSArray class]] && alarms.count > 0) {
        id list = [reminder valueForKey:@"list"];
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        for (NSDictionary *al in alarms) {
            NSString *atype = al[@"type"];
            if ([atype isEqualToString:@"date"]) {
                NSDateComponents *dc = epochToComponents(al[@"date"]);
                if (dc) {
                    id trigger = ((id(*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"REMAlarmDateTrigger") alloc],
                        NSSelectorFromString(@"initWithDateComponents:"), dc);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            } else if ([atype isEqualToString:@"interval"]) {
                NSNumber *ti = al[@"interval"];
                if (ti) {
                    id trigger = ((id(*)(id, SEL, NSTimeInterval))objc_msgSend)([NSClassFromString(@"REMAlarmTimeIntervalTrigger") alloc],
                        NSSelectorFromString(@"initWithTimeInterval:"), ti.doubleValue);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            } else if ([atype isEqualToString:@"dueDateDelta"]) {
                NSNumber *delta = al[@"delta"];
                if (delta) {
                    id ctx = [remCI valueForKey:@"dueDateDeltaAlertContext"];
                    ((void(*)(id, SEL, id))objc_msgSend)(ctx, NSSelectorFromString(@"addDueDateDeltaAlertWithDueDateDelta:"), delta);
                }
            } else if ([atype isEqualToString:@"location"]) {
                NSString *title = al[@"title"];
                NSNumber *lat = al[@"latitude"];
                NSNumber *lon = al[@"longitude"];
                NSNumber *radius = al[@"radius"] ?: @100;
                NSInteger proximity = [al[@"proximity"] integerValue] ?: 1;
                if (title.length > 0 && lat && lon) {
                    id loc = ((id(*)(id, SEL, id, id, double, double, double, id, id, id, id, id))objc_msgSend)(
                        [NSClassFromString(@"REMStructuredLocation") alloc],
                        NSSelectorFromString(@"initWithTitle:locationUID:latitude:longitude:radius:address:routing:referenceFrameString:contactLabel:mapKitHandle:"),
                        title, nil, lat.doubleValue, lon.doubleValue, radius.doubleValue, nil, nil, nil, nil, nil);
                    id trigger = ((id(*)(id, SEL, id, NSInteger))objc_msgSend)([NSClassFromString(@"REMAlarmLocationTrigger") alloc],
                        NSSelectorFromString(@"initWithStructuredLocation:proximity:"), loc, proximity);
                    ((void(*)(id, SEL, id))objc_msgSend)(remCI, NSSelectorFromString(@"addAlarmWithTrigger:"), trigger);
                }
            }
        }
        changes[@"alarms"] = @(alarms.count);
    }
}

static NSDictionary *opDelete(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    id reminder = findReminderByExtId(store, extId);
    if (!reminder) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到提醒：%@", extId]};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), reminder);
    ((void(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"removeFromList"));
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extId, @"deleted": @YES,
             @"title": [reminder valueForKey:@"titleAsString"] ?: @"",
             @"listName": listNameOfReminder(reminder) ?: @""};
}

static NSDictionary *opMove(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    id reminder = findReminderByExtId(store, extId);
    if (!reminder) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到提醒：%@", extId]};
    NSString *toName = req[@"toListName"];
    NSDictionary *listErr = nil;
    id toList = resolveList(store, req[@"toListID"], toName, &listErr);
    if (!toList) return listErr;

    // Collect the whole subtree (the reminder + every descendant via the
    // parentReminderID chain). ReminderKit enforces that a subtask shares its
    // parent's list, so moving a parent requires moving its entire subtree;
    // saving a partial move fails with -3002 "Subtask has different list".
    NSMutableArray *subtree = [NSMutableArray arrayWithObject:reminder];
    NSMutableDictionary *childrenOf = [NSMutableDictionary dictionary];
    {
        NSMutableArray *listIDs = [NSMutableArray array];
        void (^lb)(id, BOOL *) = ^(id list, BOOL *sp) {
            id oid = [list valueForKey:@"objectID"];
            if (oid) [listIDs addObject:oid];
        };
        ((void(*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"enumerateAllListsWithBlock:"), lb);
        NSError *fe = nil;
        NSArray *all = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
            NSSelectorFromString(@"fetchRemindersForEventKitBridgingWithListIDs:error:"), listIDs, &fe);
        for (id r in all) {
            id pid = [r valueForKey:@"parentReminderID"];
            if (!pid) continue;
            NSString *key = [pid description];
            if (!childrenOf[key]) childrenOf[key] = [NSMutableArray array];
            [childrenOf[key] addObject:r];
        }
    }
    NSMutableArray *queue = [NSMutableArray arrayWithObject:reminder];
    while (queue.count > 0) {
        id cur = queue[0];
        [queue removeObjectAtIndex:0];
        NSArray *kids = childrenOf[[[cur valueForKey:@"objectID"] description]];
        for (id kid in kids) {
            if (![subtree containsObject:kid]) {
                [subtree addObject:kid];
                [queue addObject:kid];
            }
        }
    }

    // True move: attach the ORIGINAL change items to the target list.
    // REMListChangeItem -addReminderChangeItem: re-parents the existing
    // reminder (identifier preserved) instead of copying — unlike the old
    // _copyReminderChangeItem:toListChangeItem: + removeFromList dance, which
    // produced a NEW identifier and dropped the old reminder. Children attach
    // to their parent's subtask context so parent/child links survive;
    // ReminderKit then enforces same-list consistency across the subtree.
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI2 = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), toList);
    NSMutableDictionary *parentCIByID = [NSMutableDictionary dictionary];
    for (id r in subtree) {
        id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), r);
        NSString *key = [[r valueForKey:@"objectID"] description];
        parentCIByID[key] = remCI;
        if (r == reminder) {
            ((void(*)(id, SEL, id))objc_msgSend)(listCI2, NSSelectorFromString(@"addReminderChangeItem:"), remCI);
        } else {
            id pid = [r valueForKey:@"parentReminderID"];
            id parentCI = pid ? parentCIByID[[pid description]] : nil;
            if (parentCI) {
                id subCtx = ((id(*)(id, SEL))objc_msgSend)(parentCI, NSSelectorFromString(@"subtaskContext"));
                ((void(*)(id, SEL, id))objc_msgSend)(subCtx, NSSelectorFromString(@"addReminderChangeItem:"), remCI);
            } else {
                ((void(*)(id, SEL, id))objc_msgSend)(listCI2, NSSelectorFromString(@"addReminderChangeItem:"), remCI);
            }
        }
    }
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    // True move keeps the identifier — no copy, no deletion, no recently-deleted entry.
    NSString *resolvedToName = [toList valueForKey:@"name"];
    return @{@"ok": @YES, @"id": extId, @"toList": resolvedToName ?: toName ?: @""};
}

// MARK: - Entry

/// Verify which of the given IDs are still marked-for-delete, with metadata.
static NSDictionary *opDeleted(id store, NSDictionary *req) {
    NSArray *ids = req[@"ids"];
    NSMutableArray *deleted = [NSMutableArray array];
    for (id item in ids) {
        NSString *uid = item;
        if (![uid isKindOfClass:[NSString class]]) continue;
        id oid = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
            NSSelectorFromString(@"initWithUUID:entityName:"),
            [[NSUUID alloc] initWithUUIDString:uid], @"REMCDReminder");
        NSError *err = nil;
        id r = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
            NSSelectorFromString(@"fetchReminderIncludingMarkedForDeleteWithObjectID:error:"), oid, &err);
        if (!r) continue; // already purged or restored
        [deleted addObject:@{
            @"id": uid,
            @"title": [r valueForKey:@"titleAsString"] ?: @"",
        }];
    }
    return @{@"ok": @YES, @"deleted": deleted};
}

/// Restore a marked-for-delete reminder by re-assigning its listID.
static NSDictionary *opRestore(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    NSString *listName = req[@"listName"];
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], listName, &listErr);
    if (!list) return listErr;

    id oid = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
        NSSelectorFromString(@"initWithUUID:entityName:"),
        [[NSUUID alloc] initWithUUIDString:extId], @"REMCDReminder");
    NSError *err = nil;
    id r = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchReminderIncludingMarkedForDeleteWithObjectID:error:"), oid, &err);
    if (!r) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到最近删除中的提醒：%@", extId]};

    id saveReq = makeSaveRequest(store, req[@"author"]);
    id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), r);
    [remCI setValue:[list valueForKey:@"objectID"] forKey:@"listID"];
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extId, @"listName": listName};
}

/// Delete a list (regular list or custom smart list).
static NSDictionary *opDeleteList(id store, NSDictionary *req) {
    NSString *name = req[@"listName"];
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);

    // 1) regular list: updateList: -> removeFromParent.
    //    Ambiguity (same-named lists) must error out; only "not found" may
    //    fall through to the smart-list check below.
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], name, &listErr);
    if (listErr && ![listErr[@"error"] hasPrefix:@"找不到列表"]) {
        return listErr;
    }
    if (list) {
        id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
        ((void(*)(id, SEL))objc_msgSend)(listCI, NSSelectorFromString(@"removeFromParent"));
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        return @{@"ok": @YES, @"listName": name ?: @"", @"type": @"list", @"deleted": @YES};
    }

    // 2) custom smart list: updateSmartList: -> removeFromParentWithAccountChangeItem:
    id smartLists = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
    for (id sl in (NSArray *)smartLists) {
        NSString *slUUID = extractUUID([sl valueForKey:@"objectID"]);
        BOOL nameMatch = ([name isKindOfClass:[NSString class]] && [[sl valueForKey:@"name"] isEqualToString:name]);
        BOOL idMatch = (req[@"listID"] && slUUID &&
                        ([slUUID isEqualToString:req[@"listID"]] ||
                         ([req[@"listID"] length] >= 8 && [slUUID.lowercaseString hasPrefix:[req[@"listID"] lowercaseString]])));
        if (nameMatch || idMatch) {
            id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchAccountsWithError:"), &err);
            id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
            if (!acct) return @{@"ok": @NO, @"error": @"找不到账户"};
            id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);
            id slCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateSmartList:"), sl);
            ((void(*)(id, SEL, id))objc_msgSend)(slCI,
                NSSelectorFromString(@"removeFromParentWithAccountChangeItem:"), acctCI);
            if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
            return @{@"ok": @YES, @"listName": name ?: @"", @"type": @"smartList", @"deleted": @YES};
        }
    }

    // 3) group (folder): groups are REMLists (isGroup) not covered by
    //    enumerateAllListsWithBlock:, so resolve them via account group context.
    NSDictionary *groups = fetchAllGroups(store);
    for (NSString *uuid in groups) {
        id g = groups[uuid];
        BOOL nameMatch = ([name isKindOfClass:[NSString class]] && [[g valueForKey:@"name"] isEqualToString:name]);
        BOOL idMatch = (req[@"listID"] && [uuid isEqualToString:req[@"listID"]]);
        if (nameMatch || idMatch) {
            id gci = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), g);
            ((void(*)(id, SEL))objc_msgSend)(gci, NSSelectorFromString(@"removeFromParent"));
            if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
            return @{@"ok": @YES, @"listName": name ?: @"", @"type": @"group", @"deleted": @YES};
        }
    }

    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到列表：%@", req[@"listID"] ?: (name ?: @"")]};
}

/// Update a regular list's name / icon / color.
static NSDictionary *opUpdateList(id store, NSDictionary *req) {
    NSString *name = req[@"listName"];
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], name, &listErr);
    if (!list) return listErr;

    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);

    NSString *newName = req[@"newName"];
    if ([newName isKindOfClass:[NSString class]] && newName.length > 0) {
        [listCI setValue:newName forKey:@"name"];
    }
    NSString *icon = req[@"icon"];
    if ([icon isKindOfClass:[NSString class]] && icon.length > 0) {
        NSString *badge = [NSString stringWithFormat:@"{\"Emoji\":\"%@\"}", icon];
        [listCI setValue:badge forKey:@"badgeEmblem"];
    }
    NSString *hex = req[@"color"];
    if ([hex isKindOfClass:[NSString class]] && hex.length > 0) {
        // Palette name drives the REMColor symbolic name; for preset palette
        // colors the symbolic name wins, for custom tones the hex is honored.
        NSString *ckName = [req[@"colorName"] isKindOfClass:[NSString class]] ? req[@"colorName"] : @"gray";
        id color = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMColor") alloc],
            NSSelectorFromString(@"initWithCKSymbolicColorName:hexString:"), ckName, hex);
        [listCI setValue:color forKey:@"color"];
    }

    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"listName": newName ?: (name ?: @""), @"updated": @YES};
}

// MARK: - Hierarchy writes (groups, lists-in-groups, sections, smart lists)
//
// Explored 2026-08-02: ReminderKit has no REMGroup class — folders are
// account-level group entities fetched via account groupContext. Sections
// are writable via REMListSectionChangeItem + REMMemberships; smart lists
// via addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:.

static NSDictionary *fetchAllGroups(id store) {
    NSError *acctErr = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchAccountsWithError:"), &acctErr);
    id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
    if (!acct) return @{};
    id groupCtx = [acct valueForKey:@"groupContext"];
    SEL fetchGrp = NSSelectorFromString(@"fetchGroupsWithError:");
    if (![groupCtx respondsToSelector:fetchGrp]) return @{};
    NSError *err = nil;
    id groups = ((id(*)(id, SEL, id*))objc_msgSend)(groupCtx, fetchGrp, &err);
    if (![groups isKindOfClass:[NSArray class]]) return @{};
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (id g in (NSArray *)groups) {
        NSString *uuid = extractUUID([g valueForKey:@"objectID"]);
        if (uuid) map[uuid] = g;
    }
    return map;
}

/// Resolve a group by exact ID or exact name; ambiguous names error out.
static id resolveGroup(id store, NSString *groupID, NSString *groupName, NSDictionary **error) {
    NSDictionary *groups = fetchAllGroups(store);
    if (groupID.length > 0) {
        id g = groups[groupID];
        if (!g) {
            *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到分组：%@", groupID]};
            return nil;
        }
        return g;
    }
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *uuid in groups) {
        if ([[groups[uuid] valueForKey:@"name"] isEqualToString:groupName]) {
            [matches addObject:groups[uuid]];
        }
    }
    if (matches.count > 1) {
        *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:
            @"分组名「%@」匹配到 %lu 个分组，请用 --group-id 精确定位", groupName, (unsigned long)matches.count]};
        return nil;
    }
    if (matches.count == 1) return matches[0];
    *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到分组：%@", groupName]};
    return nil;
}

/// Resolve a list's section by display name (same name-extraction hack as
/// Lists.m/Reminders.m). Returns the REMListSection object or nil.
static id findSectionInList(id store, id list, NSString *sectionName) {
    NSError *err = nil;
    id lsdv = [[NSClassFromString(@"REMListSectionsDataView") alloc] initWithStore:store];
    if (!lsdv) return nil;
    id secs = ((id(*)(id, SEL, id, id*))objc_msgSend)(lsdv,
        NSSelectorFromString(@"fetchListSectionsWithListObjectID:error:"),
        [list valueForKey:@"objectID"], &err);
    if (![secs respondsToSelector:@selector(count)]) return nil;
    NSInteger count = ((NSInteger(*)(id, SEL))objc_msgSend)(secs, @selector(count));
    for (NSInteger i = 0; i < count; i++) {
        id secObj = ((id(*)(id, SEL, NSInteger))objc_msgSend)(secs, @selector(objectAtIndex:), i);
        NSArray *names = parseSectionNames(secObj);
        if (names.count > 0 && [names[0] isEqualToString:sectionName]) return secObj;
    }
    return nil;
}

/// Attach a reminder change item to an existing section of its list via a
/// REMMembership(member=reminder, group=section). Returns nil on success or
/// an error dict (section missing / list has no sections).
static NSDictionary *setReminderSection(id store, id saveReq, id list, id remCI, NSString *sectionName) {
    if (!list) return @{@"ok": @NO, @"error": @"无法确定提醒所属列表"};
    id section = findSectionInList(store, list, sectionName);
    if (!section) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:
            @"列表「%@」中没有分区「%@」（先用 add-section 创建）",
            [list valueForKey:@"name"] ?: @"", sectionName]};
    }
    NSString *remUUID = extractUUID([remCI valueForKey:@"objectID"]);
    NSString *secUUID = extractUUID([section valueForKey:@"objectID"]);
    if (!remUUID || !secUUID) return @{@"ok": @NO, @"error": @"无法获取提醒/分区 ID"};

    id remNSUUID = [[NSUUID alloc] initWithUUIDString:remUUID];
    id secNSUUID = [[NSUUID alloc] initWithUUIDString:secUUID];
    id membership = ((id(*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
        [NSClassFromString(@"REMMembership") alloc],
        NSSelectorFromString(@"initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:"),
        remNSUUID, secNSUUID, NO, [NSDate date]);
    id memberships = ((id(*)(id, SEL, id))objc_msgSend)(
        [NSClassFromString(@"REMMemberships") alloc],
        NSSelectorFromString(@"initWithMemberships:"), @[membership]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
    id sectionCtx = [listCI valueForKey:@"sectionsContextChangeItem"];
    if (!sectionCtx) return @{@"ok": @NO, @"error": @"列表不支持分区"};
    ((void(*)(id, SEL, id))objc_msgSend)(sectionCtx,
        NSSelectorFromString(@"setUnsavedMembershipsOfRemindersInSections:"), memberships);
    return nil;
}

/// Create a group (folder). req: {op:createGroup, name, author}.
static NSDictionary *opCreateGroup(id store, NSDictionary *req) {
    NSString *name = req[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return @{@"ok": @NO, @"error": @"分组名不能为空"};
    }
    NSError *err = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchAccountsWithError:"), &err);
    id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
    if (!acct) return @{@"ok": @NO, @"error": @"找不到账户"};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);
    id groupCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"addGroupWithName:toAccountGroupContextChangeItem:"),
        name, [acctCI valueForKey:@"groupContext"]);
    if (!groupCI) return @{@"ok": @NO, @"error": @"创建分组失败"};
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extractUUID([groupCI valueForKey:@"objectID"]) ?: @"",
             @"name": name, @"type": @"group"};
}

/// Create a list, optionally inside a group. req: {op:createList, name,
/// groupID?/groupName?, author}. Top-level when no group given.
static NSDictionary *opCreateList(id store, NSDictionary *req) {
    NSString *name = req[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return @{@"ok": @NO, @"error": @"列表名不能为空"};
    }
    NSError *err = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchAccountsWithError:"), &err);
    id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
    if (!acct) return @{@"ok": @NO, @"error": @"找不到账户"};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);

    id listCI = nil;
    NSString *parentGroupID = nil;
    NSString *groupID = req[@"groupID"];
    NSString *groupName = req[@"groupName"];
    if (groupID.length > 0 || groupName.length > 0) {
        NSDictionary *gerr = nil;
        id group = resolveGroup(store, groupID, groupName, &gerr);
        if (!group) return gerr;
        parentGroupID = extractUUID([group valueForKey:@"objectID"]);
        id groupCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), group);
        id subCtx = [groupCI valueForKey:@"sublistContext"];
        listCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"addListWithName:toListSublistContextChangeItem:"), name, subCtx);
    } else {
        listCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"addListWithName:toAccountChangeItem:"), name, acctCI);
    }
    if (!listCI) return @{@"ok": @NO, @"error": @"创建列表失败"};
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES, @"id": extractUUID([listCI valueForKey:@"objectID"]) ?: @"",
        @"name": name, @"type": @"list"
    }];
    if (parentGroupID) out[@"groupID"] = parentGroupID;
    return out;
}

/// Add a section to a list. req: {op:addSection, listID?/listName, name, author}.
static NSDictionary *opAddSection(id store, NSDictionary *req) {
    NSString *name = req[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return @{@"ok": @NO, @"error": @"分区名不能为空"};
    }
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], req[@"listName"], &listErr);
    if (!list) return listErr;
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
    id sectionCtx = [listCI valueForKey:@"sectionsContextChangeItem"];
    if (!sectionCtx) return @{@"ok": @NO, @"error": @"列表不支持分区"};
    id sectionCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"addListSectionWithDisplayName:toListSectionContextChangeItem:"), name, sectionCtx);
    if (!sectionCI) return @{@"ok": @NO, @"error": @"创建分区失败"};
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extractUUID([sectionCI valueForKey:@"objectID"]) ?: @"",
             @"name": name, @"listID": extractUUID([list valueForKey:@"objectID"]) ?: @""};
}

/// Create a custom smart list. req: {op:createSmartList, name, color?,
/// displayName?, author}.
static NSDictionary *opCreateSmartList(id store, NSDictionary *req) {
    NSString *name = req[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return @{@"ok": @NO, @"error": @"智能列表名不能为空"};
    }
    NSString *displayName = req[@"displayName"];
    if (![displayName isKindOfClass:[NSString class]]) displayName = nil;
    NSError *err = nil;
    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchAccountsWithError:"), &err);
    id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
    if (!acct) return @{@"ok": @NO, @"error": @"找不到账户"};
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);
    NSUUID *slUUID = [NSUUID UUID];
    id slOID = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
        NSSelectorFromString(@"initWithUUID:entityName:"), slUUID, @"REMCDSmartList");
    id slCI = ((id(*)(id, SEL, id, id, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:"),
        name, acctCI, slOID);
    if (!slCI) return @{@"ok": @NO, @"error": @"创建智能列表失败"};
    id customCtx = [slCI valueForKey:@"customContext"];
    if (customCtx) {
        if (displayName.length > 0) {
            ((void(*)(id, SEL, id))objc_msgSend)(customCtx, NSSelectorFromString(@"setName:"), displayName);
        }
        NSString *hex = req[@"color"];
        if ([hex isKindOfClass:[NSString class]] && hex.length > 0) {
            NSString *ckName = req[@"colorName"];
            if (![ckName isKindOfClass:[NSString class]]) ckName = @"gray";
            id color = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMColor") alloc],
                NSSelectorFromString(@"initWithCKSymbolicColorName:hexString:"), ckName, hex);
            ((void(*)(id, SEL, id))objc_msgSend)(customCtx, NSSelectorFromString(@"setColor:"), color);
        }
    }
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);

    // ReminderKit may re-allocate the objectID we passed in; read the real
    // uuid back so the returned id matches dump output (and delete works).
    NSString *realUUID = nil;
    id smartLists = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
    for (id sl in (NSArray *)smartLists) {
        NSString *slName = [sl valueForKey:@"name"];
        NSString *slDisplay = [[sl valueForKey:@"customContext"] valueForKey:@"name"];
        BOOL nameHit = ([slName isKindOfClass:[NSString class]] && [slName isEqualToString:name]);
        BOOL displayHit = (displayName.length > 0 && [slDisplay isKindOfClass:[NSString class]]
                           && [slDisplay isEqualToString:displayName]);
        if (nameHit || displayHit) {
            realUUID = extractUUID([sl valueForKey:@"objectID"]);
            break;
        }
    }
    return @{@"ok": @YES, @"id": realUUID ?: [slUUID UUIDString], @"name": name, @"type": @"smartList"};
}

/// Move a list into/out of a group (folder) and optionally set its display
/// order. req: {op:moveList, listID?/listName, groupID?/groupName?,
/// outOfGroup?, order?, author}. Omit group without outOfGroup = keep current
/// parent, just update order.
static NSDictionary *opMoveList(id store, NSDictionary *req) {
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], req[@"listName"], &listErr);
    if (!list) return listErr;
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);

    NSString *groupID = req[@"groupID"];
    NSString *groupName = req[@"groupName"];
    NSNumber *order = req[@"order"];
    NSString *targetGroupID = nil;
    if (groupID.length > 0 || groupName.length > 0) {
        NSDictionary *gerr = nil;
        id group = resolveGroup(store, groupID, groupName, &gerr);
        if (!group) return gerr;
        targetGroupID = extractUUID([group valueForKey:@"objectID"]);
        ((void(*)(id, SEL, id))objc_msgSend)(listCI, NSSelectorFromString(@"setParentSubContainerID:"),
            [group valueForKey:@"objectID"]);
    } else if ([req[@"outOfGroup"] boolValue]) {
        ((void(*)(id, SEL, id))objc_msgSend)(listCI, NSSelectorFromString(@"setParentSubContainerID:"), nil);
    }
    if (order) {
        ((void(*)(id, SEL, NSInteger))objc_msgSend)(listCI, NSSelectorFromString(@"setDaDisplayOrder:"), order.integerValue);
    }
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES, @"id": extractUUID([list valueForKey:@"objectID"]) ?: @"",
        @"name": [list valueForKey:@"name"] ?: @""
    }];
    out[@"groupID"] = targetGroupID ?: [NSNull null];
    if (order) out[@"order"] = order;
    return out;
}

NSDictionary *executeWriteRequest(id store, NSDictionary *req) {
    NSString *op = req[@"op"];
    @try {
        if ([op isEqualToString:@"add"]) return opAdd(store, req);
        if ([op isEqualToString:@"complete"]) return opComplete(store, req);
        if ([op isEqualToString:@"delete"]) return opDelete(store, req);
        if ([op isEqualToString:@"move"]) return opMove(store, req);
        if ([op isEqualToString:@"update"]) return opUpdate(store, req);
        if ([op isEqualToString:@"deleted"]) return opDeleted(store, req);
        if ([op isEqualToString:@"restore"]) return opRestore(store, req);
        if ([op isEqualToString:@"deleteList"]) return opDeleteList(store, req);
        if ([op isEqualToString:@"updateList"]) return opUpdateList(store, req);
        if ([op isEqualToString:@"createGroup"]) return opCreateGroup(store, req);
        if ([op isEqualToString:@"createList"]) return opCreateList(store, req);
        if ([op isEqualToString:@"addSection"]) return opAddSection(store, req);
        if ([op isEqualToString:@"createSmartList"]) return opCreateSmartList(store, req);
        if ([op isEqualToString:@"moveList"]) return opMoveList(store, req);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"未知操作：%@", op]};
    } @catch (NSException *e) {
        return @{@"ok": @NO, @"error": e.reason ?: @"write exception"};
    }
}
