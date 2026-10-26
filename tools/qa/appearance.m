#import <Cocoa/Cocoa.h>
// Injected into the QA app only (DYLD_INSERT_LIBRARIES): forces NSApp.appearance from QA_APPEARANCE=dark|light, and with
// QA_INVISIBLE=1 keeps every window transparent and click-through, so a run lays out and draws without showing.
static void apply(void) {
    const char *v = getenv("QA_APPEARANCE");
    if (!v) return;
    NSAppearanceName n = strcmp(v, "dark") == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
    NSApp.appearance = [NSAppearance appearanceNamed:n];
}
static void hide(NSWindow *window) {
    if (window.alphaValue != 0) window.alphaValue = 0;
    if (!window.ignoresMouseEvents) window.ignoresMouseEvents = YES;
}
__attribute__((constructor)) static void qa_init(void) {
    if (getenv("QA_INVISIBLE")) {
        for (NSNotificationName name in @[NSWindowDidUpdateNotification, NSWindowDidBecomeKeyNotification, NSWindowDidResizeNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n){ hide(n.object); }];
        }
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n){ apply(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n){ apply(); }];
}
