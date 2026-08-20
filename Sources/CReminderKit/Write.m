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
            [matches addObject:list];  // non-ARC: array retains; no extra retain → no leak
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
            [matches addObject:list];  // non-ARC: array retains; no extra retain → no leak
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

/// Resolve a custom smart list by full UUID / ≥8-char prefix / exact name
/// (case-insensitive), same precedence as resolveList. Returns the REMSmartList
/// object or nil with an error dict. Does NOT match regular lists — callers
/// pick the target family explicitly (list vs smartList).
static id resolveSmartList(id store, NSString *listID, NSString *name, NSDictionary **error) {
    NSError *err = nil;
    id smartLists = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
    if (![smartLists isKindOfClass:[NSArray class]]) {
        *error = @{@"ok": @NO, @"error": @"获取智能列表失败"};
        return nil;
    }
    NSString *target = listID.length > 0 ? listID : name;
    NSMutableArray *matches = [NSMutableArray array];
    for (id sl in (NSArray *)smartLists) {
        NSString *u = extractUUID([sl valueForKey:@"objectID"]);
        BOOL hit = NO;
        if (listID.length > 0) {
            hit = (u && ([u isEqualToString:listID] ||
                         (listID.length >= 8 && [u.lowercaseString hasPrefix:listID.lowercaseString])));
        } else {
            NSString *n = [sl valueForKey:@"name"];
            hit = ([n isKindOfClass:[NSString class]] && [n caseInsensitiveCompare:name] == NSOrderedSame);
            if (!hit && u && target.length > 0) {
                hit = ([u isEqualToString:target] ||
                       (target.length >= 8 && [u.lowercaseString hasPrefix:target.lowercaseString]));
            }
        }
        if (hit) [matches addObject:sl];
    }
    if (matches.count == 0) {
        *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到智能列表：%@", target]};
        return nil;
    }
    if (matches.count > 1) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id sl in matches) {
            NSString *u = extractUUID([sl valueForKey:@"objectID"]) ?: @"";
            NSString *n = [[sl valueForKey:@"name"] isKindOfClass:[NSString class]] ? [sl valueForKey:@"name"] : @"";
            [parts addObject:[NSString stringWithFormat:@"%@[%@]", n, u]];
        }
        *error = @{@"ok": @NO, @"error": [NSString stringWithFormat:
            @"智能列表名「%@」匹配到 %lu 个（名称重复），请用 --id <完整UUID> 精确定位：%@",
            target, (unsigned long)matches.count, [parts componentsJoinedByString:@", "]]};
        return nil;
    }
    return matches[0];
}

/// Smart-list analogue of findSectionInList: resolve a smart list's section by
/// display name via REMStore fetchSmartListSectionsForSmartListSectionContext:.
/// Returns the REMSmartListSection object or nil.
static id findSectionInSmartList(id store, id smartList, NSString *sectionName) {
    NSError *err = nil;
    id secCtx = [smartList valueForKey:@"sectionContext"];
    if (!secCtx) return nil;
    id secs = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchSmartListSectionsForSmartListSectionContext:error:"), secCtx, &err);
    if (![secs respondsToSelector:@selector(count)]) return nil;
    NSInteger count = ((NSInteger(*)(id, SEL))objc_msgSend)(secs, @selector(count));
    for (NSInteger i = 0; i < count; i++) {
        id secObj = ((id(*)(id, SEL, NSInteger))objc_msgSend)(secs, @selector(objectAtIndex:), i);
        // Smart-list sections expose displayName via KVC directly (verified on
        // macOS 26 ReminderKit); fall back to the parseSectionNames hack.
        NSString *dn = nil;
        @try { dn = [secObj valueForKey:@"displayName"]; } @catch (NSException *e) {}
        BOOL nameHit = ([dn isKindOfClass:[NSString class]] && [dn isEqualToString:sectionName]);
        if (!nameHit) {
            NSArray *names = parseSectionNames(secObj);
            nameHit = (names.count > 0 && [names[0] isEqualToString:sectionName]);
        }
        if (nameHit) return secObj;
    }
    return nil;
}

/// Attach a reminder change item to an existing section of a smart list via a
/// REMMembership(member=reminder, group=smartListSection) on the smart list's
/// section context change item. Returns nil on success or an error dict.
static NSDictionary *setReminderSmartListSection(id store, id saveReq, id smartList,
                                                  id remCI, NSString *sectionName) {
    if (!smartList) return @{@"ok": @NO, @"error": @"无法确定智能列表"};
    id section = findSectionInSmartList(store, smartList, sectionName);
    if (!section) {
        return @{@"ok": @NO, @"code": @"noSuchSection", @"error": [NSString stringWithFormat:
            @"智能列表「%@」中没有分区「%@」（先用 add-section 创建）",
            [smartList valueForKey:@"name"] ?: @"", sectionName]};
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
    id slCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateSmartList:"), smartList);
    id sectionCtx = [slCI valueForKey:@"sectionsContextChangeItem"];
    if (!sectionCtx) return @{@"ok": @NO, @"error": @"智能列表不支持分区"};
    ((void(*)(id, SEL, id))objc_msgSend)(sectionCtx,
        NSSelectorFromString(@"setUnsavedMembershipsOfRemindersInSections:"), memberships);
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
            // non-ARC: retain + autorelease so the caller (within the same
            // autorelease pool — the whole subprocess run) owns a live ref
            // without leaking.
            found = [[r retain] autorelease];
            break;
        }
    }
    return found;
}

static NSString *listNameOfReminder(id reminder) {
    id list = [reminder valueForKey:@"list"];
    return [list valueForKey:@"name"];
}

/// Fetch every reminder (incl. subtasks) across all lists, flat. Used by
/// reorder to map ordering objectIDs back to reminder objects.
static NSArray *fetchAllReminderObjects(id store) {
    NSMutableArray *listIDs = [NSMutableArray array];
    void (^lb)(id, BOOL *) = ^(id list, BOOL *sp) {
        id oid = [list valueForKey:@"objectID"];
        if (oid) [listIDs addObject:oid];
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"enumerateAllListsWithBlock:"), lb);
    NSError *err = nil;
    NSArray *reminders = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchRemindersForEventKitBridgingWithListIDs:error:"), listIDs, &err);
    return [reminders isKindOfClass:[NSArray class]] ? reminders : @[];
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

static NSDateComponents *epochToComponents(NSNumber *epoch, BOOL isAllDay) {
    if (!epoch) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch.doubleValue];
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = NSTimeZone.localTimeZone;
    // All-day reminders carry only year/month/day (no hour/minute) — that's
    // how ReminderKit derives the allDay flag from dueDateComponents.
    NSCalendarUnit units = isAllDay
        ? (NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
        : (NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
           NSCalendarUnitHour | NSCalendarUnitMinute);
    return [cal components:units fromDate:date];
}

/// Whether a request should set an all-day due/start date: explicit allDay
/// flag wins; otherwise a pure YYYY-MM-DD string (no "HH:MM" time part)
/// means all-day, matching the CLI's documented --due semantics.
static BOOL requestIsAllDay(NSDictionary *req, NSString *key) {
    if (req[@"allDay"] != nil) return [req[@"allDay"] boolValue];
    id raw = req[key];
    return [raw isKindOfClass:[NSString class]] && [(NSString *)raw rangeOfString:@":"].location == NSNotFound;
}

// MARK: - Operations

static NSDictionary *applyEditableFields(id store, id reminder, id remCI, NSDictionary *req, NSMutableDictionary *changes);
static BOOL reminderHasChildren(id store, id reminder);

static NSDictionary *opAdd(id store, NSDictionary *req) {
    NSString *listName = req[@"listName"];
    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], listName, &listErr);
    if (!list) return listErr;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
    id remCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"addReminderWithTitle:toListChangeItem:"), req[@"title"] ?: @"", listCI);

    NSDateComponents *due = epochToComponents(req[@"due"], [req[@"allDay"] boolValue]);
    if (due) {
        [remCI setValue:due forKey:@"dueDateComponents"];
        // allDay is a stored flag on the change item; keep it in sync so an
        // all-day request stays all-day (hour/minute stripped above and the
        // flag set explicitly).
        [remCI setValue:@([req[@"allDay"] boolValue]) forKey:@"allDay"];
    }
    NSDateComponents *start = epochToComponents(req[@"start"], [req[@"allDay"] boolValue]);
    if (start) {
        [remCI setValue:start forKey:@"startDateComponents"];
        [remCI setValue:@([req[@"allDay"] boolValue]) forKey:@"allDay"];
    }

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
                // Alarms are absolute instants — never all-day.
                NSDateComponents *dc = epochToComponents(al[@"date"], NO);
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
        // --smart-list <名称/UUID>: file the reminder into a section OF THE
        // SMART LIST (virtual view) instead of the physical list's section.
        // The reminder still lives in the physical list (list above).
        NSString *slName = req[@"smartListName"];
        NSString *slID = req[@"smartListID"];
        if (slName.length > 0 || slID.length > 0) {
            NSDictionary *slErr = nil;
            id smartList = resolveSmartList(store, slID, slName, &slErr);
            if (!smartList) return slErr;
            secErr = setReminderSmartListSection(store, saveReq, smartList, remCI, sectionName);
        } else {
            secErr = setReminderSection(store, saveReq, list, remCI, sectionName);
        }
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
    NSDictionary *fieldErr = applyEditableFields(store, reminder, remCI, req, changes);
    if (fieldErr) return fieldErr;
    NSString *sectionName = req[@"section"];
    NSDictionary *secErr = nil;
    if ([sectionName isKindOfClass:[NSString class]] && sectionName.length > 0) {
        NSString *slName = req[@"smartListName"];
        NSString *slID = req[@"smartListID"];
        if (slName.length > 0 || slID.length > 0) {
            NSDictionary *slErr = nil;
            id smartList = resolveSmartList(store, slID, slName, &slErr);
            if (!smartList) return slErr;
            secErr = setReminderSmartListSection(store, saveReq, smartList, remCI, sectionName);
        } else {
            id list = [reminder valueForKey:@"list"];
            secErr = setReminderSection(store, saveReq, list, remCI, sectionName);
        }
        if (secErr) return secErr;
        changes[@"section"] = sectionName;
    }
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"id": extId, @"changes": changes};
}

/// Whether the reminder has any subtasks (parentReminderID == its objectID).
/// Requires a full fetch (enumerateAllRemindersWithBlock: silently drops subtasks).
static BOOL reminderHasChildren(id store, id reminder) {
    NSMutableArray *listIDs = [NSMutableArray array];
    void (^lb)(id, BOOL *) = ^(id list, BOOL *sp) {
        id oid = [list valueForKey:@"objectID"];
        if (oid) [listIDs addObject:oid];
    };
    ((void(*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"enumerateAllListsWithBlock:"), lb);
    NSError *err = nil;
    NSArray *all = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchRemindersForEventKitBridgingWithListIDs:error:"), listIDs, &err);
    if (![all isKindOfClass:[NSArray class]]) return NO;
    NSString *selfOID = [[reminder valueForKey:@"objectID"] description];
    for (id r in all) {
        id pid = [r valueForKey:@"parentReminderID"];
        if (pid && [[pid description] isEqualToString:selfOID]) return YES;
    }
    return NO;
}

// Apply editable fields to an existing reminder's change item. Mirrors
// opAdd's field logic; shared by opUpdate so both paths stay in sync.
// Returns nil on success, or an error dict to abort the save.
static NSDictionary *applyEditableFields(id store, id reminder, id remCI, NSDictionary *req, NSMutableDictionary *changes) {
    if ([req[@"title"] isKindOfClass:[NSString class]]) {
        [remCI setValue:req[@"title"] forKey:@"titleAsString"];
        changes[@"title"] = req[@"title"];
    }
    if ([req[@"notes"] isKindOfClass:[NSString class]]) {
        [remCI setValue:req[@"notes"] forKey:@"notesAsString"];
        changes[@"notes"] = req[@"notes"];
    }
    NSDateComponents *due = epochToComponents(req[@"due"], [req[@"allDay"] boolValue]);
    if (due) {
        [remCI setValue:due forKey:@"dueDateComponents"];
        [remCI setValue:@([req[@"allDay"] boolValue]) forKey:@"allDay"];
        changes[@"due"] = req[@"due"];
        changes[@"allDay"] = @([req[@"allDay"] boolValue]);
    }
    NSDateComponents *start = epochToComponents(req[@"start"], [req[@"allDay"] boolValue]);
    if (start) {
        [remCI setValue:start forKey:@"startDateComponents"];
        [remCI setValue:@([req[@"allDay"] boolValue]) forKey:@"allDay"];
        changes[@"start"] = req[@"start"];
    }
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
    if ([tags isKindOfClass:[NSArray class]]) {
        id list = [reminder valueForKey:@"list"];
        id acctObjID = ((id(*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"accountID"));
        id remObjID = ((id(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"objectID"));
        NSMutableSet *hts = [NSMutableSet set];
        for (id t in tags) {
            if ([t isKindOfClass:[NSString class]] && [t length] > 0) {
                [hts addObject:makeHashtag(acctObjID, remObjID, t)];
            }
        }
        // 替换语义：空数组 = 清空全部标签（bulk --tag-remove 移除最后一个标签时）
        [remCI setValue:hts forKey:@"hashtags"];
        changes[@"tags"] = tags;
    }
    if ([req[@"clearRecurrence"] boolValue]) {
        ((void(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"removeAllRecurrenceRules"));
        changes[@"recurrence"] = @NO;
    }
    NSDictionary *recur = req[@"recurrence"];
    if ([recur isKindOfClass:[NSDictionary class]]) {
        // update semantics are replacement, not append. Clearing first also
        // repairs reminders that already accumulated duplicate rules.
        ((void(*)(id, SEL))objc_msgSend)(remCI, NSSelectorFromString(@"removeAllRecurrenceRules"));
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
        NSMutableArray *replaced = [NSMutableArray arrayWithCapacity:existing.count + 1];
        for (id existingAttachment in existing) {
            if (![NSStringFromClass([existingAttachment class]) isEqualToString:@"REMURLAttachment"]) {
                [replaced addObject:existingAttachment];
            }
        }
        [replaced addObject:att];
        [remCI setValue:replaced forKey:@"attachments"];
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
                // Alarms are absolute instants — never all-day.
                NSDateComponents *dc = epochToComponents(al[@"date"], NO);
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

    // --parent: attach this reminder as a subtask of another reminder.
    // --no-parent: detach (make it a top-level task again).
    NSString *parentId = req[@"parentId"];
    if ([parentId isKindOfClass:[NSString class]] && parentId.length > 0) {
        id parent = findReminderByExtId(store, parentId);
        if (!parent) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到父提醒：%@", parentId]};
        NSString *selfExt = extractUUID([reminder valueForKey:@"objectID"]);
        NSString *parentExt = extractUUID([parent valueForKey:@"objectID"]);
        if (selfExt && parentExt && [selfExt isEqualToString:parentExt]) {
            return @{@"ok": @NO, @"error": @"不能把提醒挂到自己下面"};
        }
        if ([parent valueForKey:@"parentReminderID"] != nil) {
            return @{@"ok": @NO, @"error": @"父提醒本身是子任务——苹果不支持嵌套子任务，无法再挂"};
        }
        // ReminderKit enforces that a subtask shares its parent's list (-3002).
        id selfList = [reminder valueForKey:@"list"];
        id parentList = [parent valueForKey:@"list"];
        if (selfList && parentList) {
            NSString *selfListID = extractUUID([selfList valueForKey:@"objectID"]);
            NSString *parentListID = extractUUID([parentList valueForKey:@"objectID"]);
            if (selfListID && parentListID && ![selfListID isEqualToString:parentListID]) {
                return @{@"ok": @NO, @"error": @"父提醒在不同列表——请先 move 到同一列表再挂（ReminderKit 强制子任务与父同列表）"};
            }
        }
        // Apple supports only one level of parent→child; attaching a reminder
        // that already has children would create a 3-level chain — reject.
        if (reminderHasChildren(store, reminder)) {
            return @{@"ok": @NO, @"error": @"该提醒已有子任务——苹果不支持嵌套子任务（父→子→孙），无法再挂到父任务下"};
        }
        [remCI setValue:[parent valueForKey:@"objectID"] forKey:@"parentReminderID"];
        changes[@"parentId"] = parentExt ?: parentId;
    }
    if ([req[@"noParent"] boolValue]) {
        if ([reminder valueForKey:@"parentReminderID"] == nil) {
            return @{@"ok": @NO, @"error": @"该提醒不是子任务，无需解除"};
        }
        [remCI setValue:nil forKey:@"parentReminderID"];
        changes[@"parentId"] = [NSNull null];
    }
    return nil;
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
    // --section: file the moved reminder into a section of the TARGET list in
    // the same save request (REMMembership on the sections context change item,
    // same mechanism as add/update). Reuses setReminderSection, which validates
    // the section exists and guides "先用 add-section 创建" on miss.
    NSString *sectionName = req[@"section"];
    if (sectionName.length > 0) {
        NSString *rootKey = [[reminder valueForKey:@"objectID"] description];
        id rootCI = parentCIByID[rootKey];
        NSDictionary *secErr = setReminderSection(store, saveReq, toList, rootCI, sectionName);
        if (secErr) return secErr;
    }
    NSError *err = nil;
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    // True move keeps the identifier — no copy, no deletion, no recently-deleted entry.
    NSString *resolvedToName = [toList valueForKey:@"name"];
    NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES, @"id": extId, @"toList": resolvedToName ?: toName ?: @""
    }];
    if (sectionName.length > 0) resp[@"section"] = sectionName;  // 回显落点，agent 零验证成本
    return resp;
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

/// Collect matching regular lists, custom smart lists, and groups using one
/// resolution rule. An explicit --id only matches IDs; otherwise the
/// positional value may be a case-insensitive exact name, full UUID, or an
/// unambiguous UUID prefix of at least eight characters.
static NSArray *collectListFamilyCandidates(id store, NSString *listID,
                                             NSString *name, NSString *typeFilter) {
    NSMutableArray *candidates = [NSMutableArray array];  // {obj, type}
    NSString *target = listID.length > 0 ? listID : name;

    BOOL (^matches)(id) = ^BOOL(id obj) {
        NSString *uuid = extractUUID([obj valueForKey:@"objectID"]);
        if (listID.length > 0) {
            return uuid && ([uuid isEqualToString:listID] ||
                (listID.length >= 8 && [uuid.lowercaseString hasPrefix:listID.lowercaseString]));
        }
        NSString *objectName = [obj valueForKey:@"name"];
        BOOL nameMatch = [objectName isKindOfClass:[NSString class]] &&
            [objectName caseInsensitiveCompare:name] == NSOrderedSame;
        BOOL idMatch = uuid && target.length > 0 &&
            ([uuid isEqualToString:target] ||
             (target.length >= 8 && [uuid.lowercaseString hasPrefix:target.lowercaseString]));
        return nameMatch || idMatch;
    };

    if (typeFilter.length == 0 || [typeFilter.lowercaseString isEqualToString:@"list"]) {
        NSMutableArray *matchesForBlock = [NSMutableArray array];
        void (^listBlock)(id, BOOL *) = ^(id list, BOOL *stop) {
            if (matches(list)) [matchesForBlock addObject:list];
        };
        ((void(*)(id, SEL, id))objc_msgSend)(store,
            NSSelectorFromString(@"enumerateAllListsWithBlock:"), listBlock);
        for (id list in matchesForBlock) {
            [candidates addObject:@{@"obj": list, @"type": @"list"}];
        }
    }

    if (typeFilter.length == 0 || [typeFilter.lowercaseString isEqualToString:@"smartlist"]) {
        NSError *smartListError = nil;
        id smartLists = ((id(*)(id, SEL, id*))objc_msgSend)(store,
            NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &smartListError);
        if ([smartLists isKindOfClass:[NSArray class]]) {
            for (id smartList in (NSArray *)smartLists) {
                if (matches(smartList)) {
                    [candidates addObject:@{@"obj": smartList, @"type": @"smartList"}];
                }
            }
        }
    }

    if (typeFilter.length == 0 || [typeFilter.lowercaseString isEqualToString:@"group"]) {
        NSDictionary *groups = fetchAllGroups(store);
        for (NSString *uuid in groups) {
            id group = groups[uuid];
            if (matches(group)) {
                [candidates addObject:@{@"obj": group, @"type": @"group"}];
            }
        }
    }

    return candidates;
}

static NSDictionary *listFamilyResolutionError(NSArray *candidates, NSString *target,
                                                 NSString *typeFilter) {
    if (candidates.count == 0) {
        if ([typeFilter.lowercaseString isEqualToString:@"group"]) {
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到分组：%@", target ?: @""]};
        }
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到列表：%@", target ?: @""]};
    }
    if (candidates.count == 1) return nil;

    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
        id obj = candidate[@"obj"];
        NSString *uuid = extractUUID([obj valueForKey:@"objectID"]) ?: @"";
        NSString *name = [[obj valueForKey:@"name"] isKindOfClass:[NSString class]]
            ? [obj valueForKey:@"name"] : @"";
        [parts addObject:[NSString stringWithFormat:@"%@: %@[%@]", candidate[@"type"], name, uuid]];
    }
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:
        @"名称「%@」匹配到 %lu 个（跨列表/智能列表/分组），请用 --id <完整UUID> 精确定位：%@",
        target ?: @"", (unsigned long)candidates.count, [parts componentsJoinedByString:@", "]]};
}

/// Delete a list (regular list, custom smart list, or group).
static NSDictionary *opDeleteList(id store, NSDictionary *req) {
    NSString *name = req[@"listName"];
    NSString *listID = req[@"listID"];
    NSString *target = listID.length > 0 ? listID : name;
    NSArray *candidates = collectListFamilyCandidates(store, listID, name, nil);
    NSDictionary *resolutionError = listFamilyResolutionError(candidates, target, nil);
    if (resolutionError) return resolutionError;

    NSDictionary *candidate = candidates[0];
    id obj = candidate[@"obj"];
    NSString *type = candidate[@"type"];
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);

    if ([type isEqualToString:@"list"] || [type isEqualToString:@"group"]) {
        id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"updateList:"), obj);
        ((void(*)(id, SEL))objc_msgSend)(listCI, NSSelectorFromString(@"removeFromParent"));
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        return @{@"ok": @YES, @"listName": name ?: @"", @"type": type, @"deleted": @YES};
    }

    id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchAccountsWithError:"), &err);
    id account = [accounts isKindOfClass:[NSArray class]] && [accounts count] > 0 ? accounts[0] : nil;
    if (!account) return @{@"ok": @NO, @"error": @"找不到账户"};
    id accountCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"updateAccount:"), account);
    id smartListCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq,
        NSSelectorFromString(@"updateSmartList:"), obj);
    ((void(*)(id, SEL, id))objc_msgSend)(smartListCI,
        NSSelectorFromString(@"removeFromParentWithAccountChangeItem:"), accountCI);
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"listName": name ?: @"", @"type": @"smartList", @"deleted": @YES};
}

/// Update a list's name / icon / color, or a group / smart list's name.
/// Unified resolution (feature pool #15, 2026-08-15): candidates are collected
/// across lists, custom smart lists, and groups with one ladder
/// (full UUID → ≥8-char prefix → case-insensitive exact title); a unique hit
/// dispatches by type, multiple hits error with type-tagged candidates, and
/// `--type` narrows the search for script callers. Groups/smart lists are
/// name-only (no icon/color).
static NSDictionary *opUpdateList(id store, NSDictionary *req) {
    NSString *name = req[@"listName"];
    NSString *listID = req[@"listID"];
    NSString *typeFilter = req[@"type"];

    NSString *target = listID.length > 0 ? listID : name;
    NSArray *candidates = collectListFamilyCandidates(store, listID, name, typeFilter);
    NSDictionary *resolutionError = listFamilyResolutionError(candidates, target, typeFilter);
    if (resolutionError) return resolutionError;

    NSDictionary *candidate = candidates[0];
    id obj = candidate[@"obj"];
    NSString *type = candidate[@"type"];
    NSString *newName = req[@"newName"];
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);

    if ([type isEqualToString:@"list"]) {
        id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), obj);
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
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        return @{@"ok": @YES, @"listName": newName ?: (name ?: @""), @"type": @"list", @"updated": @YES};
    }

    // Group / smart list: name-only updates (groups) / name+icon+color (smart lists).
    NSString *icon = req[@"icon"];
    NSString *hex = req[@"color"];
    if ([type isEqualToString:@"group"] &&
        (([icon isKindOfClass:[NSString class]] && icon.length > 0) ||
         ([hex isKindOfClass:[NSString class]] && hex.length > 0))) {
        return @{@"ok": @NO, @"error": @"分组不支持 --icon/--color，仅支持 --new-name 改名"};
    }
    if (![newName isKindOfClass:[NSString class]] || newName.length == 0) {
        if (!([icon isKindOfClass:[NSString class]] && icon.length > 0) &&
            !([hex isKindOfClass:[NSString class]] && hex.length > 0)) {
            NSString *label = [type isEqualToString:@"group"] ? @"分组" : @"智能列表";
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@更新需要至少一个字段：--new-name / --icon / --color", label]};
        }
    }

    if ([type isEqualToString:@"group"]) {
        // Group = REMList isGroup variant; same KVC `name` path as lists
        // (verified by smoke test — assertion checks dump reflects the rename).
        id gci = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), obj);
        @try {
            [gci setValue:newName forKey:@"name"];
        } @catch (NSException *e) {
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"分组改名失败（ReminderKit 不支持该 KVC）：%@", e.name]};
        }
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        return @{@"ok": @YES, @"groupName": newName, @"type": @"group", @"updated": @YES};
    }

    // Smart list: rename via the display-name path used at creation
    // (customContext setName:) plus the change item's `name` KVC (guarded).
    // icon/color: badgeEmblem JSON string + customContext setColor: (same
    // shapes as creation; verified 2026-08-16 save OK + readback).
    id slCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateSmartList:"), obj);
    if ([newName isKindOfClass:[NSString class]] && newName.length > 0) {
        @try {
            [slCI setValue:newName forKey:@"name"];
        } @catch (NSException *e) {}
    }
    id customCtx = [slCI valueForKey:@"customContext"];
    if (customCtx) {
        if ([newName isKindOfClass:[NSString class]] && newName.length > 0) {
            ((void(*)(id, SEL, id))objc_msgSend)(customCtx, NSSelectorFromString(@"setName:"), newName);
        }
        if ([icon isKindOfClass:[NSString class]] && icon.length > 0) {
            NSString *badge = [NSString stringWithFormat:@"{\"Emoji\":\"%@\"}", icon];
            @try {
                [slCI setValue:badge forKey:@"badgeEmblem"];
            } @catch (NSException *e) {}
        }
        if ([hex isKindOfClass:[NSString class]] && hex.length > 0) {
            NSString *ckName = [req[@"colorName"] isKindOfClass:[NSString class]] ? req[@"colorName"] : @"gray";
            id color = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMColor") alloc],
                NSSelectorFromString(@"initWithCKSymbolicColorName:hexString:"), ckName, hex);
            ((void(*)(id, SEL, id))objc_msgSend)(customCtx, NSSelectorFromString(@"setColor:"), color);
        }
    }
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"name": newName ?: @"", @"type": @"smartList", @"updated": @YES};
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
        return @{@"ok": @NO, @"code": @"noSuchSection", @"error": [NSString stringWithFormat:
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
/// Set smartList=true to target a custom smart list (uses the smart-list
/// section path: updateSmartList: → sectionsContextChangeItem →
/// addSmartListSectionWithDisplayName:).
static NSDictionary *opAddSection(id store, NSDictionary *req) {
    NSString *name = req[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return @{@"ok": @NO, @"error": @"分区名不能为空"};
    }
    BOOL smart = [req[@"smartList"] boolValue];
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);

    if (smart) {
        NSDictionary *slErr = nil;
        id smartList = resolveSmartList(store, req[@"listID"], req[@"listName"], &slErr);
        if (!smartList) return slErr;
        id slCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateSmartList:"), smartList);
        id sectionCtx = [slCI valueForKey:@"sectionsContextChangeItem"];
        if (!sectionCtx) return @{@"ok": @NO, @"error": @"智能列表不支持分区"};
        id sectionCI = ((id(*)(id, SEL, id, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"addSmartListSectionWithDisplayName:toSmartListSectionContextChangeItem:"),
            name, sectionCtx);
        if (!sectionCI) return @{@"ok": @NO, @"error": @"创建分区失败"};
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        return @{@"ok": @YES, @"id": extractUUID([sectionCI valueForKey:@"objectID"]) ?: @"",
                 @"name": name, @"smartListID": extractUUID([smartList valueForKey:@"objectID"]) ?: @""};
    }

    NSDictionary *listErr = nil;
    id list = resolveList(store, req[@"listID"], req[@"listName"], &listErr);
    if (!list) return listErr;
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

/// Delete a section from a list. req: {op:deleteSection, listID?/listName,
/// name, author}. Deleting a section removes the grouping itself; any
/// reminders filed in it are moved to the list's un-sectioned area.
static NSDictionary *opDeleteSection(id store, NSDictionary *req) {
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

    // 拿现有分区（change item 上下文），按显示名匹配
    id secs = ((id(*)(id, SEL, id, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchListSectionsForListSectionContextChangeItem:error:"), sectionCtx, &err);
    if (![secs respondsToSelector:@selector(count)]) return @{@"ok": @NO, @"error": @"获取分区失败"};
    NSInteger count = ((NSInteger(*)(id, SEL))objc_msgSend)(secs, @selector(count));
    id section = nil;
    for (NSInteger i = 0; i < count; i++) {
        id secObj = ((id(*)(id, SEL, NSInteger))objc_msgSend)(secs, @selector(objectAtIndex:), i);
        NSArray *names = parseSectionNames(secObj);
        if (names.count > 0 && [names[0] isEqualToString:name]) { section = secObj; break; }
    }
    if (!section) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到分区：%@", name]};

    id oid = [section valueForKey:@"objectID"];
    // 用 REMSaveRequest.updateListSection: 拿被正确跟踪的 change item（手动
    // initWithObjectID:displayName:insertIntoListChangeItem: 构造的 item 是
    // “新插入”语义，removeFromList 只会撤销插入，分区不会真删）。
    id sectionCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateListSection:"), section);
    if (!sectionCI) return @{@"ok": @NO, @"error": @"创建分区 change item 失败"};
    ((void(*)(id, SEL))objc_msgSend)(sectionCI, NSSelectorFromString(@"removeFromList"));

    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    return @{@"ok": @YES, @"name": name,
             @"listID": extractUUID([list valueForKey:@"objectID"]) ?: @""};
}

/// Create a custom smart list. req: {op:createSmartList, name, color?,
/// displayName?, filterData?, groupID?/groupName?, author}. When a group is
/// given, the smart list is created inside that group (folder) via
/// addCustomSmartListWithName:toListSublistContextChangeItem:smartListObjectID:
/// (verified 2026-08-16: readback parentList == group); otherwise top-level.
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

    id smartListsBefore = ((id(*)(id, SEL, id*))objc_msgSend)(store,
        NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
    if (![smartListsBefore isKindOfClass:[NSArray class]]) {
        return @{@"ok": @NO, @"error": @"创建前无法读取智能列表，已取消创建"};
    }
    NSMutableSet *existingUUIDs = [NSMutableSet set];
    for (id smartList in (NSArray *)smartListsBefore) {
        NSString *uuid = extractUUID([smartList valueForKey:@"objectID"]);
        if (uuid.length > 0) [existingUUIDs addObject:uuid];
    }

    id saveReq = makeSaveRequest(store, req[@"author"]);
    id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);
    NSUUID *slUUID = [NSUUID UUID];
    id slOID = ((id(*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"REMObjectID") alloc],
        NSSelectorFromString(@"initWithUUID:entityName:"), slUUID, @"REMCDSmartList");
    id slCI = nil;
    NSString *groupID = req[@"groupID"];
    NSString *groupName = req[@"groupName"];
    if (groupID.length > 0 || groupName.length > 0) {
        NSDictionary *gerr = nil;
        id group = resolveGroup(store, groupID, groupName, &gerr);
        if (!group) return gerr;
        id groupCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), group);
        id subCtx = [groupCI valueForKey:@"sublistContext"];
        if (!subCtx) return @{@"ok": @NO, @"error": @"分组不支持子列表"};
        slCI = ((id(*)(id, SEL, id, id, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"addCustomSmartListWithName:toListSublistContextChangeItem:smartListObjectID:"),
            name, subCtx, slOID);
    } else {
        slCI = ((id(*)(id, SEL, id, id, id))objc_msgSend)(saveReq,
            NSSelectorFromString(@"addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:"),
            name, acctCI, slOID);
    }
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
    // #19: optional filter at creation — write filterData (NSData of the JSON
    // filter) on the change item's storage. Hashtag filters come as
    // {"hashtags":{"hashtags":["标签"]}}; the App accepts the same shape.
    // Received as a JSON string (raw Data cannot cross the request boundary).
    id filterDataStr = req[@"filterData"];
    if ([filterDataStr isKindOfClass:[NSString class]] && [filterDataStr length] > 0) {
        NSData *filterData = [filterDataStr dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            [slCI setValue:filterData forKey:@"filterData"];
        } @catch (NSException *e) {
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"设置智能列表过滤条件失败：%@", e.name]};
        }
    }
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);

    // ReminderKit may re-allocate the objectID we passed in. Identify the
    // created object by the before/after UUID set difference; name lookup is
    // unsafe because Reminders allows duplicate smart-list names.
    NSString *realUUID = nil;
    NSString *changeItemUUID = extractUUID([slCI valueForKey:@"objectID"]);
    NSMutableArray *lastNewUUIDs = [NSMutableArray array];
    for (NSInteger attempt = 0; attempt < 30 && realUUID.length == 0; attempt++) {
        id smartListsAfter = ((id(*)(id, SEL, id*))objc_msgSend)(store,
            NSSelectorFromString(@"fetchCustomSmartListsWithError:"), &err);
        [lastNewUUIDs removeAllObjects];
        if ([smartListsAfter isKindOfClass:[NSArray class]]) {
            for (id smartList in (NSArray *)smartListsAfter) {
                NSString *uuid = extractUUID([smartList valueForKey:@"objectID"]);
                if (uuid.length > 0 && ![existingUUIDs containsObject:uuid]) {
                    [lastNewUUIDs addObject:uuid];
                }
            }
        }
        if (changeItemUUID.length > 0 && [lastNewUUIDs containsObject:changeItemUUID]) {
            realUUID = changeItemUUID;
        } else if (lastNewUUIDs.count == 1) {
            realUUID = lastNewUUIDs[0];
        } else if (attempt < 29) {
            [NSThread sleepForTimeInterval:0.1];
            changeItemUUID = extractUUID([slCI valueForKey:@"objectID"]);
        }
    }
    if (realUUID.length == 0) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:
            @"智能列表已创建，但 3 秒内无法确认其最终 ID；请勿重试创建，先运行 dump 检查（候选：%@）",
            [lastNewUUIDs componentsJoinedByString:@", "]]};
    }
    return @{@"ok": @YES, @"id": realUUID, @"name": name, @"type": @"smartList"};
}

/// Move a list into/out of a group (folder) and optionally set its display
/// order. req: {op:moveList, listID?/listName, groupID?/groupName?,
/// outOfGroup?, order?, author}. Omit group without outOfGroup = keep current
/// parent, just update order.
/// Move a list into/out of a group (regular lists only), and/or set its
/// position in the sidebar ordering. req: {op:moveList, listID?/listName,
/// groupID?/groupName?, outOfGroup?, order?, last?, type?, author}.
///
/// Sorting (--last / --order N) is UNIFIED across list types: both regular
/// lists and smart lists go through the account's listIDsOrdering
/// (updateAccount: → _editListIDsOrderingUsingBlock: → moveObjectFromIndex:
/// toIndex:). Regular lists previously used daDisplayOrder, but the account
/// ordering is the single source of truth for sidebar position (2026-08-16
/// decision: unify; --order N is the ordering index, --last moves to the end).
/// Group move (--to-group / --out-of-group) remains regular-lists-only —
/// smart lists get their parent from the group's sublistContext at creation.
static NSDictionary *opMoveList(id store, NSDictionary *req) {
    NSString *typeFilter = req[@"type"];
    BOOL wantSmart = (typeFilter.length > 0 &&
                      [typeFilter.lowercaseString isEqualToString:@"smartlist"]);
    BOOL wantGroup = (typeFilter.length > 0 &&
                      [typeFilter.lowercaseString isEqualToString:@"group"]);

    // Resolve the target: --type smartlist/group pins that family; otherwise
    // regular list first, then smart list, then group (folder) as fallback.
    // All three families share the account's listIDsOrdering for sorting.
    id list = nil;
    id smartList = nil;
    id group = nil;
    NSDictionary *listErr = nil;
    NSDictionary *slErr = nil;
    NSDictionary *groupErr = nil;
    if (!wantSmart && !wantGroup) {
        list = resolveList(store, req[@"listID"], req[@"listName"], &listErr);
    }
    if (!list && !wantGroup) {
        smartList = resolveSmartList(store, req[@"listID"], req[@"listName"], &slErr);
    }
    if (!list && !smartList) {
        group = resolveGroup(store, req[@"listID"], req[@"listName"], &groupErr);
    }
    if (!list && !smartList && !group) {
        if (wantSmart) return slErr;
        if (wantGroup) return groupErr;
        return listErr;
    }

    NSNumber *order = req[@"order"];
    if (order == nil) {
        // No sorting requested → must be a group move, which needs a regular list.
        if (group) {
            return @{@"ok": @NO, @"error": @"分组不支持进出分组（文件夹是容器顶层）；排序请用 --order N"};
        }
        if (!list) {
            return @{@"ok": @NO, @"error": @"智能列表不支持进出分组（父分组由创建时指定）；排序请用 --order N"};
        }
    }

    // Unified ordering path (regular + smart lists + groups): reorder within
    // the account's listIDsOrdering. The target position is an index into that
    // global ordering (0-based). 末尾 = dump 的 listIDsOrdering 长度 - 1。
    if (order != nil) {
        id target = list ?: (smartList ?: group);
        NSString *targetUUID = extractUUID([target valueForKey:@"objectID"]);
        NSError *err = nil;
        id accounts = ((id(*)(id, SEL, id*))objc_msgSend)(store, NSSelectorFromString(@"fetchAccountsWithError:"), &err);
        id acct = [accounts isKindOfClass:[NSArray class]] ? accounts[0] : nil;
        if (!acct) return @{@"ok": @NO, @"error": @"找不到账户"};
        id saveReq = makeSaveRequest(store, req[@"author"]);
        id acctCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateAccount:"), acct);
        __block BOOL moved = NO;
        @try {
            ((void(*)(id, SEL, id))objc_msgSend)(acctCI, NSSelectorFromString(@"_editListIDsOrderingUsingBlock:"), ^(id ordering) {
                id imm = [ordering performSelector:NSSelectorFromString(@"immutableOrderedSet")];
                id oset = [imm performSelector:NSSelectorFromString(@"orderedSet")];
                NSInteger cnt = [oset count];
                NSInteger idx = NSNotFound;
                for (NSInteger i = 0; i < cnt; i++) {
                    if ([[[oset objectAtIndex:i] description] isEqualToString:targetUUID]) { idx = i; break; }
                }
                NSInteger target = order.integerValue;
                if (target < 0) target = 0;
                if (target >= cnt) target = cnt - 1;
                if (idx != NSNotFound && idx != target) {
                    ((void(*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(ordering,
                        NSSelectorFromString(@"moveObjectFromIndex:toIndex:"), idx, target);
                    moved = YES;
                }
            });
        } @catch (NSException *e) {}
        if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
            @"ok": @YES, @"id": targetUUID,
            @"name": [target valueForKey:@"name"] ?: @"",
            @"type": list ? @"list" : (smartList ? @"smartList" : @"group")
        }];
        if (order) out[@"order"] = order;
        if (moved) out[@"moved"] = @YES;
        return out;
    }

    // Group move (regular lists only).
    if (!list) return listErr;
    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);

    NSString *groupID = req[@"groupID"];
    NSString *groupName = req[@"groupName"];
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
    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES, @"id": extractUUID([list valueForKey:@"objectID"]) ?: @"",
        @"name": [list valueForKey:@"name"] ?: @""
    }];
    out[@"groupID"] = targetGroupID ?: [NSNull null];
    return out;
}

/// Reorder a reminder within its list. req: {op:reorder, id, before?/after?,
/// first?, last?, author}. before/after 引用同列表的相邻提醒（by extId）；
/// first/last 移到列表顶/底。底层 insertReminderChangeItem:before/after:
/// （探索已验证：无分区/分区内/非 manual sortingStyle 均持久化；新列表默认
/// sortingStyle=manual）。子任务 v1 拒绝（子任务顺序由父任务 subtaskContext
/// 管理，不在列表 reminderIDsOrdering 里）。目标与锚点相同 → no-op 成功。
static NSDictionary *opReorder(id store, NSDictionary *req) {
    NSString *extId = req[@"id"];
    id reminder = findReminderByExtId(store, extId);
    if (!reminder) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到提醒：%@", extId]};
    if ([reminder valueForKey:@"parentReminderID"] != nil) {
        return @{@"ok": @NO, @"error": @"子任务不支持排序（顺序由父任务管理）：请对父任务排序"};
    }
    NSString *before = req[@"before"];
    NSString *after = req[@"after"];
    BOOL first = [req[@"first"] boolValue];
    BOOL last = [req[@"last"] boolValue];
    int mode = (before.length > 0) + (after.length > 0) + first + last;
    if (mode != 1) {
        return @{@"ok": @NO, @"error": @"reorder 需要且仅需一个定位参数：--before <sibling> / --after <sibling> / --first / --last"};
    }

    id list = [reminder valueForKey:@"list"];
    NSString *listName = [list valueForKey:@"name"] ?: @"";

    // 锚点（sibling）解析：显式 --before/--after 按 extId 找；first/last 用
    // 列表 reminderIDsOrdering 的第一个/最后一个顶层任务。
    id sibling = nil;
    NSString *relation = nil; // "before" | "after"
    if (before.length > 0 || after.length > 0) {
        NSString *sibExtId = before.length > 0 ? before : after;
        relation = before.length > 0 ? @"before" : @"after";
        sibling = findReminderByExtId(store, sibExtId);
        if (!sibling) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"找不到相邻提醒：%@", sibExtId]};
        id sibList = [sibling valueForKey:@"list"];
        NSString *targetListUUID = extractUUID([list valueForKey:@"objectID"]);
        NSString *sibListUUID = extractUUID([sibList valueForKey:@"objectID"]);
        if (![targetListUUID isEqualToString:sibListUUID]) {
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:
                @"排序目标与相邻提醒不在同一列表：相邻提醒在「%@」",
                [sibList valueForKey:@"name"] ?: @"未知列表"]};
        }
    } else {
        id ordering = [list valueForKey:@"reminderIDsOrdering"];
        if (![ordering respondsToSelector:@selector(firstObject)]) {
            return @{@"ok": @NO, @"error": @"无法读取列表排序"};
        }
        id anchorOID = first
            ? ((id(*)(id, SEL))objc_msgSend)(ordering, @selector(firstObject))
            : ((id(*)(id, SEL))objc_msgSend)(ordering, @selector(lastObject));
        relation = first ? @"before" : @"after";
        if (!anchorOID) {
            return @{@"ok": @NO, @"error": @"列表为空，无法定位排序位置"};
        }
        NSString *anchorUUID = extractUUID(anchorOID);
        for (id r in fetchAllReminderObjects(store)) {
            if ([extractUUID([r valueForKey:@"objectID"]) isEqualToString:anchorUUID]) {
                sibling = r;
                break;
            }
        }
        if (!sibling) return @{@"ok": @NO, @"error": @"无法解析列表排序锚点（列表数据异常）"};
    }

    // 目标与锚点相同（单任务列表 --first/--last、或显式 --before 自己）→ no-op
    NSString *targetUUID = extractUUID([reminder valueForKey:@"objectID"]);
    NSString *sibUUID = extractUUID([sibling valueForKey:@"objectID"]);
    if ([targetUUID isEqualToString:sibUUID]) {
        return @{@"ok": @YES, @"id": extId,
                 @"title": [reminder valueForKey:@"titleAsString"] ?: @"",
                 @"listName": listName, @"relation": relation,
                 @"sibling": [sibling valueForKey:@"titleAsString"] ?: @"",
                 @"unchanged": @YES};
    }

    NSError *err = nil;
    id saveReq = makeSaveRequest(store, req[@"author"]);
    id listCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateList:"), list);
    id remCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), reminder);
    id sibCI = ((id(*)(id, SEL, id))objc_msgSend)(saveReq, NSSelectorFromString(@"updateReminder:"), sibling);
    NSString *sel = [relation isEqualToString:@"before"]
        ? @"insertReminderChangeItem:beforeReminderChangeItem:"
        : @"insertReminderChangeItem:afterReminderChangeItem:";
    ((void(*)(id, SEL, id, id))objc_msgSend)(listCI, NSSelectorFromString(sel), remCI, sibCI);

    if (!saveRequest(saveReq, &err)) return saveError(saveReq, err);

    return @{@"ok": @YES, @"id": extId,
             @"title": [reminder valueForKey:@"titleAsString"] ?: @"",
             @"listName": listName, @"relation": relation,
             @"sibling": [sibling valueForKey:@"titleAsString"] ?: @""};
}

NSDictionary *executeWriteRequest(id store, NSDictionary *req) {
    NSString *op = req[@"op"];
    @try {
        if ([op isEqualToString:@"add"]) return opAdd(store, req);
        if ([op isEqualToString:@"complete"]) return opComplete(store, req);
        if ([op isEqualToString:@"delete"]) return opDelete(store, req);
        if ([op isEqualToString:@"move"]) return opMove(store, req);
        if ([op isEqualToString:@"update"]) return opUpdate(store, req);
        if ([op isEqualToString:@"reorder"]) return opReorder(store, req);
        if ([op isEqualToString:@"deleted"]) return opDeleted(store, req);
        if ([op isEqualToString:@"restore"]) return opRestore(store, req);
        if ([op isEqualToString:@"deleteList"]) return opDeleteList(store, req);
        if ([op isEqualToString:@"updateList"]) return opUpdateList(store, req);
        if ([op isEqualToString:@"createGroup"]) return opCreateGroup(store, req);
        if ([op isEqualToString:@"createList"]) return opCreateList(store, req);
        if ([op isEqualToString:@"addSection"]) return opAddSection(store, req);
        if ([op isEqualToString:@"deleteSection"]) return opDeleteSection(store, req);
        if ([op isEqualToString:@"createSmartList"]) return opCreateSmartList(store, req);
        if ([op isEqualToString:@"moveList"]) return opMoveList(store, req);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"未知操作：%@", op]};
    } @catch (NSException *e) {
        return @{@"ok": @NO, @"error": e.reason ?: @"write exception"};
    }
}
