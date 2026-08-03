#import "ReminderKit.h"
#import <objc/message.h>

NSString *extractUUID(id object) {
    if (!object || [object isKindOfClass:[NSNull class]]) return nil;
    NSString *desc = [[object description]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
        @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        options:0 error:NULL];
    NSTextCheckingResult *match = [regex firstMatchInString:desc options:0
                                                     range:NSMakeRange(0, desc.length)];
    return match ? [desc substringWithRange:match.range] : nil;
}

NSArray *parseSectionNames(id section) {
    NSString *debugDesc = [[section valueForKey:@"storage"] debugDescription];
    NSRange addrEnd = [debugDesc rangeOfString:@"0x[0-9a-fA-F]+ "
        options:NSRegularExpressionSearch];
    if (addrEnd.location == NSNotFound) return @[];

    NSString *afterAddr = [debugDesc substringFromIndex:addrEnd.location + addrEnd.length];
    NSRange tildeRange = [afterAddr rangeOfString:@"~<"];
    if (tildeRange.location == NSNotFound || tildeRange.location <= 0) return @[];

    NSString *secName = [afterAddr substringToIndex:tildeRange.location];
    secName = [secName stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSRange lastSpace = [secName rangeOfString:@" " options:NSBackwardsSearch];
    if (lastSpace.location != NSNotFound)
        secName = [secName substringToIndex:lastSpace.location];
    if (secName.length == 0) return @[];
    return @[secName];
}

NSString *colorToHex(id color) {
    if (![color respondsToSelector:NSSelectorFromString(@"description")]) return nil;
    NSString *desc = [color description];
    if (![desc hasPrefix:@"REMColor:rgba("]) return nil;

    NSString *rgba = [desc substringFromIndex:14];  // "REMColor:rgba(" is 14 chars
    rgba = [rgba substringToIndex:[rgba length] - 1];
    NSArray *parts = [rgba componentsSeparatedByString:@","];
    if ([parts count] < 3) return nil;

    int r = (int)([[parts[0] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] floatValue] * 255);
    int g = (int)([[parts[1] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] floatValue] * 255);
    int b = (int)([[parts[2] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] floatValue] * 255);
    return [NSString stringWithFormat:@"#%02x%02x%02x", r, g, b];
}

NSString *badgeEmoji(id badgeEmblem) {
    if (![badgeEmblem isKindOfClass:[NSString class]]) return nil;
    NSData *jsonData = [(NSString *)badgeEmblem dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    return json[@"Emoji"];
}
