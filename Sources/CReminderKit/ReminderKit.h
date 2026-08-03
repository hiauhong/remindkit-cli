#import <Foundation/Foundation.h>

NSString *extractUUID(id object);
NSArray *parseSectionNames(id section);
NSString *colorToHex(id color);
NSString *badgeEmoji(id badgeEmblem);
NSArray *fetchSmartLists(id store, NSRegularExpression *uuidRegex);
NSArray *fetchListIDsOrdering(id store);
NSDictionary *fetchGroups(id store);
NSArray *fetchLists(id store, id groups);
NSSet *collectSectionedListUUIDs(NSArray *listEntries);
void fetchReminders(id store, NSSet *sectionedListUUIDs,
                    NSMutableArray *reminderEntries);

NSDictionary *executeWriteRequest(id store, NSDictionary *req);
