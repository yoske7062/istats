// iStats: a tiny performance overlay for Mac games.
// Reads CPU, GPU, memory and chip temperature from macOS only; never touches the game's process.
// Menu bar icon: show/hide the overlay, start/stop a recording (summary + CSV in ~/Documents/iStats),
// and optional keyboard sounds (a switch sound in your headphones on every key; off by default).
// Build: ./build.sh
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <IOKit/hidsystem/IOLLEvent.h>

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
    static io_service_t s;   // looked up once: the registry search costs more than reading the stats
    if (!s) s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!s) return -1;
    double pct = -1;
    CFDictionaryRef stats = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (stats) {
        NSNumber *u = ((__bridge NSDictionary *)stats)[@"Device Utilization %"];
        if (u) pct = u.doubleValue;
        CFRelease(stats);
    }
    return pct;
}

static double memoryUsedGB(double *totalGB) {
    vm_statistics64_data_t vm; mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    static uint64_t total;
    if (!total) { size_t len = sizeof total; sysctlbyname("hw.memsize", &total, &len, NULL, 0); }
    *totalGB = total / 1073741824.0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) != KERN_SUCCESS) return -1;
    uint64_t used = ((uint64_t)vm.internal_page_count - vm.purgeable_count + vm.wire_count + vm.compressor_page_count) * vm_kernel_page_size;
    return used / 1073741824.0;
}

static int health(double v, double a, double b, double c) {
    if (v < 0) return -1;
    return v < a ? 0 : v < b ? 1 : v < c ? 2 : 3;
}

// ---- Keyboard sounds ----
// Every switch is synthesized (noise transient + damped resonances + two early reflections), so there are no sample
// files and nothing to license. Sounds are rendered once per switch; playback only mixes ready buffers.
#define SR 48000
#define NVAR 4                       // takes per sound, so repeated keys never sound identical
typedef struct { float hz, tau, amp; } Mode;
typedef struct {
    const char *name;
    float click, clickHz, clickTau, upClick;  // click jacket / tactile bump; upClick: clicks again on release
    float travel;                             // ms from bump to bottom-out
    float hit, hitTau, hitTone;               // bottom-out: level, decay ms, brightness 0..1
    Mode modes[3];                            // keycap, plate and case resonances
    float spring;                             // buckling spring ping
    float up, gain;                           // release level, overall level
} Switch;

static const Switch switches[] = {
    {"Cherry MX Blue (clicky)",        1.0, 4200, 1.0, .65, 9, .55, 1.5, .50, {{1900, 6, .25}, {3100, 4, .20}, {900, 9, .15}}, 0, .70, .85},
    {"Kailh Box Jade (thick click)",   1.0, 3300, 1.4, .70, 8, .70, 1.8, .40, {{1500, 7, .30}, {2700, 5, .20}, {750, 11, .20}}, 0, .70, .90},
    {"Cherry MX Brown (tactile)",      .25, 2500, 1.5, 0, 6, .80, 2.0, .35, {{1400, 8, .30}, {2600, 5, .20}, {700, 12, .20}}, 0, .50, 1},
    {"Holy Panda (tactile thock)",     .35, 1800, 2.0, 0, 5, 1.0, 2.5, .20, {{450, 18, .50}, {900, 10, .30}, {1700, 6, .15}}, 0, .55, 1},
    {"Cherry MX Red (linear)",         0, 0, 0, 0, 0, .90, 2.0, .30, {{1200, 9, .30}, {2300, 5, .20}, {600, 14, .20}}, 0, .50, 1},
    {"Gateron Ink Black (deep thock)", 0, 0, 0, 0, 0, 1.0, 3.0, .12, {{320, 22, .60}, {620, 14, .35}, {1150, 7, .15}}, 0, .40, 1},
    {"Topre (dome, soft thock)",       .20, 900, 3.0, 0, 4, .80, 4.0, .08, {{260, 25, .55}, {520, 15, .30}, {980, 8, .10}}, 0, .35, 1},
    {"IBM Model M (buckling spring)",  .90, 3000, 1.5, .40, 7, .80, 2.0, .40, {{1100, 10, .30}, {2000, 6, .20}, {0}}, .45, .60, .85},
    {"Silent (dampened)",              0, 0, 0, 0, 0, .60, 4.0, .05, {{380, 10, .30}, {750, 6, .10}, {0}}, 0, .20, .60},
};
#define NSW (int)(sizeof switches / sizeof *switches)

static uint32_t seed = 1;
static float noise(void) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed / 2147483648.0f - 1; }

static void addNoise(float *y, int len, int at, float amp, float tauMs, float tone) {
    float c = .02f + .98f * tone, g = amp / sqrtf(c / (2 - c)), lp = 0, k = 1000 / (tauMs * SR);  // gain-compensated lowpass
    for (int i = 0; at + i < len && i < tauMs * SR / 1000 * 7; i++) { lp += c * (noise() - lp); y[at + i] += g * lp * expf(-i * k); }
}

static void addMode(float *y, int len, int at, float hz, float tauMs, float amp) {
    float k = 1000 / (tauMs * SR), w = 2 * M_PI * hz / SR, ph = noise() * M_PI;
    for (int i = 0; at + i < len && i < tauMs * SR / 1000 * 7; i++)
        y[at + i] += amp * (i < 12 ? i / 12.0f : 1) * sinf(w * i + ph) * expf(-i * k);  // 0.25 ms attack: no step
}

// kind: 0 press, 1 big key press (space, enter, shift...), 2 release
static float *synth(const Switch *s, int kind, int *outLen) {
    int len = SR / 5; float *y = calloc(len, sizeof *y);
    BOOL big = kind == 1, up = kind == 2;
    float fs = big ? .72f : up ? 1.15f : 1, ts = big ? 1.5f : up ? .7f : 1, hit = up ? .55f : 1;  // upstroke: lighter clack
    float clk = up ? s->upClick : s->click; int at = 0;
    if (clk > 0) {
        addMode(y, len, 0, s->clickHz * (up ? 1.08f : 1), s->clickTau, clk);
        addNoise(y, len, 0, clk * .5f, s->clickTau * .7f, .9f);
        at = s->travel * SR / 1000 * (up ? .6f : 1);
    }
    addNoise(y, len, at, s->hit * hit, s->hitTau * ts, MIN(1, s->hitTone * (up ? 1.4f : 1)));
    for (int m = 0; m < 3; m++) if (s->modes[m].amp > 0)
        addMode(y, len, at, s->modes[m].hz * fs * (1 + .02f * noise()), s->modes[m].tau * ts, s->modes[m].amp * hit);
    if (big) {  // stabilizer: a second, rattly contact a few ms later
        int st = at + SR * 35 / 10000;
        addNoise(y, len, st, s->hit * .35f, 1.2f, .55f);
        addMode(y, len, st, 2400, 3, .12f);
    }
    if (s->spring > 0) {
        float sp = s->spring * (up ? .6f : 1);
        addMode(y, len, at, 2750, 28, sp); addMode(y, len, at, 4300, 22, sp * .7f); addMode(y, len, at, 5900, 16, sp * .45f);
    }
    int d1 = SR * 71 / 10000, d2 = SR * 129 / 10000;  // small room; back to front so each tap reads the dry signal
    for (int i = len - 1; i >= d1; i--) y[i] += .2f * y[i - d1] + (i >= d2 ? .1f * y[i - d2] : 0);
    float rc = 1 / (2 * M_PI * 70), a = rc / (rc + 1.0f / SR), px = 0, py = 0, peak = 1e-9f;  // 70 Hz highpass: no boom
    for (int i = 0; i < len; i++) { float x = y[i]; py = a * (py + x - px); px = x; y[i] = py; peak = MAX(peak, fabsf(py)); }
    float target = .5f * s->gain * (up ? s->up : 1) * (big ? 1.1f : 1);
    int end = 0;
    for (int i = 0; i < len; i++) { y[i] *= target / peak; if (fabsf(y[i]) > target * .002f) end = i; }
    int fade = SR / 500;  // 2 ms fade out
    len = MIN(len, end + fade);
    for (int i = 0; i < fade && i < len; i++) y[len - 1 - i] *= i / (float)fade;
    *outLen = len;
    return y;
}

static float *bank[NSW][3][NVAR]; static int bankLen[NSW][3][NVAR];   // never freed: the audio thread can't read a dead buffer
static void loadSwitch(int s) {
    if (bank[s][0][0]) return;
    for (int k = 0; k < 3; k++) for (int v = 0; v < NVAR; v++) {
        seed = (uint32_t)(s * 31 + k * 7 + v + 1) * 2654435761u;
        bank[s][k][v] = synth(&switches[s], k, &bankLen[s][k][v]);
    }
}

// Left-to-right spot of each key on an ANSI board (in key widths, 0..14.5), for a subtle stereo spread in headphones.
static const float keyX[128] = {
    [50] = .3f, [18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5, [22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10, [27] = 11, [24] = 12, [51] = 13.5f,
    [48] = .5f, [12] = 1.5f, [13] = 2.5f, [14] = 3.5f, [15] = 4.5f, [17] = 5.5f, [16] = 6.5f, [32] = 7.5f, [34] = 8.5f, [31] = 9.5f, [35] = 10.5f, [33] = 11.5f, [30] = 12.5f, [42] = 13.7f,
    [57] = .9f, [0] = 1.8f, [1] = 2.8f, [2] = 3.8f, [3] = 4.8f, [5] = 5.8f, [4] = 6.8f, [38] = 7.8f, [40] = 8.8f, [37] = 9.8f, [41] = 10.8f, [39] = 11.8f, [36] = 13.4f,
    [56] = 1.1f, [6] = 2.3f, [7] = 3.3f, [8] = 4.3f, [9] = 5.3f, [11] = 6.3f, [45] = 7.3f, [46] = 8.3f, [43] = 9.3f, [47] = 10.3f, [44] = 11.3f, [60] = 13.2f,
    [63] = .3f, [59] = 1, [58] = 1.8f, [55] = 2.9f, [49] = 7.2f, [54] = 10.6f, [61] = 11.6f, [123] = 12.7f, [125] = 13.5f, [126] = 13.5f, [124] = 14.3f, [53] = .2f,
};
static BOOL bigKey(int kc) { return kc == 49 || kc == 36 || kc == 51 || kc == 48 || kc == 56 || kc == 60 || kc == 57 || kc == 76; }

// The main thread pushes voices into a single-producer/single-consumer queue; the render block mixes them.
// No locks and no allocation on the audio thread.
typedef struct { const float *d; int len; float pos, inc, gl, gr; } Voice;
#define NV 16
#define QN 64
static Voice voices[NV], queue[QN];
static _Atomic unsigned qHead, qTail;

static void pushVoice(Voice v) {
    unsigned h = atomic_load_explicit(&qHead, memory_order_relaxed);
    if (h - atomic_load_explicit(&qTail, memory_order_acquire) >= QN) return;   // audio thread behind: drop, never block
    queue[h % QN] = v;
    atomic_store_explicit(&qHead, h + 1, memory_order_release);
}

static OSStatus renderVoices(BOOL *silence, AVAudioFrameCount frames, AudioBufferList *abl) {
    unsigned t = atomic_load_explicit(&qTail, memory_order_relaxed), h = atomic_load_explicit(&qHead, memory_order_acquire);
    for (; t != h; t++) {   // free slot, else steal the voice nearest its end
        int slot = 0; float best = -1;
        for (int i = 0; i < NV; i++) {
            if (!voices[i].d) { slot = i; break; }
            float done = voices[i].pos / voices[i].len; if (done > best) { best = done; slot = i; }
        }
        voices[slot] = queue[t % QN];
    }
    atomic_store_explicit(&qTail, t, memory_order_release);
    float *L = abl->mBuffers[0].mData, *R = abl->mNumberBuffers > 1 ? abl->mBuffers[1].mData : NULL;
    memset(L, 0, frames * sizeof(float)); if (R) memset(R, 0, frames * sizeof(float));
    BOOL any = NO;
    for (int i = 0; i < NV; i++) {
        Voice *v = &voices[i];
        if (!v->d) continue;
        any = YES;
        for (AVAudioFrameCount f = 0; f < frames; f++) {
            int p = (int)v->pos;
            if (p + 1 >= v->len) { v->d = NULL; break; }
            float s = v->d[p] + (v->d[p + 1] - v->d[p]) * (v->pos - p);
            L[f] += s * v->gl; if (R) R[f] += s * v->gr;
            v->pos += v->inc;
        }
    }
    *silence = !any;
    return noErr;
}

static CGEventRef keyTap(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx);

// ---- App ----
@interface Stats : NSObject <NSApplicationDelegate>
@property NSPanel *panel; @property NSTextField *label; @property NSStatusItem *item;
@property NSMenuItem *showItem, *recItem, *layoutItem, *kbItem, *permItem;
@property NSMenu *kbMenu;
@property (strong) dispatch_source_t timer, idle;
@property BOOL moving, horizontal;
@property NSMutableArray<NSArray<NSNumber *> *> *rec; @property NSDate *recStart;
@property NSString *shown;
@property AVAudioEngine *engine; @property NSTimer *permTimer;
- (void)tapEvent:(CGEventType)type event:(CGEventRef)e;
@end

static CGEventRef keyTap(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx) {
    [(__bridge Stats *)ctx tapEvent:type event:e];
    return e;   // listen-only: the key always goes through untouched
}

static float rnd(void) { return arc4random_uniform(1000) / 1000.0f; }

@implementation Stats {
    double cpu, gpu, mem, memTotal, temp;
    int n;
    BOOL sampling;
    CFMachPortRef tap; CFRunLoopSourceRef tapSrc;
    CFAbsoluteTime lastKey;
    int kbSwitch; float kbVolume, kbPitch; BOOL kbRelease;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    cpu = gpu = mem = temp = -1;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"kbSwitch": @3, @"kbVolume": @0.5, @"kbPitch": @1.0, @"kbRelease": @NO}];
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
    [m addItemWithTitle:@"Keyboard Sounds" action:nil keyEquivalent:@""].submenu = [self keyboardMenu];
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit iStats" action:@selector(terminate:) keyEquivalent:@"q"];
    for (NSMenuItem *i in m.itemArray) if (i.action && i.action != @selector(terminate:)) i.target = self;
    self.item.menu = m;

    // Sample off the main thread twice a second; temperature every 3 s (it costs ~19 ms per read).
    // Stops entirely while the overlay is hidden and nothing is recording.
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(t, ^{ [self sample]; });
    dispatch_resume(t);
    self.timer = t; sampling = YES;

    if ([NSUserDefaults.standardUserDefaults boolForKey:@"kbOn"]) [self startKeys];
}

- (void)sample {
    @autoreleasepool {
        double c = cpuPercent(), g = gpuPercent(), total = 0, m = memoryUsedGB(&total);
        if (c >= 0) cpu = cpu < 0 ? c : cpu * 0.5 + c * 0.5;
        if (g >= 0) gpu = gpu < 0 ? g : gpu * 0.5 + g * 0.5;
        mem = m; memTotal = total;
        int k = n++;
        if (k % 6 == 0) { double tt = chipTemperature(); temp = tt > 0 ? tt : -1; }
        double sc = cpu, sg = gpu, sm = mem, st = temp, smt = memTotal;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.rec && k % 2 == 0)   // one CSV row per second
                [self.rec addObject:@[@(-[self.recStart timeIntervalSinceNow]), @(sc), @(sg), @(sm), @(st)]];
            [self drawCPU:sc gpu:sg mem:sm total:smt temp:st];
        });
    }
}

- (void)updateSampling {
    BOOL want = self.panel.isVisible || self.rec;
    if (want == sampling) return;
    sampling = want;
    want ? dispatch_resume(self.timer) : dispatch_suspend(self.timer);
}

- (void)row:(NSMutableAttributedString *)s name:(NSString *)name value:(NSString *)value h:(int)h {
    static NSArray *dots; static NSDictionary *dimA, *valA;
    if (!dots) {
        NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowBlurRadius = 2.5; sh.shadowOffset = NSMakeSize(0, -1);
        NSFont *font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        NSMutableArray *d = [NSMutableArray array];
        for (NSColor *c in @[[NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.40 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.82 blue:0.20 alpha:1],
                             [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.15 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.27 alpha:1]])
            [d addObject:@{NSFontAttributeName: font, NSForegroundColorAttributeName: c, NSShadowAttributeName: sh}];
        dots = d;
        dimA = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.75], NSShadowAttributeName: sh};
        valA = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.whiteColor, NSShadowAttributeName: sh};
    }
    if (s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:self.horizontal ? @"   " : @"\n"]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:(h >= 0 ? @"● " : @"  ") attributes:h >= 0 ? dots[h] : dimA]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:(self.horizontal ? [name stringByAppendingString:@" "] : [name stringByPaddingToLength:5 withString:@" " startingAtIndex:0])
        attributes:dimA]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:value attributes:valA]];
}

- (void)drawCPU:(double)c gpu:(double)g mem:(double)m total:(double)t temp:(double)tp {
    NSString *vc = c < 0 ? @"--" : [NSString stringWithFormat:@"%.0f%%", c], *vg = g < 0 ? @"--" : [NSString stringWithFormat:@"%.0f%%", g];
    NSString *vm = m < 0 ? @"--" : [NSString stringWithFormat:@"%.1f/%.0f GB", m, t], *vt = tp < 0 ? @"--" : [NSString stringWithFormat:@"%.0f°C", tp];
    NSString *vr = self.rec ? [NSString stringWithFormat:@"%.0fs", -[self.recStart timeIntervalSinceNow]] : nil;
    int hc = health(c, 60, 80, 95), hg = health(g, 70, 90, 98), hm = health(t > 0 ? m / t * 100 : -1, 70, 85, 95), ht = health(tp, 75, 90, 100);
    NSString *key = [NSString stringWithFormat:@"%@%@%@%@%@%d%d%d%d%d", vc, vg, vm, vt, vr, hc, hg, hm, ht, self.horizontal];
    if ([key isEqualToString:self.shown]) return;   // nothing changed: skip the text layout and the window redraw
    self.shown = key;
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    [self row:s name:@"CPU" value:vc h:hc];
    [self row:s name:@"GPU" value:vg h:hg];
    [self row:s name:@"MEM" value:vm h:hm];
    [self row:s name:@"TEMP" value:vt h:ht];
    if (vr) [self row:s name:@"REC" value:vr h:3];
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
    [self updateSampling];
}

// ---- Keyboard sounds: menu ----
- (NSMenu *)keyboardMenu {
    NSMenu *k = [NSMenu new];
    self.kbItem = [k addItemWithTitle:@"Play Key Sounds" action:@selector(toggleKeys) keyEquivalent:@""];
    self.permItem = [k addItemWithTitle:@"Needs Input Monitoring: Open Settings…" action:@selector(openPermission) keyEquivalent:@""];
    self.permItem.hidden = YES;
    [k addItem:NSMenuItem.separatorItem];
    for (int i = 0; i < NSW; i++) [k addItemWithTitle:@(switches[i].name) action:@selector(pickSwitch:) keyEquivalent:@""].tag = i;
    [k addItem:NSMenuItem.separatorItem];
    NSMenu *vol = [NSMenu new], *pit = [NSMenu new];
    for (NSNumber *v in @[@10, @25, @50, @75, @100]) [vol addItemWithTitle:[NSString stringWithFormat:@"%@%%", v] action:@selector(pickVolume:) keyEquivalent:@""].tag = v.intValue;
    [pit addItemWithTitle:@"Deep" action:@selector(pickPitch:) keyEquivalent:@""].tag = 88;
    [pit addItemWithTitle:@"Normal" action:@selector(pickPitch:) keyEquivalent:@""].tag = 100;
    [pit addItemWithTitle:@"Bright" action:@selector(pickPitch:) keyEquivalent:@""].tag = 112;
    [k addItemWithTitle:@"Volume" action:nil keyEquivalent:@""].submenu = vol;
    [k addItemWithTitle:@"Pitch" action:nil keyEquivalent:@""].submenu = pit;
    [k addItemWithTitle:@"Sound on Key Release" action:@selector(toggleRelease) keyEquivalent:@""];
    for (NSMenu *mm in @[k, vol, pit]) for (NSMenuItem *i in mm.itemArray) i.target = self;
    self.kbMenu = k;
    [self refreshKeys];
    return k;
}

- (void)refreshKeys {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    kbSwitch = (int)MIN(MAX([d integerForKey:@"kbSwitch"], 0), NSW - 1);
    kbVolume = MIN(MAX([d floatForKey:@"kbVolume"], 0), 1); kbPitch = MIN(MAX([d floatForKey:@"kbPitch"], .5f), 2);  // clamped: a bad value must not run the audio thread off a buffer
    if (!(kbPitch == kbPitch)) kbPitch = 1; if (!(kbVolume == kbVolume)) kbVolume = .5f; kbRelease = [d boolForKey:@"kbRelease"];
    for (NSMenuItem *i in self.kbMenu.itemArray) {
        BOOL on = i.action == @selector(toggleKeys) ? [d boolForKey:@"kbOn"] : i.action == @selector(pickSwitch:) ? i.tag == kbSwitch
                : i.action == @selector(toggleRelease) ? kbRelease : NO;
        i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        for (NSMenuItem *j in i.submenu.itemArray)
            j.state = j.tag == lroundf((j.action == @selector(pickVolume:) ? kbVolume : kbPitch) * 100) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)toggleKeys {
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:@"kbOn"];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"kbOn"];
    on ? [self startKeys] : [self stopKeys];
    [self refreshKeys];
}
- (void)pickSwitch:(NSMenuItem *)i {   // picking a switch means you want to type with it: turn key sounds on
    [NSUserDefaults.standardUserDefaults setInteger:i.tag forKey:@"kbSwitch"];
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"kbOn"]) { [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"kbOn"]; [self startKeys]; }
    [self refreshKeys]; [self demo];
}
- (void)pickVolume:(NSMenuItem *)i { [NSUserDefaults.standardUserDefaults setFloat:i.tag / 100.0f forKey:@"kbVolume"]; [self refreshKeys]; [self demo]; }
- (void)pickPitch:(NSMenuItem *)i { [NSUserDefaults.standardUserDefaults setFloat:i.tag / 100.0f forKey:@"kbPitch"]; [self refreshKeys]; [self demo]; }
- (void)toggleRelease { [NSUserDefaults.standardUserDefaults setBool:!kbRelease forKey:@"kbRelease"]; [self refreshKeys]; }
- (void)openPermission {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

// A few typed keys so a switch can be heard right after picking it.
- (void)demo {
    static const int keys[] = {4, 14, 37, 37, 31, 49, 13, 31, 15, 37, 2, 36};   // "hello world" + return
    for (int i = 0; i < 12; i++) {
        int kc = keys[i]; double at = i * .12 + (i % 3) * .025;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, at * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self playKey:kc up:NO]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (at + .075) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self playKey:kc up:YES]; });
    }
}

// ---- Keyboard sounds: input ----
// A listen-only event tap: it sees which key moved, never changes or blocks it, and keeps nothing. Needs Input Monitoring.
- (void)startKeys {
    if (tap) return;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
    if (CGPreflightListenEventAccess())   // without the grant a tap may still be created but hear nothing
        tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionListenOnly, mask, keyTap, (__bridge void *)self);
    if (!tap) {   // no permission yet: ask once, then retry quietly until it is granted or the feature is turned off
        self.permItem.hidden = NO;
        if (!self.permTimer) {
            CGRequestListenEventAccess();
            self.permTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { [self startKeys]; }];
        }
        return;
    }
    [self.permTimer invalidate]; self.permTimer = nil; self.permItem.hidden = YES;
    tapSrc = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSrc, kCFRunLoopCommonModes);
}

- (void)stopKeys {
    [self.permTimer invalidate]; self.permTimer = nil; self.permItem.hidden = YES;
    if (tap) {
        CGEventTapEnable(tap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSrc, kCFRunLoopCommonModes);
        CFMachPortInvalidate(tap); CFRelease(tapSrc); CFRelease(tap); tap = NULL; tapSrc = NULL;
    }
    [self.engine stop];
}

- (void)tapEvent:(CGEventType)type event:(CGEventRef)e {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) { if (tap) CGEventTapEnable(tap, true); return; }
    int kc = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    if (type == kCGEventKeyDown) { if (!CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat)) [self playKey:kc up:NO]; }
    else if (type == kCGEventKeyUp) [self playKey:kc up:YES];
    else if (type == kCGEventFlagsChanged) {   // modifiers: down or up from their own left/right bit
        CGEventFlags f = CGEventGetFlags(e), bit;
        switch (kc) {
            case 56: bit = NX_DEVICELSHIFTKEYMASK; break; case 60: bit = NX_DEVICERSHIFTKEYMASK; break;
            case 59: bit = NX_DEVICELCTLKEYMASK; break;   case 62: bit = NX_DEVICERCTLKEYMASK; break;
            case 58: bit = NX_DEVICELALTKEYMASK; break;   case 61: bit = NX_DEVICERALTKEYMASK; break;
            case 55: bit = NX_DEVICELCMDKEYMASK; break;   case 54: bit = NX_DEVICERCMDKEYMASK; break;
            case 63: bit = kCGEventFlagMaskSecondaryFn; break;
            case 57: [self playKey:kc up:NO]; return;    // caps lock only reports presses
            default: return;
        }
        [self playKey:kc up:!(f & bit)];
    }
}

// ---- Keyboard sounds: output ----
- (void)playKey:(int)kc up:(BOOL)up {
    if (up && !kbRelease) return;
    int sw = kbSwitch, kind = up ? 2 : bigKey(kc) ? 1 : 0, v = arc4random_uniform(NVAR);
    loadSwitch(sw);
    float x = (kc >= 0 && kc < 128 && keyX[kc] ? keyX[kc] : 7.25f) / 14.5f, ang = (1 + (x - .5f) * .6f) * M_PI_4;
    float keyPitch = 1 + (((uint32_t)kc * 2654435761u) >> 24) / 255.0f * .06f - .03f;   // each key a touch different, like a real board
    float inc = kbPitch * keyPitch * (kc == 49 ? .94f : 1) * (1 + (rnd() - .5f) * .04f), g = kbVolume * (.85f + .15f * rnd());
    pushVoice((Voice){bank[sw][kind][v], bankLen[sw][kind][v], 0, inc, g * cosf(ang) * (float)M_SQRT2, g * sinf(ang) * (float)M_SQRT2});
    [self wakeAudio];
}

// The audio device only runs while you type: it stops 3 min after the last key, so idle costs nothing. Not sooner:
// waking Bluetooth headphones takes long enough that the first keys after a pause would sound late.
- (void)wakeAudio {
    lastKey = CFAbsoluteTimeGetCurrent();
    if (!self.engine) {
        AVAudioEngine *e = [AVAudioEngine new];
        AVAudioFormat *f = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:SR channels:2];
        AVAudioSourceNode *src = [[AVAudioSourceNode alloc] initWithFormat:f renderBlock:
            ^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount frames, AudioBufferList *abl) { return renderVoices(silence, frames, abl); }];
        [e attachNode:src];
        [e connect:src to:e.mainMixerNode format:f];
        // Headphones plugged in or out: the engine stops itself. Drop it; the next key builds one on the new device.
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { if (self.engine && self.engine == note.object) { [self.engine stop]; self.engine = nil; } }];
        });
        self.engine = e;
    }
    if (self.engine.isRunning) return;
    // The render block is not running here, so it is safe to drop what piled up while stopped: keep only the newest key.
    for (int i = 0; i < NV; i++) voices[i].d = NULL;
    unsigned h = atomic_load(&qHead);
    if (h != atomic_load(&qTail)) atomic_store(&qTail, h - 1);
    UInt32 frames = 128;   // 2.7 ms I/O buffer instead of the default 512 (10.7 ms): the sound lands closer to the key
    AudioUnitSetProperty(self.engine.outputNode.audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, sizeof frames);
    if (![self.engine startAndReturnError:nil]) { self.engine = nil; return; }
    if (self.idle) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        if (CFAbsoluteTimeGetCurrent() - self->lastKey < 180) return;
        [self.engine stop];
        dispatch_source_cancel(self.idle); self.idle = nil;
    });
    dispatch_resume(t);
    self.idle = t;
}

- (void)toggleRec {
    if (!self.rec) {
        self.rec = [NSMutableArray array]; self.recStart = [NSDate date];
        self.recItem.title = @"Stop Recording"; self.item.button.title = @":) ●";
        [self updateSampling];
        return;
    }
    NSArray *rows = self.rec; self.rec = nil;
    self.recItem.title = @"Start Recording"; self.item.button.title = @":)";
    [self updateSampling];
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

// `iStats --render-sounds DIR`: writes every switch sound to WAV files and prints peak, length and brightness.
static int renderSounds(const char *dir) {
    AVAudioFormat *f = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:SR channels:1];
    const char *kinds[] = {"press", "big", "release"};
    int bad = 0;
    for (int s = 0; s < NSW; s++) {
        loadSwitch(s);
        for (int k = 0; k < 3; k++) {
            int len = bankLen[s][k][0]; const float *d = bank[s][k][0];
            float peak = 0; int zc = 0;
            for (int i = 0; i < len; i++) { peak = MAX(peak, fabsf(d[i])); if (i && (d[i] < 0) != (d[i - 1] < 0)) zc++; }
            printf("%-32s %-8s peak %.2f  %5.1f ms  ~%5.0f Hz\n", switches[s].name, kinds[k], peak, len * 1000.0 / SR, zc / 2.0 * SR / len);
            if (peak < .02 || peak > .99 || len < SR / 200 || len > SR / 5) bad++;
            AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:len];
            memcpy(b.floatChannelData[0], d, len * sizeof(float)); b.frameLength = len;
            NSString *p = [NSString stringWithFormat:@"%s/%02d-%s.wav", dir, s, kinds[k]];
            [[[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:p] settings:f.settings error:nil] writeFromBuffer:b error:nil];
        }
    }
    printf(bad ? "FAIL: %d sounds silent, clipped or wrong length\n" : "OK\n", bad);
    return bad != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--render-sounds")) return renderSounds(argv[2]);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;  // no Dock icon
        Stats *d = [Stats new]; app.delegate = d;
        [app run];
    }
}
