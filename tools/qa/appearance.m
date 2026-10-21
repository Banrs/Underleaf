#import <Cocoa/Cocoa.h>
// Injected into the QA app only (DYLD_INSERT_LIBRARIES): forces NSApp.appearance from QA_APPEARANCE=dark|light.
static void apply(void) {
    const char *v = getenv("QA_APPEARANCE");
    if (!v) return;
    NSAppearanceName n = strcmp(v, "dark") == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
    NSApp.appearance = [NSAppearance appearanceNamed:n];
}
__attribute__((constructor)) static void qa_init(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n){ apply(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n){ apply(); }];
}
