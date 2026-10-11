/*
 * tpK-tap-logger.m
 *
 * Tap Logger — diagnostic de reverse-engineering.
 *
 * Lecture seule : on observe hitTest:/la hiérarchie que UIKit produit déjà
 * pour ce touch. Aucun appel n'altère la gestion de l'évent ni son
 * acheminement. L'installation se fait par swizzle de UIWindow.sendEvent:
 * (méthode d'instance) : la boucle se déclenche sur n'importe quelle
 * fenêtre qui reçoit un touch — key window, PiP, overlay, clavier — sans
 * jamais nommer sa classe à l'avance.
 */

#import "Settings/tpK-tap-logger.h"
#import "Core/tpK-core-manager.h"

static NSInteger s_tapLogCount = 0;

static NSString *tpk_imgDesc(UIImage *img) {
    if (!img) return @"nil";
    NSString *d = img.description;
    // SF Symbol : ne garder que le nom, pas la config de traits/insets.
    NSRange r = [d rangeOfString:@"symbol("];
    if (r.location != NSNotFound) {
        NSUInteger from = r.location + r.length;
        NSRange end = [d rangeOfString:@")"
                               options:0
                                 range:NSMakeRange(from, d.length - from)];
        if (end.location != NSNotFound && end.location > from) {
            NSString *name = [d substringWithRange:NSMakeRange(from, end.location - from)];
            return [NSString stringWithFormat:@"%@ %.0fx%.0f",
                    name, img.size.width, img.size.height];
        }
    }
    return [NSString stringWithFormat:@"img %.0fx%.0f",
            img.size.width, img.size.height];
}

static NSString *tpk_viewExtra(UIView *v) {
    NSMutableString *extra = [NSMutableString string];

    if (v.accessibilityLabel.length > 0)
        [extra appendFormat:@" accLabel='%@'", v.accessibilityLabel];

    if (v.accessibilityIdentifier.length > 0)
        [extra appendFormat:@" accID='%@'", v.accessibilityIdentifier];

    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        NSArray *states = @[@(UIControlStateNormal), @(UIControlStateSelected),
                            @(UIControlStateHighlighted), @(UIControlStateDisabled)];
        NSArray *stateNames = @[@"normal", @"selected", @"highlighted", @"disabled"];
        for (NSUInteger i = 0; i < states.count; i++) {
            UIControlState st = ((NSNumber *)states[i]).unsignedIntegerValue;
            NSString *title = [btn titleForState:st];
            UIImage  *img   = [btn imageForState:st];
            if (title.length > 0)
                [extra appendFormat:@" btnTitle[%@]='%@'", stateNames[i], title];
            if (img)
                [extra appendFormat:@" btnImg[%@]=(%@)", stateNames[i], tpk_imgDesc(img)];
        }
        NSSet *targets = [btn allTargets];
        for (id target in targets) {
            NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (actions.count > 0)
                [extra appendFormat:@" action=%@->%@",
                 NSStringFromClass([target class]), [actions componentsJoinedByString:@","]];
        }
    }

    if ([v isKindOfClass:[UITextField class]])
        [extra appendFormat:@" ph='%@'", ((UITextField *)v).placeholder ?: @""];

    if ([v isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)v).text;
        if (txt.length > 0 && txt.length <= 40)
            [extra appendFormat:@" text='%@'", txt];
    }

    return [extra copy];
}

static UIViewController *tpk_vcForView(UIView *v) {
    UIResponder *r = v.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// Le tap porte-t-il sur une vue de TwitchPlusK (classe TPK*/TPK* ou
// fenêtre du floating button) ? Auquel cas on ne logue rien : le Tap Logger
// sert à observer Twitch, pas notre propre UI.
static BOOL tpk_isOurView(UIView *v) {
    for (UIView *w = v; w; w = w.superview) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn hasPrefix:@"TPK"] || [cn hasPrefix:@"TPK"]) return YES;
        UIViewController *vc = tpk_vcForView(w);
        if (vc) {
            NSString *vcn = NSStringFromClass([vc class]);
            if ([vcn hasPrefix:@"TPK"] || [vcn hasPrefix:@"TPK"]) return YES;
        }
    }
    NSString *wn = NSStringFromClass([[v window] class]);
    return [wn hasPrefix:@"TPK"] || [wn hasPrefix:@"TPK"];
}

@interface UIWindow (TPKTapLogger)
- (void)tpk_sendEvent:(UIEvent *)event;
@end

@implementation UIWindow (TPKTapLogger)

- (void)tpk_sendEvent:(UIEvent *)event {
    [self tpk_sendEvent:event];

    TPKManager *mgr = [TPKManager sharedManager];
    if (!mgr.logsEnabled || !mgr.logTap) return;
    if (event.type != UIEventTypeTouches) return;

    UITouch *touch = event.allTouches.anyObject;
    if (!touch || touch.phase != UITouchPhaseBegan) return;

    CGPoint pt = [touch locationInView:self];
    UIView *hit = [self hitTest:pt withEvent:nil];

    // Tap porté par notre propre UI : silencieux.
    if (hit && tpk_isOurView(hit)) return;

    s_tapLogCount++;

    [mgr log:@"👆 TAP #%ld @ (%.0f, %.0f)", (long)s_tapLogCount, pt.x, pt.y];

    UIResponder *currentFR = nil;
    {
        NSMutableArray<UIView *> *frQueue = [NSMutableArray arrayWithObject:self];
        while (frQueue.count > 0) {
            UIView *fv = frQueue.firstObject; [frQueue removeObjectAtIndex:0];
            if (fv.isFirstResponder) { currentFR = fv; break; }
            for (UIView *sub in fv.subviews) [frQueue addObject:sub];
        }
    }
    if (currentFR) {
        NSString *frExtra = @"";
        if ([currentFR isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)currentFR;
            frExtra = [NSString stringWithFormat:@" text='%@' selectedRange={%lu,%lu}",
                       tv.text ?: @"",
                       (unsigned long)tv.selectedRange.location,
                       (unsigned long)tv.selectedRange.length];
        }
        [mgr log:@"  FIRST_RESPONDER: %@%@",
         NSStringFromClass([currentFR class]), frExtra];
    } else {
        [mgr log:@"  FIRST_RESPONDER: (aucun)"];
    }

    if (!hit) {
        [mgr log:@"  HIT: (nil)"];
        return;
    }

    [mgr log:@"  HIT: %@ frame=(%.0f,%.0f,%.0f,%.0f) tag=%ld%@",
     NSStringFromClass([hit class]),
     hit.frame.origin.x, hit.frame.origin.y,
     hit.frame.size.width, hit.frame.size.height,
     (long)hit.tag,
     tpk_viewExtra(hit)];

    UIViewController *vc = tpk_vcForView(hit);
    if (vc) [mgr log:@"  VC: %@", NSStringFromClass([vc class])];

    UIView *v = hit.superview;
    for (int d = 1; d <= 45 && v; d++, v = v.superview) {
        [mgr log:@"  [%02d] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
         d, NSStringFromClass([v class]),
         v.frame.origin.x, v.frame.origin.y,
         v.frame.size.width, v.frame.size.height,
         tpk_viewExtra(v)];
    }
    [mgr log:@"  ── fin hiérarchie ──"];
}

@end

void TPKTapLoggerSetup(void) {
    tpk_swizzle([UIWindow class],
                 [UIWindow class],
                 @selector(sendEvent:),
                 @selector(tpk_sendEvent:));
}
