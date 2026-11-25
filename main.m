// iStats: a tiny performance overlay for Mac games.
// Reads CPU, GPU, memory and chip temperature from macOS only; never touches the game's process.
// Menu bar icon: show/hide the overlay, start/stop a recording (summary + CSV in ~/Documents/iStats).
// Build: ./build.sh
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <sys/sysctl.h>

// ---- Sensors ----
typedef struct __IOHIDEventSystemClient *HIDClient;
typedef struct __IOHIDServiceClient *HIDService;
typedef struct __IOHIDEvent *HIDEvent;
extern HIDClient IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(HIDClient, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(HIDClient);
extern HIDEvent IOHIDServiceClientCopyEvent(HIDService, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(HIDEvent, int32_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(HIDService, CFStringRef);

static double chipTemperature(void) {
    static NSArray *sensors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        HIDClient c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!c) return;
        IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
        NSMutableArray *found = [NSMutableArray array];
        for (id s in CFBridgingRelease(IOHIDEventSystemClientCopyServices(c))) {
            NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge HIDService)s, CFSTR("Product")));
            if ([name containsString:@"tdie"]) [found addObject:s];
        }
        sensors = found;
    });
    double hottest = 0;
    for (id s in sensors) {
        HIDEvent e = IOHIDServiceClientCopyEvent((__bridge HIDService)s, 15, 0, 0);
        if (!e) continue;
        double t = IOHIDEventGetFloatValue(e, 15 << 16);
        CFRelease(e);
        if (t > hottest && t < 150) hottest = t;
    }
    return hottest;
}

static double cpuPercent(void) {
    static uint64_t lastBusy, lastTotal;
    host_cpu_load_info_data_t info; mach_msg_type_number_t n = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &n) != KERN_SUCCESS) return -1;
    uint64_t busy = (uint64_t)info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_SYSTEM] + info.cpu_ticks[CPU_STATE_NICE];
    uint64_t total = busy + info.cpu_ticks[CPU_STATE_IDLE];
    double pct = total > lastTotal ? 100.0 * (busy - lastBusy) / (total - lastTotal) : -1;
    lastBusy = busy; lastTotal = total;
    return pct;
}

static double gpuPercent(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!s) return -1;
    double pct = -1;
    CFDictionaryRef stats = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (stats) {
        NSNumber *u = ((__bridge NSDictionary *)stats)[@"Device Utilization %"];
        if (u) pct = u.doubleValue;
        CFRelease(stats);
    }
    IOObjectRelease(s);
    return pct;
}

static double memoryUsedGB(double *totalGB) {
    vm_statistics64_data_t vm; mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    uint64_t total = 0; size_t len = sizeof total;
    sysctlbyname("hw.memsize", &total, &len, NULL, 0);
    *totalGB = total / 1073741824.0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) != KERN_SUCCESS) return -1;
    uint64_t used = ((uint64_t)vm.internal_page_count - vm.purgeable_count + vm.wire_count + vm.compressor_page_count) * vm_kernel_page_size;
    return used / 1073741824.0;
}

static int health(double v, double a, double b, double c) {
    if (v < 0) return -1;
    return v < a ? 0 : v < b ? 1 : v < c ? 2 : 3;
}

// ---- App ----
@interface Stats : NSObject <NSApplicationDelegate>
@property NSPanel *panel; @property NSTextField *label; @property NSStatusItem *item;
@property NSMenuItem *showItem, *recItem, *layoutItem;
@property (strong) dispatch_source_t timer;
@property BOOL moving, horizontal;
@property NSMutableArray<NSArray<NSNumber *> *> *rec; @property NSDate *recStart;
@end

@implementation Stats {
    double cpu, gpu, mem, memTotal, temp;
    int n;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    cpu = gpu = mem = temp = -1;
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSRect r = NSMakeRect(NSMaxX(screen) - 196, NSMaxY(screen) - 104, 184, 92);
    self.panel = [[NSPanel alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:NO];
    self.panel.level = CGShieldingWindowLevel() + 1;        // above everything, including games that capture the display (League fullscreen)
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
                                  | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    self.panel.ignoresMouseEvents = YES;                    // clicks go to the game
    self.panel.opaque = NO; self.panel.backgroundColor = NSColor.clearColor; self.panel.hasShadow = NO;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, r.size.width, r.size.height)];
    box.wantsLayer = YES;
    self.label = [NSTextField labelWithString:@""];
    self.label.frame = NSInsetRect(box.bounds, 10, 8);
    self.label.refusesFirstResponder = YES;
    [box addSubview:self.label];
    self.panel.contentView = box;
    self.panel.movableByWindowBackground = YES;
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"origin"];
    if (saved) { NSRect f = self.panel.frame; f.origin = NSPointFromString(saved); [self.panel setFrame:[self onScreen:f] display:NO]; }
    [self.panel orderFrontRegardless];
    // Locked: clicks pass through to the game, so a global monitor spots the double-click on the data.
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *e) {
        if (e.clickCount == 2 && !self.moving && NSPointInRect(NSEvent.mouseLocation, self.panel.frame)) [self setMoving:YES];
    }];
    // Unlocked: the panel gets the clicks itself; drag moves it, double-click locks it again.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged handler:^NSEvent *(NSEvent *e) {
        if (!self.moving) return e;
        if (e.type == NSEventTypeLeftMouseDown && e.clickCount == 2) { [self setMoving:NO]; return nil; }
        if (e.type == NSEventTypeLeftMouseDragged) {
            NSPoint o = self.panel.frame.origin;
            NSRect f = self.panel.frame; f.origin = NSMakePoint(o.x + e.deltaX, o.y - e.deltaY);
            [self.panel setFrame:[self onScreen:f] display:YES];
            return nil;
        }
        return nil;
    }];

    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title = @":)";
    NSMenu *m = [NSMenu new];
    self.showItem = [m addItemWithTitle:@"Hide Overlay" action:@selector(toggleShow) keyEquivalent:@""];
    self.recItem = [m addItemWithTitle:@"Start Recording" action:@selector(toggleRec) keyEquivalent:@""];
    self.layoutItem = [m addItemWithTitle:@"Horizontal Layout" action:@selector(toggleLayout) keyEquivalent:@""];
    self.horizontal = [NSUserDefaults.standardUserDefaults boolForKey:@"horizontal"];
    self.layoutItem.state = self.horizontal ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit iStats" action:@selector(terminate:) keyEquivalent:@"q"];
    for (NSMenuItem *i in m.itemArray) if (i.action != @selector(terminate:)) i.target = self;
    self.item.menu = m;

    // Sample off the main thread 10x a second; temperature every 0.5 s (it costs ~19 ms per read).
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    dispatch_source_set_event_handler(t, ^{ [self sample]; });
    dispatch_resume(t);
    self.timer = t;
}

- (void)sample {
    double c = cpuPercent(), g = gpuPercent(), total = 0, m = memoryUsedGB(&total);
    if (c >= 0) cpu = cpu < 0 ? c : cpu * 0.5 + c * 0.5;
    if (g >= 0) gpu = gpu < 0 ? g : gpu * 0.5 + g * 0.5;
    mem = m; memTotal = total;
    if (n++ % 5 == 0) { double tt = chipTemperature(); temp = tt > 0 ? tt : -1; }
    double sc = cpu, sg = gpu, sm = mem, st = temp, smt = memTotal;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.rec && self->n % 10 == 0)
            [self.rec addObject:@[@(-[self.recStart timeIntervalSinceNow]), @(sc), @(sg), @(sm), @(st)]];
        [self drawCPU:sc gpu:sg mem:sm total:smt temp:st];
    });
}

- (void)row:(NSMutableAttributedString *)s name:(NSString *)name value:(NSString *)value h:(int)h {
    NSArray *colors = @[[NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.40 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.82 blue:0.20 alpha:1],
                        [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.15 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.27 alpha:1]];
    NSFont *font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSFont *bold = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    NSColor *dim = [NSColor colorWithWhite:1 alpha:0.75];
    static NSShadow *sh; if (!sh) { sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowBlurRadius = 2.5; sh.shadowOffset = NSMakeSize(0, -1); }
    if (s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:self.horizontal ? @"   " : @"\n"]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:(h >= 0 ? @"● " : @"  ")
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: h >= 0 ? colors[h] : dim, NSShadowAttributeName: sh}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:(self.horizontal ? [name stringByAppendingString:@" "] : [name stringByPaddingToLength:5 withString:@" " startingAtIndex:0])
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: dim, NSShadowAttributeName: sh}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:value
        attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: NSColor.whiteColor, NSShadowAttributeName: sh}]];
}

- (void)drawCPU:(double)c gpu:(double)g mem:(double)m total:(double)t temp:(double)tp {
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    [self row:s name:@"CPU" value:c < 0 ? @"--" : [NSString stringWithFormat:@"%.0f%%", c] h:health(c, 60, 80, 95)];
    [self row:s name:@"GPU" value:g < 0 ? @"--" : [NSString stringWithFormat:@"%.0f%%", g] h:health(g, 70, 90, 98)];
    [self row:s name:@"MEM" value:m < 0 ? @"--" : [NSString stringWithFormat:@"%.1f/%.0f GB", m, t] h:health(t > 0 ? m / t * 100 : -1, 70, 85, 95)];
    [self row:s name:@"TEMP" value:tp < 0 ? @"--" : [NSString stringWithFormat:@"%.0f°C", tp] h:health(tp, 75, 90, 100)];
    if (self.rec) [self row:s name:@"REC" value:[NSString stringWithFormat:@"%.0fs", -[self.recStart timeIntervalSinceNow]] h:3];
    self.label.attributedStringValue = s;
    CGFloat w = self.horizontal ? (self.rec ? 520 : 440) : 184, h = self.horizontal ? 30 : (self.rec ? 108 : 92);
    NSRect f = self.panel.frame;
    if (f.size.height != h || f.size.width != w) {   // keep the top-left corner where it is
        f.origin.y += f.size.height - h; f.size.height = h; f.size.width = w;
        [self.panel setFrame:[self onScreen:f] display:YES]; self.label.frame = NSInsetRect(self.panel.contentView.bounds, 10, 8);
    }
}

// Keep the overlay fully inside a screen: a saved spot from another layout or a gone monitor must not hide it.
- (NSRect)onScreen:(NSRect)f {
    NSScreen *best = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSIntersectsRect(s.frame, f)) { best = s; break; }
    NSRect v = best.visibleFrame;
    f.origin.x = MAX(NSMinX(v), MIN(f.origin.x, NSMaxX(v) - f.size.width));
    f.origin.y = MAX(NSMinY(v), MIN(f.origin.y, NSMaxY(v) - f.size.height));
    return f;
}

- (void)setMoving:(BOOL)on {
    _moving = on;
    self.panel.ignoresMouseEvents = !on;
    NSView *v = self.panel.contentView;
    v.layer.borderWidth = on ? 1.5 : 0;
    v.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.7].CGColor;
    v.layer.cornerRadius = 6;
    v.layer.backgroundColor = on ? [NSColor colorWithWhite:0 alpha:0.25].CGColor : NSColor.clearColor.CGColor;
    if (!on) [NSUserDefaults.standardUserDefaults setObject:NSStringFromPoint(self.panel.frame.origin) forKey:@"origin"];
}

- (void)toggleLayout {
    self.horizontal = !self.horizontal;
    self.layoutItem.state = self.horizontal ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:self.horizontal forKey:@"horizontal"];
}

- (void)toggleShow {
    if (self.panel.isVisible) { [self.panel orderOut:nil]; self.showItem.title = @"Show Overlay"; }
    else { [self.panel orderFrontRegardless]; self.showItem.title = @"Hide Overlay"; }
}

- (void)toggleRec {
    if (!self.rec) {
        self.rec = [NSMutableArray array]; self.recStart = [NSDate date];
        self.recItem.title = @"Stop Recording"; self.item.button.title = @":) ●";
        return;
    }
    NSArray *rows = self.rec; self.rec = nil;
    self.recItem.title = @"Start Recording"; self.item.button.title = @":)";
    if (rows.count < 2) return;
    double sum[5] = {0}, mx[5] = {0}; int cnt[5] = {0};
    NSMutableString *csv = [NSMutableString stringWithString:@"seconds,cpu_percent,gpu_percent,memory_gb,temp_c\n"];
    for (NSArray<NSNumber *> *r in rows) {
        [csv appendFormat:@"%.1f,%.1f,%.1f,%.2f,%.1f\n", r[0].doubleValue, r[1].doubleValue, r[2].doubleValue, r[3].doubleValue, r[4].doubleValue];
        for (int i = 1; i < 5; i++) { double v = r[i].doubleValue; if (v < 0) continue; sum[i] += v; cnt[i]++; if (v > mx[i]) mx[i] = v; }
    }
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/iStats"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *path = [dir stringByAppendingPathComponent:[[df stringFromDate:self.recStart] stringByAppendingString:@".csv"]];
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    double secs = ((NSArray<NSNumber *> *)rows.lastObject)[0].doubleValue;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Recording: %d min %02d s", (int)secs / 60, (int)secs % 60];
    a.informativeText = [NSString stringWithFormat:@"CPU   avg %.0f%%   max %.0f%%\nGPU   avg %.0f%%   max %.0f%%\nMemory   avg %.1f GB   max %.1f GB\nTemp   avg %.0f°C   max %.0f°C\n\nSaved to Documents/iStats.",
        cnt[1] ? sum[1] / cnt[1] : 0, mx[1], cnt[2] ? sum[2] / cnt[2] : 0, mx[2], cnt[3] ? sum[3] / cnt[3] : 0, mx[3], cnt[4] ? sum[4] / cnt[4] : 0, mx[4]];
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;  // no Dock icon
        Stats *d = [Stats new]; app.delegate = d;
        [app run];
    }
}
