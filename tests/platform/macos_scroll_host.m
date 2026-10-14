// Runs the real AppKit host's delivery and raster-cache contracts without a window.
#import "../../src/platform/macos/appkit_host.m"

// Update verification is supplied by Zig in apps and is not exercised here.
native_sdk_update_verify_result_t native_sdk_update_verify_feed(
    const char *a, size_t b, const char *c, size_t d, const char *e, size_t f,
    const char *g, size_t h, const char *i, size_t j, char *k, size_t l,
    char *m, size_t n, char *o, size_t p) { abort(); }
int native_sdk_update_verify_archive(const char *a, size_t b, uint64_t c, const char *d, size_t e) { abort(); }

static NSUInteger failures;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

@interface ScrollTestHost : NativeSdkAppKitHost
@property NSUInteger offsets;
@property double offsetY;
@property NSUInteger focusActions;
@property NSUInteger inputs;
@property int inputKind;
@property double inputX;
@property double inputY;
@property uint32_t inputModifiers;
@end
@implementation ScrollTestHost
- (void)emitEvent:(native_sdk_appkit_event_t)event {
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT) {
        self.inputs++; self.inputKind = event.input_kind;
        self.inputX = event.delta_x; self.inputY = event.delta_y;
        self.inputModifiers = event.shortcut_modifiers;
    }
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION && event.widget_action == NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS) self.focusActions++;
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_SCROLL_DRIVER) { self.offsets++; self.offsetY = event.scroll_driver_offset_y; }
}
@end

@interface ScrollTestSurface : NativeSdkMetalSurfaceView
@property NSUInteger frames;
@end
@implementation ScrollTestSurface
- (void)renderFrame {}
- (void)updateDrawableSize {}
- (BOOL)isAvailable { return YES; }
- (void)emitFrameEventWithFrameIndex:(NSUInteger)index sampleColor:(uint32_t)color nonblank:(BOOL)nonblank occluded:(BOOL)occluded { self.frames++; }
@end

@interface ScrollSourceEvent : NSEvent
@property BOOL precise;
@property NSEventModifierFlags testModifiers;
@end
@implementation ScrollSourceEvent
- (BOOL)hasPreciseScrollingDeltas { return self.precise; }
- (NSEventModifierFlags)modifierFlags { return self.testModifiers; }
@end

static void testScrollSourceCoalescing(void) {
    ScrollTestHost *host = [ScrollTestHost new];
    ScrollTestSurface *surface = [[ScrollTestSurface alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    [surface stopDisplayTimer];
    surface.host = host;
    surface.surfaceLabel = @"timeline";
    ScrollSourceEvent *smooth = [ScrollSourceEvent new];
    smooth.precise = YES;
    ScrollSourceEvent *wheel = [ScrollSourceEvent new];
    wheel.precise = NO;
    [surface queueScrollInputEvent:smooth atPoint:NSMakePoint(20, 30) deltaX:6 deltaY:-2];
    [surface queueScrollInputEvent:smooth atPoint:NSMakePoint(20, 30) deltaX:6 deltaY:-2];
    CHECK(host.inputs == 0, "smooth samples remain frame-coalesced");
    [surface queueScrollInputEvent:wheel atPoint:NSMakePoint(20, 30) deltaX:0 deltaY:40];
    CHECK(host.inputs == 1 && host.inputKind == NATIVE_SDK_APPKIT_GPU_INPUT_SCROLL, "switching to a wheel flushes the smooth batch first");
    CHECK(host.inputX == 12 && host.inputY == -4, "both smooth axes survive coalescing");
    wheel.testModifiers = NSEventModifierFlagShift;
    [surface queueScrollInputEvent:wheel atPoint:NSMakePoint(20, 30) deltaX:0 deltaY:40];
    CHECK(host.inputs == 2 && host.inputKind == NATIVE_SDK_APPKIT_GPU_INPUT_DETENTED_SCROLL && host.inputY == 40, "modifier changes flush the previous wheel batch");
    CHECK(host.inputModifiers == 0, "the previous wheel keeps its original modifiers");
    [surface emitQueuedScrollInputEvent];
    CHECK(host.inputs == 3 && host.inputKind == NATIVE_SDK_APPKIT_GPU_INPUT_DETENTED_SCROLL, "wheel classification reaches the raw event");
    CHECK(host.inputModifiers != 0 && host.inputY == 40, "the shifted wheel remains separate");
    [surface queueScrollInputEvent:smooth atPoint:NSMakePoint(20, 30) deltaX:0.75 deltaY:-0.25];
    [surface emitQueuedScrollInputEvent];
    CHECK(host.inputKind == NATIVE_SDK_APPKIT_GPU_INPUT_SCROLL && host.inputX == 0.75, "fractional momentum stays smooth after a wheel event");
}

static void testAccessibilityFocusPublication(void) {
    ScrollTestHost *host = [ScrollTestHost new];
    ScrollTestSurface *surface = [[ScrollTestSurface alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    [surface stopDisplayTimer];
    surface.host = host;
    surface.surfaceLabel = @"menu";
    native_sdk_appkit_widget_accessibility_node_t node = {0};
    node.id = 7;
    node.role = NATIVE_SDK_APPKIT_WIDGET_ROLE_BUTTON;
    node.state_flags = NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED | NATIVE_SDK_APPKIT_WIDGET_STATE_FOCUSED;
    node.action_flags = NATIVE_SDK_APPKIT_WIDGET_ACTION_FOCUS;
    node.width = 100;
    node.height = 24;
    for (NSUInteger i = 0; i < 20; i++) [surface updateWidgetAccessibilityWithNodes:&node count:1];
    CHECK(host.focusActions == 0, "publishing focused semantics must never dispatch focus back into the runtime");
    NativeSdkWidgetAccessibilityElement *element = (NativeSdkWidgetAccessibilityElement *)surface.widgetAccessibilityElements.firstObject;
    CHECK(element.accessibilityFocused, "published focus must remain visible to assistive clients");
    const NSUInteger before = host.focusActions;
    [element setAccessibilityFocused:YES];
    CHECK(host.focusActions == before + 1, "an assistive client's focus write must still dispatch exactly once");
    [element setAccessibilityFocused:NO];
    CHECK(host.focusActions == before + 1, "clearing the snapshot focus must not request focus");
}

static void testTrackingDelivery(void) {
    ScrollTestHost *host = [ScrollTestHost new];
    ScrollTestSurface *surface = [[ScrollTestSurface alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    [surface stopDisplayTimer];
    surface.host = host;
    surface.surfaceLabel = @"test";
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // AppKit can enter a nested tracking loop from a main-queue callback.
        // The pending offset and frame must arrive BEFORE tracking returns.
        [surface queueScrollDriverEventWithId:1 offsetX:0 offsetY:40];
        [surface queueScrollDriverEventWithId:1 offsetX:0 offsetY:90];
        [surface scheduleFrameEventEmission];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.05];
        while ([deadline timeIntervalSinceNow] > 0 && (host.offsets == 0 || surface.frames == 0)) {
            [[NSRunLoop mainRunLoop] runMode:NSEventTrackingRunLoopMode beforeDate:deadline];
        }
        CHECK(host.offsets == 1, "scroll offset must deliver inside nested AppKit tracking");
        CHECK(host.offsetY == 90, "coalesced scroll must deliver the latest offset");
        CHECK(surface.frames == 1, "render frame must deliver inside nested AppKit tracking");
        finished = YES;
    });
    while (!finished) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}

static NSDictionary *scrollCommand(CGFloat y, CGFloat clipY, CGFloat opacity) {
    return @{@"kind": @"fill_rect_solid", @"bounds": @[@40, @(y), @60, @20],
        @"shape": @{@"kind": @"rect", @"rect": @[@40, @(y), @60, @20]},
        @"paint": @{@"kind": @"color", @"color": @[@1, @0, @0, @1]},
        @"opacity": @(opacity), @"clip": @[@20, @(clipY), @150, @150],
        @"clipRadius": @[@8, @8, @8, @8]};
}
static void testTranslatedRasterPixels(void) {
    ScrollTestSurface *surface = [[ScrollTestSurface alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    [surface stopDisplayTimer];
    surface.canvasColorSpace = CGColorSpaceCreateDeviceRGB();
    NSDictionary *oldCommand = scrollCommand(60, 20, 1);
    NSDictionary *newCommand = scrollCommand(50, 10, 1);
    NativeSdkPacketCommandRaster *entry = [surface rasterCacheBuildEntryForCommand:oldCommand kind:oldCommand[@"kind"] scale:2 pixelWidth:600 pixelHeight:600];
    NativeSdkPacketCommandRaster *reference = [surface rasterCacheBuildEntryForCommand:newCommand kind:newCommand[@"kind"] scale:2 pixelWidth:600 pixelHeight:600];
    CHECK(entry.image && reference.image, "scroll fixtures must produce real raster images");
    CHECK(NativeSdkPacketRetargetRasterForTranslation(entry, newCommand, 2, 600, 600), "translated raster should be retained");
    CHECK(NSEqualRects(entry.destination, reference.destination), "cached pixels must land at the full redraw destination");
    if (entry.image && reference.image) {
        NSData *cached = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(entry.image)));
        NSData *redrawn = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(reference.image)));
        CHECK([cached isEqualToData:redrawn], "translated clip reuse must match a fresh raster byte-for-byte");
    }
}

static void testTranslatedRoundedClip(void) {
    NativeSdkPacketCommandRaster *entry = [NativeSdkPacketCommandRaster new];
    entry.command = scrollCommand(60, 20, 1);
    entry.destination = NSMakeRect(39.5, 59.5, 61, 21);
    CHECK(NativeSdkPacketRetargetRasterForTranslation(entry, scrollCommand(50, 10, 1), 2, 600, 600), "content and rounded clip moving together must retain their raster");
    CHECK(fabs(entry.destination.origin.y - 49.5) < 0.001, "reused raster must follow scroll offset");
    CHECK(!NativeSdkPacketRetargetRasterForTranslation(entry, scrollCommand(40, 0, 0.5), 2, 600, 600), "changed paint opacity must invalidate raster");
    entry.command = scrollCommand(60, 20, 1);
    CHECK(NativeSdkPacketRetargetRasterForTranslation(entry, scrollCommand(50, 20, 1), 2, 600, 600), "content inside a fixed rounded clip must retain its raster");
    entry.command = scrollCommand(60, 20, 1);
    CHECK(!NativeSdkPacketRetargetRasterForTranslation(entry, scrollCommand(-5, -45, 1), 2, 600, 600), "surface-clipped pixels must be rasterized at the new position");
    // A fixed mask cutting a new part of the shape cannot reuse masked pixels.
    entry.command = scrollCommand(25, 20, 1);
    CHECK(!NativeSdkPacketRetargetRasterForTranslation(entry, scrollCommand(21, 20, 1), 2, 600, 600), "scroll across a fixed rounded corner must rerasterize");
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        testScrollSourceCoalescing();
        testAccessibilityFocusPublication();
        testTrackingDelivery();
        testTranslatedRoundedClip();
        testTranslatedRasterPixels();
        fprintf(stderr, "%lu failures\n", (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
