#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "utils.h"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <objc/runtime.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <sys/mman.h>
#include <stdlib.h>
#include "../litehook/src/litehook.h"
#import "Tweaks/Tweaks.h"
#include <mach-o/ldsyms.h>

extern char **environ;
static int (*appMain)(int, char**, char**);
NSUserDefaults *lcUserDefaults;
NSUserDefaults *lcSharedDefaults;
NSString *lcAppGroupPath;
NSString* lcAppUrlScheme;
NSBundle* lcMainBundle;
NSDictionary* guestAppInfo;
NSDictionary* guestContainerInfo;
NSString* lcGuestAppId;
NSString* lcLaunchURL;
bool isLiveProcess = false;
bool isSharedBundle = false;
bool isSideStore = false;
bool sideStoreExist = false;

@implementation NSUserDefaults(LiveContainer)
+ (instancetype)lcUserDefaults {
    return lcUserDefaults;
}
+ (instancetype)lcSharedDefaults {
    if(!lcUserDefaults) {
        lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    }
    return lcSharedDefaults;
}
+ (NSString *)lcAppGroupPath {
    return lcAppGroupPath;
}
+ (NSString *)lcAppUrlScheme {
    return lcAppUrlScheme;
}
+ (NSBundle *)lcMainBundle {
    return lcMainBundle;
}
+ (NSDictionary *)guestAppInfo {
    return guestAppInfo;
}

+ (NSDictionary *)guestContainerInfo {
    return guestContainerInfo;
}

+ (bool)isLiveProcess {
    return isLiveProcess;
}
+ (bool)isSharedApp {
    return isSharedBundle;
}
+ (bool)isSideStore {
    return isSideStore;
}
+ (bool)sideStoreExist {
    return sideStoreExist;
}

+ (NSString*)lcGuestAppId {
    return lcGuestAppId;
}
+ (NSString*)lcLaunchURL {
    return lcLaunchURL;
}
@end

static BOOL checkJITEnabled() {
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    return YES;
#else
    if([lcUserDefaults boolForKey:@"LCIgnoreJITOnLaunch"]) {
        return NO;
    }
    // check if jailbroken
    if (access("/usr/lib/systemhook.dylib", R_OK) == 0) {
        return YES;
    }
    
    // check csflags
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
#endif
}

static uint64_t rnd64(uint64_t v, uint64_t r) {
    r--;
    return (v + r) & ~r;
}

void overwriteMainCFBundle(void) {
    // Overwrite CFBundleGetMainBundle
    uint32_t *pc = (uint32_t *)CFBundleGetMainBundle;
    void **mainBundleAddr = 0;
    
#if !TARGET_OS_SIMULATOR
    if(@available(iOS 27.0, *)) {
        // at least in iOS 27.0 db1, the logic is inversed and the __mainBundle is right after the first tbz instruction
        while (true) {
            bool isTbz = ((*pc) & 0x7F000000) == 0x36000000;
            if (isTbz) {
                // adrp <- pc-1
                // tbz <- pc
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)(pc+1), (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
    } else {
#endif
        while (true) {
            uint64_t addr = aarch64_get_tbnz_jump_address(*pc, (uint64_t)pc);
            if (addr) {
                // adrp <- pc-1
                // tbnz <- pc
                // ...
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)addr, (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
#if !TARGET_OS_SIMULATOR
    }
#endif
    assert(mainBundleAddr != NULL);
    *mainBundleAddr = (__bridge void *)NSBundle.mainBundle._cfBundle;
}

void overwriteMainNSBundle(NSBundle *newBundle) {
    // Overwrite NSBundle.mainBundle
    // iOS 16: x19 is _MergedGlobals
    // iOS 17: x19 is _MergedGlobals+4

    NSString *oldPath = NSBundle.mainBundle.executablePath;
    uint32_t *mainBundleImpl = (uint32_t *)method_getImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)));
    for (int i = 0; i < 20; i++) {
        void **_MergedGlobals = (void **)aarch64_emulate_adrp_add(mainBundleImpl[i], mainBundleImpl[i+1], (uint64_t)&mainBundleImpl[i]);
        if (!_MergedGlobals) continue;

        // In iOS 17, adrp+add gives _MergedGlobals+4, so it uses ldur instruction instead of ldr
        if ((mainBundleImpl[i+4] & 0xFF000000) == 0xF8000000) {
            uint64_t ptr = (uint64_t)_MergedGlobals - 4;
            _MergedGlobals = (void **)ptr;
        }

        for (int mgIdx = 0; mgIdx < 20; mgIdx++) {
            if (_MergedGlobals[mgIdx] == (__bridge void *)NSBundle.mainBundle) {
                _MergedGlobals[mgIdx] = (__bridge void *)newBundle;
                break;
            }
        }
    }

    assert(![NSBundle.mainBundle.executablePath isEqualToString:oldPath]);
}

typedef struct {
    void *gap_0x0[2];                  // 0x00, 0x08
    char *mainExecutablePath_old;      // 0x10
    void *gap_0x18;                    // 0x18
    char *mainExecutablePath_18_4;     // 0x20
    size_t mainExecutablePathLen_27_0; // 0x28
} DyldConfig;
typedef struct {
    void *gap_0x0;
    DyldConfig *dyldConfig;
} DyldAPI;

int hook__NSGetExecutablePath_overwriteExecPath(DyldAPI* dyldApiInstancePtr, char* newPath, uint32_t* bufsize) {
    assert(dyldApiInstancePtr != 0);
    DyldConfig* dyldConfig = dyldApiInstancePtr->dyldConfig;
    assert(dyldConfig != 0);
    
    char** mainExecutablePathPtr = 0;
    // mainExecutablePath is at 0x10 for iOS 15~18.3.2, 0x20 for iOS 18.4+
    if(dyldConfig->mainExecutablePath_old != 0 && dyldConfig->mainExecutablePath_old[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_old);
    } else if (dyldConfig->mainExecutablePath_18_4 != 0 && dyldConfig->mainExecutablePath_18_4[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_18_4);
    } else {
        assert(mainExecutablePathPtr != 0);
    }

    kern_return_t ret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)dyldConfig, sizeof(dyldConfig), false, PROT_READ | PROT_WRITE);
    if(ret != KERN_SUCCESS) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    *mainExecutablePathPtr = newPath;
    
    // in iOS 27, the length is also cached, it's at +0x28
    if(@available(iOS 27.0, *)) {
        dyldConfig->mainExecutablePathLen_27_0 = strlen(newPath);
    }
    
    if(ret != KERN_SUCCESS) {
        os_thread_self_restrict_tpro_to_ro();
    }

    return 0;
}

void overwriteExecPath(const char *newExecPath) {
    // dyld4 stores executable path in a different place (iOS 15.0 +)
    // https://github.com/apple-oss-distributions/dyld/blob/ce1cc2088ef390df1c48a1648075bbd51c5bbc6a/dyld/DyldAPIs.cpp#L802
    int (*orig__NSGetExecutablePath)(void* dyldPtr, char* buf, uint32_t* bufsize);
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, hook__NSGetExecutablePath_overwriteExecPath);
    _NSGetExecutablePath((char*)newExecPath, NULL);
    // put the original function back
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, orig__NSGetExecutablePath);
}

static void *getAppEntryPoint(void *handle) {
    uint32_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    return (void *)header + entryoff;
}

#pragma mark - 快捷栏（游戏内「返回游戏库」）
// 形态：游戏在本进程内全屏直跑（standalone 路径），客体场景之上挂一个高层级小窗，
// 承载可四边吸附的玻璃舌与展开快捷栏。同进程内恢复宿主 UI 不可行——invokeAppMain
// 跳入客体 main 后不返回，宿主 UI 从未在本进程加载——因此回库动作沿用已真机验证的
// 自拉起机制：清掉 selected 后调用 launchToGuestAppWithClassicMode:，新启的 LC 进程
// 因 selected 已清而直接进入游戏库，客体进程随之终止（串行单开，符合既定规格）。
//
// 状态机：吸附态（玻璃舌半藏于所吸边）→ 点击展开（完整胶囊自所吸边滑出）→
// 点「游戏库」回库 / 点栏外或 3 秒无操作收回吸附态。舌与栏均可拖动，松手吸附最近边。
// 持久化：本进程的 standardUserDefaults 已被客体钩子改指到客体容器（见
// Tweaks/NSUserDefaults.m 的 NUDGuestHooksInit），不能存宿主状态；改用宿主容器内
// 显式路径的 plist（LC_HOME_PATH/Library/Preferences/LCQuickBar.plist），存所吸边、
// 沿边位置比例与回库 returning 标记，库侧 LCAppListView 读同一文件消费 returning。

typedef NS_ENUM(NSInteger, LCQuickBarEdge) {
    LCQuickBarEdgeRight = 0,
    LCQuickBarEdgeLeft = 1,
    LCQuickBarEdgeTop = 2,
    LCQuickBarEdgeBottom = 3,
};

typedef NS_ENUM(NSInteger, LCQBDirection) {
    LCQBDirectionLeft,
    LCQBDirectionRight,
    LCQBDirectionUp,
    LCQBDirectionDown,
};

// 舌全尺寸 44×76pt、约 41% 半藏（露出 26pt）；展开胶囊高 46pt、离边 12pt（下边 20pt 避指示条）。
static const CGFloat LCQBTongueThickness = 44;
static const CGFloat LCQBTongueLength = 76;
static const CGFloat LCQBTongueVisible = 26;
static const CGFloat LCQBBarHeight = 46;
static const CGFloat LCQBBarGap = 12;
static const CGFloat LCQBBarGapBottom = 20;
static const CGFloat LCQBBottomBandHalf = 90; // 下边中央禁带半宽（Home 指示条横穿区）
static const NSTimeInterval LCQBAutoCollapseDelay = 3;

#pragma mark - 状态文件

static NSString *LCQBStatePath(void) {
    const char *home = getenv("LC_HOME_PATH");
    NSString *base = home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    return [base stringByAppendingPathComponent:@"Library/Preferences/LCQuickBar.plist"];
}

static NSMutableDictionary *LCQBLoadState(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:LCQBStatePath()];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static void LCQBSaveState(NSDictionary *state) {
    NSString *path = LCQBStatePath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [state writeToFile:path atomically:YES];
}

#pragma mark - 图标绘制（与预览稿同构的白色线形图标）

static UIImage *LCQBRenderImage(CGSize size, void (^draw)(void)) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        draw();
    }];
}

// 六点握把：竖向 2 列 × 3 行，横向 3 列 × 2 行
static UIImage *LCQBGripImage(BOOL vertical) {
    CGSize size = vertical ? CGSizeMake(11, 17) : CGSizeMake(17, 11);
    return LCQBRenderImage(size, ^{
        [[UIColor colorWithWhite:1 alpha:0.55] setFill];
        CGFloat vCols[2] = {0.27, 0.73};
        CGFloat vRows[3] = {0.16, 0.5, 0.84};
        CGFloat hCols[3] = {0.16, 0.5, 0.84};
        CGFloat hRows[2] = {0.27, 0.73};
        CGFloat *colFrac = vertical ? vCols : hCols;
        CGFloat *rowFrac = vertical ? vRows : hRows;
        int cols = vertical ? 2 : 3;
        int rows = vertical ? 3 : 2;
        for (int i = 0; i < cols; i++) {
            for (int j = 0; j < rows; j++) {
                CGFloat cx = size.width * colFrac[i];
                CGFloat cy = size.height * rowFrac[j];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - 1.2, cy - 1.2, 2.4, 2.4)] fill];
            }
        }
    });
}

static UIImage *LCQBGamepadImage(void) {
    CGSize size = CGSizeMake(18, 18);
    return LCQBRenderImage(size, ^{
        CGFloat w = size.width, h = size.height;
        UIColor *ink = [UIColor colorWithWhite:1 alpha:0.92];
        [ink setStroke];
        [ink setFill];
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w * 0.05, h * 0.28, w * 0.90, h * 0.46)
                                                        cornerRadius:h * 0.23];
        body.lineWidth = 1.4;
        [body stroke];
        CGFloat cx = w * 0.30, cy = h * 0.51, a = w * 0.09;
        UIBezierPath *plus = [UIBezierPath bezierPath];
        [plus moveToPoint:CGPointMake(cx - a, cy)];
        [plus addLineToPoint:CGPointMake(cx + a, cy)];
        [plus moveToPoint:CGPointMake(cx, cy - a)];
        [plus addLineToPoint:CGPointMake(cx, cy + a)];
        plus.lineWidth = 1.4;
        [plus stroke];
        CGFloat r = w * 0.05;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.68 - r, h * 0.43 - r, 2 * r, 2 * r)] fill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.81 - r, h * 0.57 - r, 2 * r, 2 * r)] fill];
    });
}

static UIImage *LCQBChevronImage(LCQBDirection dir) {
    CGSize size = CGSizeMake(12, 12);
    return LCQBRenderImage(size, ^{
        CGFloat w = size.width, h = size.height;
        CGPoint p1, p2, p3;
        switch (dir) {
            case LCQBDirectionLeft:
                p1 = CGPointMake(w * 0.66, h * 0.16); p2 = CGPointMake(w * 0.30, h * 0.50); p3 = CGPointMake(w * 0.66, h * 0.84);
                break;
            case LCQBDirectionRight:
                p1 = CGPointMake(w * 0.34, h * 0.16); p2 = CGPointMake(w * 0.70, h * 0.50); p3 = CGPointMake(w * 0.34, h * 0.84);
                break;
            case LCQBDirectionUp:
                p1 = CGPointMake(w * 0.16, h * 0.66); p2 = CGPointMake(w * 0.50, h * 0.30); p3 = CGPointMake(w * 0.84, h * 0.66);
                break;
            case LCQBDirectionDown:
                p1 = CGPointMake(w * 0.16, h * 0.34); p2 = CGPointMake(w * 0.50, h * 0.70); p3 = CGPointMake(w * 0.84, h * 0.34);
                break;
        }
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:p1];
        [path addLineToPoint:p2];
        [path addLineToPoint:p3];
        path.lineWidth = 1.6;
        path.lineJoinStyle = kCGLineJoinRound;
        path.lineCapStyle = kCGLineCapRound;
        [[UIColor colorWithWhite:1 alpha:0.78] setStroke];
        [path stroke];
    });
}

static UIImage *LCQBHouseImage(CGFloat side, CGFloat alpha, CGFloat lineWidth) {
    return LCQBRenderImage(CGSizeMake(side, side), ^{
        CGFloat w = side, h = side;
        [[UIColor colorWithWhite:1 alpha:alpha] setStroke];
        UIBezierPath *roof = [UIBezierPath bezierPath];
        [roof moveToPoint:CGPointMake(w * 0.08, h * 0.52)];
        [roof addLineToPoint:CGPointMake(w * 0.50, h * 0.12)];
        [roof addLineToPoint:CGPointMake(w * 0.92, h * 0.52)];
        roof.lineWidth = lineWidth;
        roof.lineJoinStyle = kCGLineJoinRound;
        roof.lineCapStyle = kCGLineCapRound;
        [roof stroke];
        UIBezierPath *body = [UIBezierPath bezierPath];
        [body moveToPoint:CGPointMake(w * 0.22, h * 0.42)];
        [body addLineToPoint:CGPointMake(w * 0.22, h * 0.88)];
        [body addLineToPoint:CGPointMake(w * 0.78, h * 0.88)];
        [body addLineToPoint:CGPointMake(w * 0.78, h * 0.42)];
        body.lineWidth = lineWidth;
        body.lineJoinStyle = kCGLineJoinRound;
        body.lineCapStyle = kCGLineCapRound;
        [body stroke];
        UIBezierPath *door = [UIBezierPath bezierPath];
        [door moveToPoint:CGPointMake(w * 0.44, h * 0.88)];
        [door addLineToPoint:CGPointMake(w * 0.44, h * 0.66)];
        [door addLineToPoint:CGPointMake(w * 0.56, h * 0.66)];
        [door addLineToPoint:CGPointMake(w * 0.56, h * 0.88)];
        door.lineWidth = lineWidth;
        door.lineJoinStyle = kCGLineJoinRound;
        [door stroke];
    });
}

#pragma mark - 触摸视图（轻点/拖动判别，与游戏触摸共存）
// 手工跟踪触摸：累计位移超过 8pt 才算拖动（此前不挪位置），轻点走 onTap。
// 拖动用增量位移回调——视图随手指同移，增量天然不受视图自身移动污染。

@interface LCQBTouchView : UIView
@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onTouchBegan)(void);
@property (nonatomic, copy, nullable) void (^onDragDelta)(CGPoint delta);
@property (nonatomic, copy, nullable) void (^onDragEnded)(void);
@end

@implementation LCQBTouchView {
    CGPoint _lastPoint;
    CGFloat _travel;
    BOOL _dragging;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _lastPoint = [touches.anyObject locationInView:self];
    _travel = 0;
    _dragging = NO;
    if (self.onTouchBegan) self.onTouchBegan();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self];
    CGPoint delta = CGPointMake(p.x - _lastPoint.x, p.y - _lastPoint.y);
    _lastPoint = p;
    _travel += fabs(delta.x) + fabs(delta.y);
    if (!_dragging && _travel > 8) _dragging = YES;
    if (_dragging && self.onDragDelta) self.onDragDelta(delta);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_dragging) {
        if (self.onDragEnded) self.onDragEnded();
    } else if (self.onTap) {
        self.onTap();
    }
    _dragging = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_dragging && self.onDragEnded) self.onDragEnded();
    _dragging = NO;
}

@end

#pragma mark - 处理器

@class LCQuickBarHandler;

@interface LCQuickBarHandler : NSObject
+ (instancetype)sharedHandler;
- (void)attachToActiveSceneIfNeeded;
- (void)collapseFromOutsideTap;
- (void)relayoutForBounds:(CGRect)bounds;
@end

@interface LCQBRootView : UIView
@property (nonatomic, weak) LCQuickBarHandler *handler;
@end

@implementation LCQBRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        // 展开态下窗口全屏：点到栏外先收栏，且返回 nil 不吞这次触摸、让游戏接管。
        // 吸附态窗口只有舌大小，落到这里也只是让 collapseFromOutsideTap 空转。
        [self.handler collapseFromOutsideTap];
        return nil;
    }
    return hit;
}
@end

@interface LCQBRootViewController : UIViewController
@property (nonatomic, weak) LCQuickBarHandler *handler;
@end

@implementation LCQBRootViewController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.handler relayoutForBounds:CGRectMake(0, 0, size.width, size.height)];
    } completion:nil];
}
@end

#pragma mark - 毛玻璃容器

// 深色毛玻璃：系统暗色模糊 + rgba(20,20,24) 染色近似预览稿的 .55 压暗，
// 白 0.18 描边，阴影挂在不裁剪的外层 wrapper 上。
static UIView *LCQBMakeGlass(CGFloat cornerRadius, UIView **outContentView) {
    UIView *wrapper = [[UIView alloc] init];
    wrapper.backgroundColor = UIColor.clearColor;
    wrapper.layer.shadowColor = UIColor.blackColor.CGColor;
    wrapper.layer.shadowOpacity = 0.35;
    wrapper.layer.shadowRadius = 10;
    wrapper.layer.shadowOffset = CGSizeMake(0, 4);
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.layer.cornerRadius = cornerRadius;
    blur.layer.borderWidth = 1;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    blur.clipsToBounds = YES;
    [wrapper addSubview:blur];
    UIView *tint = [[UIView alloc] init];
    tint.backgroundColor = [UIColor colorWithRed:20.0 / 255 green:20.0 / 255 blue:24.0 / 255 alpha:0.30];
    tint.userInteractionEnabled = NO;
    [blur.contentView addSubview:tint];
    if (outContentView) *outContentView = blur.contentView;
    return wrapper;
}

@implementation LCQuickBarHandler {
    UIWindow *_window;
    LCQBRootView *_rootView;
    UIWindowScene *_scene;
    BOOL _attached;

    UIView *_tongueGlass;
    UIView *_tongueContent;
    LCQBTouchView *_tongueTouch;
    UIImageView *_gripView;
    UIImageView *_gamepadView;
    UIImageView *_chevronView;

    UIView *_barGlass;
    UIView *_barContent;
    LCQBTouchView *_barTouch;
    UIButton *_collapseButton;
    CGFloat _barWidth;

    UIWindow *_veilWindow;
    NSTimer *_collapseTimer;

    LCQuickBarEdge _edge;
    CGFloat _ratio;
    BOOL _expanded;
    BOOL _returning;
}

+ (instancetype)sharedHandler {
    static LCQuickBarHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [LCQuickBarHandler new]; });
    return handler;
}

#pragma mark 挂载

- (void)sceneDidActivate:(NSNotification *)note {
    if ([note.object isKindOfClass:UIWindowScene.class]) {
        [self attachToScene:(UIWindowScene *)note.object];
    } else {
        [self attachToActiveSceneIfNeeded];
    }
}

- (void)attachToActiveSceneIfNeeded {
    if (_attached) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            [self attachToScene:(UIWindowScene *)scene];
            return;
        }
    }
}

- (void)attachToScene:(UIWindowScene *)scene {
    if (_attached || !scene) return;
    _attached = YES;
    _scene = scene;
    [self loadPersistedState];
    [self buildViews];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    LCQBRootView *rootView = [[LCQBRootView alloc] init];
    rootView.handler = self;
    rootView.backgroundColor = UIColor.clearColor;
    LCQBRootViewController *rootVC = [LCQBRootViewController new];
    rootVC.handler = self;
    rootVC.view = rootView;
    window.rootViewController = rootVC;
    [rootView addSubview:_tongueGlass];
    [rootView addSubview:_barGlass];
    _rootView = rootView;
    _window = window;
    [self layoutForBounds:scene.coordinateSpace.bounds];
    window.hidden = NO;
    NSLog(@"[LCBootstrap][quickbar] 快捷栏已挂载（edge=%ld, ratio=%.2f）", (long)_edge, _ratio);
}

#pragma mark 视图构建

- (void)buildViews {
    __weak LCQuickBarHandler *weakSelf = self;

    // 吸附舌：触摸层在底，图标不拦截触摸、透传给触摸层
    UIView *tongueContent = nil;
    _tongueGlass = LCQBMakeGlass(15, &tongueContent);
    _tongueContent = tongueContent;
    LCQBTouchView *tongueTouch = [[LCQBTouchView alloc] init];
    tongueTouch.onTap = ^{ [weakSelf expand]; };
    tongueTouch.onDragDelta = ^(CGPoint delta) { [weakSelf dragWindowBy:delta]; };
    tongueTouch.onDragEnded = ^{ [weakSelf finishDragFromTongue]; };
    [_tongueContent addSubview:tongueTouch];
    _tongueTouch = tongueTouch;
    _gripView = [[UIImageView alloc] init];
    _gamepadView = [[UIImageView alloc] init];
    _chevronView = [[UIImageView alloc] init];
    [_tongueContent addSubview:_gripView];
    [_tongueContent addSubview:_gamepadView];
    [_tongueContent addSubview:_chevronView];

    // 展开栏：横向胶囊，横排常量与预览稿一致（pt）
    UIView *barContent = nil;
    _barGlass = LCQBMakeGlass(LCQBBarHeight / 2, &barContent);
    _barGlass.hidden = YES;
    _barContent = barContent;
    LCQBTouchView *barTouch = [[LCQBTouchView alloc] init];
    barTouch.onTouchBegan = ^{ [weakSelf resetCollapseTimer]; };
    barTouch.onTap = ^{ [weakSelf resetCollapseTimer]; };
    barTouch.onDragDelta = ^(CGPoint delta) { [weakSelf dragBarBy:delta]; };
    barTouch.onDragEnded = ^{ [weakSelf finishDragFromBar]; };
    [_barContent addSubview:barTouch];
    _barTouch = barTouch;

    UIImageView *barGrip = [[UIImageView alloc] initWithImage:LCQBGripImage(YES)];
    barGrip.frame = CGRectMake(13, (LCQBBarHeight - 17) / 2, 11, 17);
    [_barContent addSubview:barGrip];
    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(34, (LCQBBarHeight - 22) / 2, 1, 22)];
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    [_barContent addSubview:separator];

    UIFont *labelFont = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    CGFloat textWidth = ceil([@"游戏库" sizeWithAttributes:@{NSFontAttributeName: labelFont}].width);
    CGFloat pillWidth = 11 + 19 + 8 + textWidth + 13;
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.frame = CGRectMake(45, (LCQBBarHeight - 32) / 2, pillWidth, 32);
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    pill.layer.cornerRadius = 16;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    pill.clipsToBounds = YES;
    UIImageView *house = [[UIImageView alloc] initWithImage:LCQBHouseImage(19, 1.0, 1.5)];
    house.frame = CGRectMake(11, (32 - 19) / 2, 19, 19);
    [pill addSubview:house];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(11 + 19 + 8, 0, textWidth + 2, 32)];
    label.text = @"游戏库";
    label.font = labelFont;
    label.textColor = UIColor.whiteColor;
    [pill addSubview:label];
    [pill addTarget:self action:@selector(resetCollapseTimer) forControlEvents:UIControlEventTouchDown];
    [pill addTarget:self action:@selector(returnToLibrary) forControlEvents:UIControlEventTouchUpInside];
    [_barContent addSubview:pill];

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeCustom];
    collapse.frame = CGRectMake(45 + pillWidth + 8, (LCQBBarHeight - 30) / 2, 28, 30);
    [collapse addTarget:self action:@selector(collapseAnimated) forControlEvents:UIControlEventTouchUpInside];
    [_barContent addSubview:collapse];
    _collapseButton = collapse;

    _barWidth = 45 + pillWidth + 8 + 28 + 6;
}

#pragma mark 持久化

- (void)loadPersistedState {
    NSDictionary *state = LCQBLoadState();
    NSNumber *edge = state[@"edge"];
    NSNumber *ratio = state[@"ratio"];
    _edge = edge ? (LCQuickBarEdge)edge.integerValue : LCQuickBarEdgeRight;
    if (_edge < LCQuickBarEdgeRight || _edge > LCQuickBarEdgeBottom) _edge = LCQuickBarEdgeRight;
    _ratio = ratio ? ratio.doubleValue : 0.5;
    _ratio = MAX(0, MIN(1, _ratio));
}

- (void)persistState {
    NSMutableDictionary *state = LCQBLoadState();
    state[@"edge"] = @(_edge);
    state[@"ratio"] = @(_ratio);
    LCQBSaveState(state);
}

#pragma mark 几何与布局

- (BOOL)isVerticalEdge {
    return _edge == LCQuickBarEdgeLeft || _edge == LCQuickBarEdgeRight;
}

// 沿边中心点：比例换算后钳制在两角内侧；下边再避开中央 180pt 指示条禁带，落带内时滑到带外最近处
- (CGFloat)alongCenterForBounds:(CGRect)bounds {
    CGFloat axis = [self isVerticalEdge] ? bounds.size.height : bounds.size.width;
    CGFloat center = _ratio * axis;
    CGFloat half = LCQBTongueLength / 2 + 6;
    center = MAX(half, MIN(center, axis - half));
    if (_edge == LCQuickBarEdgeBottom) {
        CGFloat mid = bounds.size.width / 2;
        if (center > mid - LCQBBottomBandHalf && center < mid + LCQBBottomBandHalf) {
            center = (center < mid) ? mid - LCQBBottomBandHalf : mid + LCQBBottomBandHalf;
            center = MAX(half, MIN(center, bounds.size.width - half));
        }
    }
    return center;
}

- (CGRect)dockedFrameForBounds:(CGRect)bounds {
    CGFloat center = [self alongCenterForBounds:bounds];
    CGFloat tucked = LCQBTongueThickness - LCQBTongueVisible; // 18
    switch (_edge) {
        case LCQuickBarEdgeRight:
            return CGRectMake(bounds.size.width - LCQBTongueVisible, center - LCQBTongueLength / 2,
                              LCQBTongueThickness, LCQBTongueLength);
        case LCQuickBarEdgeLeft:
            return CGRectMake(-tucked, center - LCQBTongueLength / 2,
                              LCQBTongueThickness, LCQBTongueLength);
        case LCQuickBarEdgeTop:
            return CGRectMake(center - LCQBTongueLength / 2, -tucked,
                              LCQBTongueLength, LCQBTongueThickness);
        case LCQuickBarEdgeBottom:
            return CGRectMake(center - LCQBTongueLength / 2, bounds.size.height - LCQBTongueVisible,
                              LCQBTongueLength, LCQBTongueThickness);
    }
    return CGRectZero;
}

- (CGRect)barFrameForBounds:(CGRect)bounds {
    CGFloat center = [self alongCenterForBounds:bounds];
    CGFloat w = _barWidth, h = LCQBBarHeight;
    switch (_edge) {
        case LCQuickBarEdgeRight: {
            CGFloat y = MAX(8, MIN(center - h / 2, bounds.size.height - h - 8));
            return CGRectMake(bounds.size.width - LCQBBarGap - w, y, w, h);
        }
        case LCQuickBarEdgeLeft: {
            CGFloat y = MAX(8, MIN(center - h / 2, bounds.size.height - h - 8));
            return CGRectMake(LCQBBarGap, y, w, h);
        }
        case LCQuickBarEdgeTop: {
            CGFloat x = MAX(8, MIN(center - w / 2, bounds.size.width - w - 8));
            return CGRectMake(x, LCQBBarGap, w, h);
        }
        case LCQuickBarEdgeBottom: {
            CGFloat x = MAX(8, MIN(center - w / 2, bounds.size.width - w - 8));
            return CGRectMake(x, bounds.size.height - LCQBBarGapBottom - h, w, h);
        }
    }
    return CGRectZero;
}

- (void)sizeGlass:(UIView *)glass {
    UIVisualEffectView *blur = (UIVisualEffectView *)glass.subviews.firstObject;
    blur.frame = glass.bounds;
    blur.contentView.subviews.firstObject.frame = blur.bounds; // 染色层
}

- (void)layoutForBounds:(CGRect)bounds {
    if (!_window) return;
    if (_expanded) {
        _window.frame = bounds;
        _rootView.frame = bounds;
        _barGlass.frame = [self barFrameForBounds:bounds];
        [self sizeGlass:_barGlass];
        _barTouch.frame = _barContent.bounds;
        _tongueGlass.hidden = YES;
        _barGlass.hidden = NO;
    } else {
        CGRect frame = [self dockedFrameForBounds:bounds];
        _window.frame = frame;
        _rootView.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
        _tongueGlass.frame = _rootView.bounds;
        [self sizeGlass:_tongueGlass];
        [self layoutTongueContent];
        _tongueGlass.hidden = NO;
        _barGlass.hidden = YES;
    }
    [self refreshChevronImages];
}

- (void)relayoutForBounds:(CGRect)bounds {
    [self layoutForBounds:bounds];
}

// 舌内元素沿长轴依次排：握把 17、间 9、手柄 18、间 9、箭头 11，共 64，居中于长轴；
// 横轴对准可见带中心（贴边一侧 18pt 藏在屏外）。
- (void)layoutTongueContent {
    _tongueTouch.frame = _tongueContent.bounds;
    BOOL vertical = [self isVerticalEdge];
    CGFloat stripCenter = LCQBTongueVisible / 2;
    switch (_edge) {
        case LCQuickBarEdgeRight: stripCenter = LCQBTongueVisible / 2; break;
        case LCQuickBarEdgeLeft: stripCenter = LCQBTongueThickness - LCQBTongueVisible / 2; break;
        case LCQuickBarEdgeTop: stripCenter = LCQBTongueThickness - LCQBTongueVisible / 2; break;
        case LCQuickBarEdgeBottom: stripCenter = LCQBTongueVisible / 2; break;
    }
    _gripView.image = LCQBGripImage(vertical);
    _gamepadView.image = LCQBGamepadImage();
    CGFloat along[3] = {17, 18, 11};
    CGFloat cross[3] = {11, 18, 11};
    UIView *views[3] = {_gripView, _gamepadView, _chevronView};
    CGFloat pos = (LCQBTongueLength - 64) / 2;
    for (int i = 0; i < 3; i++) {
        if (vertical) {
            views[i].frame = CGRectMake(stripCenter - cross[i] / 2, pos, cross[i], along[i]);
        } else {
            views[i].frame = CGRectMake(pos, stripCenter - cross[i] / 2, along[i], cross[i]);
        }
        pos += along[i] + 9;
    }
}

// 吸附态箭头指向屏内（展开方向）；展开态箭头指向所吸边（收回方向）
- (void)refreshChevronImages {
    LCQBDirection dockedDir = LCQBDirectionLeft, barDir = LCQBDirectionRight;
    switch (_edge) {
        case LCQuickBarEdgeRight: dockedDir = LCQBDirectionLeft; barDir = LCQBDirectionRight; break;
        case LCQuickBarEdgeLeft: dockedDir = LCQBDirectionRight; barDir = LCQBDirectionLeft; break;
        case LCQuickBarEdgeTop: dockedDir = LCQBDirectionDown; barDir = LCQBDirectionUp; break;
        case LCQuickBarEdgeBottom: dockedDir = LCQBDirectionUp; barDir = LCQBDirectionDown; break;
    }
    _chevronView.image = LCQBChevronImage(dockedDir);
    [_collapseButton setImage:LCQBChevronImage(barDir) forState:UIControlStateNormal];
}

#pragma mark 展开/收起

- (CGAffineTransform)edgeTranslation:(CGFloat)distance {
    switch (_edge) {
        case LCQuickBarEdgeRight: return CGAffineTransformMakeTranslation(distance, 0);
        case LCQuickBarEdgeLeft: return CGAffineTransformMakeTranslation(-distance, 0);
        case LCQuickBarEdgeTop: return CGAffineTransformMakeTranslation(0, -distance);
        case LCQuickBarEdgeBottom: return CGAffineTransformMakeTranslation(0, distance);
    }
    return CGAffineTransformIdentity;
}

- (void)expand {
    if (_expanded || !_window) return;
    _expanded = YES;
    CGRect bounds = _scene.coordinateSpace.bounds;
    _window.frame = bounds;
    _rootView.frame = bounds;
    _barGlass.frame = [self barFrameForBounds:bounds];
    [self sizeGlass:_barGlass];
    _barTouch.frame = _barContent.bounds;
    [self refreshChevronImages];
    _tongueGlass.hidden = YES;
    _barGlass.hidden = NO;
    UIView *bar = _barGlass;
    bar.alpha = 0;
    bar.transform = [self edgeTranslation:28];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        bar.alpha = 1;
        bar.transform = CGAffineTransformIdentity;
    } completion:nil];
    [self resetCollapseTimer];
}

- (void)collapseAnimated {
    if (!_expanded) return;
    _expanded = NO;
    [self invalidateCollapseTimer];
    UIView *bar = _barGlass;
    CGAffineTransform slide = [self edgeTranslation:28];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        bar.alpha = 0;
        bar.transform = slide;
    } completion:^(BOOL finished) {
        bar.hidden = YES;
        bar.alpha = 1;
        bar.transform = CGAffineTransformIdentity;
        [self layoutForBounds:self->_scene.coordinateSpace.bounds];
    }];
}

- (void)collapseFromOutsideTap {
    if (_expanded) [self collapseAnimated];
}

- (void)resetCollapseTimer {
    [_collapseTimer invalidate];
    _collapseTimer = nil;
    if (!_expanded) return;
    _collapseTimer = [NSTimer scheduledTimerWithTimeInterval:LCQBAutoCollapseDelay
                                                       target:self
                                                     selector:@selector(collapseFromTimer)
                                                     userInfo:nil
                                                      repeats:NO];
}

- (void)collapseFromTimer {
    [self collapseAnimated];
}

- (void)invalidateCollapseTimer {
    [_collapseTimer invalidate];
    _collapseTimer = nil;
}

#pragma mark 拖动与吸附

- (void)dragWindowBy:(CGPoint)delta {
    CGRect frame = _window.frame;
    frame.origin.x += delta.x;
    frame.origin.y += delta.y;
    _window.frame = frame;
}

- (void)dragBarBy:(CGPoint)delta {
    CGRect frame = _barGlass.frame;
    frame.origin.x += delta.x;
    frame.origin.y += delta.y;
    _barGlass.frame = frame;
    [self resetCollapseTimer];
}

// 以给定中心点定所吸边（到四边距离最近者）与沿边比例，落盘后由调用方动画归位
- (void)snapFromCenter:(CGPoint)center inBounds:(CGRect)bounds {
    CGFloat dLeft = center.x, dRight = bounds.size.width - center.x;
    CGFloat dTop = center.y, dBottom = bounds.size.height - center.y;
    CGFloat nearest = MIN(MIN(dLeft, dRight), MIN(dTop, dBottom));
    if (nearest == dLeft) _edge = LCQuickBarEdgeLeft;
    else if (nearest == dRight) _edge = LCQuickBarEdgeRight;
    else if (nearest == dTop) _edge = LCQuickBarEdgeTop;
    else _edge = LCQuickBarEdgeBottom;
    _ratio = [self isVerticalEdge] ? center.y / bounds.size.height : center.x / bounds.size.width;
    _ratio = MAX(0, MIN(1, _ratio));
    [self persistState];
}

- (void)finishDragFromTongue {
    CGRect bounds = _scene.coordinateSpace.bounds;
    [self snapFromCenter:_window.center inBounds:bounds];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self layoutForBounds:bounds];
    } completion:nil];
}

- (void)finishDragFromBar {
    CGRect bounds = _scene.coordinateSpace.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(_barGlass.frame), CGRectGetMidY(_barGlass.frame));
    [self snapFromCenter:center inBounds:bounds];
    [self collapseAnimated];
}

#pragma mark 回库

- (void)returnToLibrary {
    if (_returning) return;
    _returning = YES;
    [self invalidateCollapseTimer];
    // returning 标记与吸附状态同文件：库侧冷启动读到后首帧盖黑、淡出时清除
    NSMutableDictionary *state = LCQBLoadState();
    state[@"edge"] = @(_edge);
    state[@"ratio"] = @(_ratio);
    state[@"returning"] = @YES;
    LCQBSaveState(state);
    [self showReturnVeil];
}

// 全屏黑遮罩：0.25s 淡入至全黑（中央白房子图标 + 「游戏库」小字），
// 全黑后再走回库原语，进程重启的接缝被盖在黑场里；库侧以同一标记接淡出。
- (void)showReturnVeil {
    CGRect bounds = _scene.coordinateSpace.bounds;
    UIWindow *veil = [[UIWindow alloc] initWithWindowScene:_scene];
    veil.windowLevel = UIWindowLevelAlert + 200;
    veil.frame = bounds;
    veil.backgroundColor = UIColor.blackColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    UIImageView *house = [[UIImageView alloc] initWithImage:LCQBHouseImage(38, 0.9, 2.2)];
    house.frame = CGRectMake((bounds.size.width - 38) / 2, (bounds.size.height - 38) / 2 - 14, 38, 38);
    [vc.view addSubview:house];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(house.frame) + 8, bounds.size.width, 18)];
    label.text = @"游戏库";
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:label];
    veil.rootViewController = vc;
    veil.alpha = 0;
    veil.hidden = NO;
    _veilWindow = veil;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        veil.alpha = 1;
    } completion:^(BOOL finished) {
        // 以下为 dock-test-3 已真机验证的回库原语，调用内容与顺序保持原样
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults synchronize];
        NSLog(@"[LCBootstrap][quickbar] 点击返回游戏库，自拉起宿主 UI");
        [LCSharedUtils launchToGuestAppWithClassicMode:0];
    }];
}

@end

static BOOL lcQuickBarInstallAttempted;

static void LCQuickBarInstall(void) {
    if (lcQuickBarInstallAttempted) return;
    lcQuickBarInstallAttempted = YES;
    // 关闭开关（默认装）
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCQuickBarDisable"]) return;
    LCQuickBarHandler *handler = [LCQuickBarHandler sharedHandler];
    [NSNotificationCenter.defaultCenter addObserver:handler
                                           selector:@selector(sceneDidActivate:)
                                               name:UISceneDidActivateNotification
                                             object:nil];
    // 兜底重试：场景可能在通知注册前已激活，或客体建场较晚
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [handler attachToActiveSceneIfNeeded];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [handler attachToActiveSceneIfNeeded];
    });
}

static NSString* invokeAppMain(NSString *selectedApp, NSString *selectedContainer, int argc, char *argv[]) {
    NSString *appError = nil;
    if([[lcUserDefaults objectForKey:@"LCWaitForDebugger"] boolValue]) {
        sleep(100);
    }
    if (!LCSharedUtils.certificatePassword && !isSideStore) {
#if !TARGET_OS_SIMULATOR
        if(@available(iOS 26.0 ,*))  {
            return @"JITLess mode is required since iOS 26. Please set it up in settings. \nPlease go to LiveContainer settings -> tap \"Import Certificate from SideStore\" / \"Import Certificate\"";
        }
#endif
        // First of all, let's check if we have JIT
        for (int i = 0; i < 10 && !checkJITEnabled(); i++) {
            usleep(1000*100);
        }
        if (!checkJITEnabled()) {
            appError = @"JIT was not enabled. If you want to use LiveContainer without JIT, setup JITLess mode in settings.";
            return appError;
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = 0;
    if(!isSideStore) {
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, selectedApp];
    } else if (isLiveProcess) {
        bundlePath = [[NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] path];
    } else {
        bundlePath = [[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] path];
    }
    

    guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];

    // not found locally, let's look for the app in shared folder
    if(!guestAppInfo) {
        NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
        appGroupFolder = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, selectedApp];
        guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];
        isSharedBundle = true;
    }
    
    if(!guestAppInfo) {
        return @"App bundle not found! Unable to read LCAppInfo.plist.";
    }
    
    if([guestAppInfo[@"doUseLCBundleId"] boolValue] ) {
        NSMutableDictionary* infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("application-identifier"), &error);
        CFRelease(taskSelf);
        if (value) {
            NSString *entStr = (__bridge NSString *)value;
            CFRelease(value);
            NSRange dotRange = [entStr rangeOfString:@"."];
            if (dotRange.location != NSNotFound) {
                NSString *expectedBundleId = [entStr substringFromIndex:dotRange.location + 1];
                if(![infoPlist[@"CFBundleIdentifier"] isEqualToString:expectedBundleId]) {
                    infoPlist[@"CFBundleIdentifier"] = expectedBundleId;
                    [infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
                }
            }
        }
    }
    
    NSBundle *appBundle = [[NSBundle alloc] initWithPathForMainBundle:bundlePath];
    
    if(!appBundle) {
        return @"App not found";
    }
    
    // find container in Info.plist
    NSString* dataUUID = selectedContainer;
    if(!dataUUID) {
        dataUUID = guestAppInfo[@"LCDataUUID"];
    }

    if(dataUUID == nil) {
        return @"Container not found!";
    }
    
    if(isLiveProcess && !isSideStore) {
        lcAppUrlScheme = [lcUserDefaults stringForKey:@"hostUrlScheme"];
        [lcUserDefaults removeObjectForKey:@"hostUrlScheme"];
    }
    
    NSError *error;

    // Setup tweak loader
    NSString *tweakFolder = nil;
    if (isSharedBundle) {
        tweakFolder = [appGroupFolder.path  stringByAppendingPathComponent:@"Tweaks"];
    } else {
        tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
    }
    setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);

    // Update TweakLoader symlink
    NSString *tweakLoaderPath = [tweakFolder stringByAppendingPathComponent:@"TweakLoader.dylib"];
    if (![fm fileExistsAtPath:tweakLoaderPath]) {
        remove(tweakLoaderPath.UTF8String);
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        if([bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) {
            // traverse back to LiveContainer.app
            bundlePath = bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        }
        NSString *target = [bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
        symlink(target.UTF8String, tweakLoaderPath.UTF8String);
    }

    // If JIT is enabled, bypass library validation so we can load arbitrary binaries
    bool isJitEnabled = checkJITEnabled();
    if (isJitEnabled) {
        init_bypassDyldLibValidation();
    }

    // Locate dyld image name address
    const char **path = _CFGetProcessPath();
    const char *oldPath = *path;
    
    // Overwrite @executable_path
    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);
    
    // Overwrite NSUserDefaults
    if([guestAppInfo[@"doUseLCBundleId"] boolValue]) {
        lcGuestAppId = guestAppInfo[@"LCOrignalBundleIdentifier"];
    } else {
        lcGuestAppId = appBundle.bundleIdentifier;
        
    }

    // Overwrite home and tmp path
    NSString *newHomePath = nil;
    NSArray<NSDictionary*>* containers = guestAppInfo[@"LCContainers"];
    NSURL* bookmarkURL = nil;

    // see if the container contains a bookmark. if so, resolve it and report error upon failure.
    if(containers && [containers isKindOfClass:NSArray.class]) {
        for(NSDictionary* container in containers){
            if(![container isKindOfClass:NSDictionary.class]) {
                continue;
            }
            if([container[@"folderName"] isEqualToString:dataUUID]) {
                NSData* bookmarkData = container[@"bookmarkData"];
                if(bookmarkData && [bookmarkData isKindOfClass:NSData.class]) {
                    // we will be killed by watchdog before timedout, so we set this error beforehand.
                    [lcUserDefaults setObject:@"Bookmark resolution timed out. Is the data storage offline?" forKey:@"error"];
                    NSError* err = nil;
                    BOOL isStale = false;
                    bookmarkURL = [NSURL URLByResolvingBookmarkData:bookmarkData options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&err];
                    bool access = [bookmarkURL startAccessingSecurityScopedResource];
                    if(!bookmarkURL || !access) {
                        return [@"Bookmark resolution failed or unable to access the container. You might need to readd the data storage. %@" stringByAppendingString:err.localizedDescription];
                    }
                    [lcUserDefaults removeObjectForKey:@"error"];
                }
                break;
            }
        }
    }
    
    if(isSideStore) {
        if(isLiveProcess) {
            newHomePath = [lcUserDefaults stringForKey:@"specifiedSideStoreContainerPath"];;
            [lcUserDefaults removeObjectForKey:@"specifiedSideStoreContainerPath"];
        } else {
            newHomePath = [docPath stringByAppendingPathComponent:@"SideStore"];
        }
    } else if (bookmarkURL) {
        newHomePath = bookmarkURL.path;
    } else if(isSharedBundle) {
        newHomePath = [NSString stringWithFormat:@"%@/Data/Application/%@", appGroupFolder.path, dataUUID];
        
    } else {
        newHomePath = [NSString stringWithFormat:@"%@/Data/Application/%@", docPath, dataUUID];
    }
    
    
    NSString *newTmpPath = [newHomePath stringByAppendingPathComponent:@"tmp"];
    remove(newTmpPath.UTF8String);
    symlink(getenv("TMPDIR"), newTmpPath.UTF8String);
    
    if([guestAppInfo[@"doSymlinkInbox"] boolValue]) {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSString* inboxPath = [newHomePath stringByAppendingPathComponent:@"Inbox"];
        
        if (![fm fileExistsAtPath:inboxPath]) {
            [fm createDirectoryAtPath:inboxPath withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if([fm fileExistsAtPath:inboxSymlinkPath]) {
            NSString* fileType = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error][NSFileType];
            if(fileType == NSFileTypeDirectory) {
                NSArray* contents = [fm contentsOfDirectoryAtPath:inboxSymlinkPath error:&error];
                for(NSString* content in contents) {
                    [fm moveItemAtPath:[inboxSymlinkPath stringByAppendingPathComponent:content] toPath:[inboxPath stringByAppendingPathComponent:content] error:&error];
                }
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }
        

        symlink(inboxPath.UTF8String, inboxSymlinkPath.UTF8String);
    } else {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSDictionary* targetAttribute = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error];
        if(targetAttribute) {
            if(targetAttribute[NSFileType] == NSFileTypeSymbolicLink) {
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }

    }
    
    setenv("CFFIXED_USER_HOME", newHomePath.UTF8String, 1);
    setenv("HOME", newHomePath.UTF8String, 1);
    // we don't change TMP's env in case some apps clear cache by directly deleting the tmp folder,
    // which if symlinked, the new tmp cannot be recreated (#1040, #1125) or the app may camplain about the tmp folder being a symlimk (#884)

    // Setup directories
    NSArray *dirList = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData"];
    for (NSString *dir in dirList) {
        NSString *dirPath = [newHomePath stringByAppendingPathComponent:dir];
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString* containerInfoPath = [newHomePath stringByAppendingPathComponent:@"LCContainerInfo.plist"];
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    
    [LCSharedUtils setContainerUsingByLC:lcAppUrlScheme folderName:dataUUID auditToken:0];

    // Overwrite NSBundle
    overwriteMainNSBundle(appBundle);

    // Overwrite CFBundle
    overwriteMainCFBundle();

    // Overwrite executable info
    if(!appBundle.executablePath) {
        return @"App's executable path not found. Please try force re-signing or reinstalling this app.";
    }

    NSMutableArray<NSString *> *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo performSelector:@selector(setArguments:) withObject:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }
    
    // hook NSUserDefault before running libraries' initializers
    NUDGuestHooksInit();
    if(!isSideStore) {
        SecItemGuestHooksInit();
        NSFMGuestHooksInit();
        initDead10ccFix();
    }
    if(isLiveProcess) {
        NSURLSCGuestHooksInit();
    }
    // ignore setting handler from guest app
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, NSSetUncaughtExceptionHandler, hook_do_nothing, nil);
    
    BOOL hookDlopen = !isSideStore && !isSharedBundle && LCSharedUtils.certificatePassword && isLiveProcess;
    DyldHooksInit([guestAppInfo[@"hideLiveContainer"] boolValue], hookDlopen, [guestAppInfo[@"spoofSDKVersion"] unsignedIntValue]);
    
    if([guestContainerInfo[@"spoofIdentifierForVendor"] boolValue]) {
        NSString* idForVendorStr = guestContainerInfo[@"spoofedIdentifierForVendor"];
        if([idForVendorStr isKindOfClass:NSString.class]) {
            NSUUID* idForVendorUUID = [[NSUUID UUID] initWithUUIDString:idForVendorStr];
            if(idForVendorUUID) {
                IDFVHookInit(idForVendorUUID);
            }
        }
    }
    
    bool is32bit = [guestAppInfo[@"is32bit"] boolValue];
    if(is32bit) {
        [lcUserDefaults removeObjectForKey:@"LC32BitTranslationLayerLogFile"];
        if (!isJitEnabled) {
            return @"JIT is required to run 32-bit apps.";
        }
        
        NSString *selected32BitLayer = guestAppInfo[@"selected32BitEmulator"] ?: [lcSharedDefaults stringForKey:@"LCSelected32BitEmulator"];
        if(selected32BitLayer.length == 0) {
            appError = @"No 32-bit emulator selected";
            NSLog(@"[LCBootstrap] %@", appError);
            *path = oldPath;
            return appError;
        }
        NSBundle *selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Applications/%@", docPath, selected32BitLayer]];
        if(!selected32bitLayerBundle) {
            selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, selected32BitLayer]];
        }
        if(!selected32bitLayerBundle) {
            appError = @"The specified 32-bit emulator app is not found";
            NSLog(@"[LCBootstrap] %@", appError);
            *path = oldPath;
            return appError;
        }
        // maybe need to save selected32bitLayerBundle to static variable?
        appExecPath = strdup(selected32bitLayerBundle.executablePath.UTF8String);
        overwriteExecPath(appExecPath);
    }
    if(![guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        tweakLoaderLoaded = true;
    }
    
    // Preload executable to bypass RT_NOLOAD
    appMainImageIndex = _dyld_image_count();
    __block void *appHandle = 0;
    void (^dlopenBlock)(void) = ^{
        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
    };
    
    BOOL is27up = false;
    if(@available(iOS 27, *)) { is27up = true; }
    if(is27up && [guestAppInfo[@"segCountMismatch"] boolValue]) {
        bypass_seg_count_check(dlopenBlock);
    } else {
        dlopenBlock();
    }

    appExecutableHandle = appHandle;
    const char *dlerr = dlerror();
    
    if (!appHandle || (uint64_t)appHandle > 0xf00000000000) {
        if (dlerr) {
            appError = @(dlerr);
        } else {
            appError = @"dlopen: an unknown error occurred";
        }
        NSLog(@"[LCBootstrap] %@", appError);
        *path = oldPath;
        return appError;
    }
    
    if([guestAppInfo[@"dontInjectTweakLoader"] boolValue] && ![guestAppInfo[@"dontLoadTweakLoader"] boolValue]) {
        tweakLoaderLoaded = true;
        if([guestAppInfo[@"hideLiveContainer"] boolValue]) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"].UTF8String, RTLD_LAZY|RTLD_GLOBAL);
        } else {
            dlopen("@loader_path/../TweakLoader.dylib", RTLD_LAZY|RTLD_GLOBAL);
        }
    }
    
    if(isSideStore) {
        tweakLoaderLoaded = true;
        dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"].UTF8String, RTLD_LAZY|RTLD_GLOBAL);
    }
    
    if(sideStoreExist) {
        if (!isLiveProcess && (isSideStore || ![guestAppInfo[@"dontInjectTweakLoader"] boolValue])) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework/SideStoreSupport"].UTF8String, RTLD_LAZY);
        } else if (isLiveProcess && isSideStore) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"../../Frameworks/SideStoreSupport.framework/SideStoreSupport"].UTF8String, RTLD_LAZY);
        }
    }
    
    // Fix dynamic properties of some apps
    [NSUserDefaults performSelector:@selector(initialize)];

    // Attempt to load the bundle. 32-bit bundle will always fail because of 32-bit main executable, so ignore it
    if (!is32bit && ![appBundle loadAndReturnError:&error]) {
        appError = error.localizedDescription;
        NSLog(@"[LCBootstrap] loading bundle failed: %@", error);
        *path = oldPath;
        return appError;
    }
    NSLog(@"[LCBootstrap] loaded bundle");

    // Find main()
    appMain = getAppEntryPoint(appHandle);
    if (!appMain) {
        appError = @"Could not find the main entry point";
        NSLog(@"[LCBootstrap] %@", appError);
        *path = oldPath;
        return appError;
    }

    // standalone 进程内直跑：跳客体 main 前预置快捷栏（回游戏库）。
    // 多任务 LiveProcess 路径不装（快捷栏是进程内直跑形态的一部分）。
    if (!isLiveProcess) {
        LCQuickBarInstall();
    }

    // Go!
    NSLog(@"[LCBootstrap] jumping to main %p", appMain);
    int ret;
    if(!is32bit) {
        argv[0] = (char *)appExecPath;
        ret = appMain(argc, argv, environ);
    } else {
        char *argv32[] = {(char*)appExecPath, (char*)*path, NULL};
        ret = appMain(sizeof(argv32)/sizeof(*argv32) - 1, argv32, environ);
    }
    return [NSString stringWithFormat:@"App returned from its main function with code %d.", ret];
}

static void exceptionHandler(NSException *exception) {
    NSString *error = [NSString stringWithFormat:@"%@\nCall stack: %@", exception.reason, exception.callStackSymbols];
    if(isLiveProcess) {
        NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
        [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: error}]];
    } else {
        [lcUserDefaults setObject:error forKey:@"error"];
    }
}

int LiveContainerMain(int argc, char *argv[]) {
    lcMainBundle = [NSBundle mainBundle];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    isLiveProcess = [lcAppUrlScheme isEqualToString:@"liveprocess"];
    setenv("LC_HOME_PATH", getenv("HOME"), 0);

    NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];
    NSString *selectedContainer = [lcUserDefaults stringForKey:@"selectedContainer"];
    NSString *launchUrl = nil;
    do {
        if(selectedApp) {
            launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
            break;
        }
        // check launch task in shared defaults
        NSString* scheemFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionScheme"];
        if(![scheemFromLaunchExtension isEqualToString:lcAppUrlScheme]) break;
        NSString* selectedAppFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionBundleID"];
        if(!selectedAppFromLaunchExtension) break;
        NSDate* launchDate = [lcSharedDefaults objectForKey:@"LCLaunchExtensionLaunchDate"];
        NSTimeInterval secondsSinceDate = [launchDate timeIntervalSinceNow];
        if (secondsSinceDate >= 0 || secondsSinceDate < -3.0) break;
        
        selectedApp = selectedAppFromLaunchExtension;
        selectedContainer = [lcSharedDefaults stringForKey:@"LCLaunchExtensionContainerName"];
        launchUrl = [lcSharedDefaults stringForKey:@"LCLaunchExtensionLaunchURL"];
        
        [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionBundleID"];
        if (selectedContainer) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionContainerName"];
        if (launchUrl) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionLaunchURL"];
    } while (0);
    
    NSString* lastLaunchDataUUID;
    if(!isLiveProcess) {
        lastLaunchDataUUID = [lcUserDefaults objectForKey:@"lastLaunchDataUUID"];
    } else {
        lastLaunchDataUUID = selectedContainer;
    }
    
    // we put all files in app group after fixing 0xdead10cc. This call is here in case user upgraded lc with app's data in private Library/SharedDocuments
    [LCSharedUtils moveSharedAppFolderBack];
    
    if(lastLaunchDataUUID) {
        NSString* lastLaunchType = [lcUserDefaults objectForKey:@"lastLaunchType"];
        NSString* preferencesTo;
        if([lastLaunchType isEqualToString:@"Shared"]) {
            preferencesTo = [LCSharedUtils.appGroupPath.path stringByAppendingPathComponent:[NSString stringWithFormat:@"LiveContainer/Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        } else {
            NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
            preferencesTo = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        }
        // recover preferences
        // this is not needed anymore, it's here for backward competability
        [LCSharedUtils dumpPreferenceToPath:preferencesTo dataUUID:lastLaunchDataUUID];
        if(!isLiveProcess) {
            [lcUserDefaults removeObjectForKey:@"lastLaunchDataUUID"];
            [lcUserDefaults removeObjectForKey:@"lastLaunchType"];
        }
    }
    // in case some weird apps remove the tmp folder
    [NSFileManager.defaultManager createDirectoryAtPath:@(getenv("TMPDIR")) withIntermediateDirectories:YES attributes:nil error:nil];
    
    if([selectedApp isEqualToString:@"ui"]) {
        selectedApp = nil;
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    }
    
    if(isLiveProcess) {
        sideStoreExist = [NSFileManager.defaultManager fileExistsAtPath:[lcMainBundle.bundlePath stringByAppendingPathComponent:@"../../Frameworks/SideStoreApp.framework"]];
    } else {
        sideStoreExist = [NSFileManager.defaultManager fileExistsAtPath:[lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"]];
    }

    if([lcUserDefaults boolForKey:@"LCOpenSideStore"] || [selectedApp isEqualToString:@"builtinSideStore"]) {
        if(sideStoreExist) {
            isSideStore = true;
        } else {
            [lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        }
    }
    
    if(selectedApp && !isSideStore && !selectedContainer) {
        selectedContainer = [LCSharedUtils findDefaultContainerWithBundleId:selectedApp];
    }
    NSString* runningLC = [LCSharedUtils getContainerUsingLCSchemeWithFolderName:selectedContainer];
    // if another instance is running, we just switch to that one, these should be called after uiapplication initialized
    // however if the running lc is liveprocess and current lc is livecontainer1 we just continue
    if(selectedApp && runningLC) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        
        if([runningLC hasSuffix:@"liveprocess"]) {
            runningLC = runningLC.stringByDeletingPathExtension;
        }
        
        NSString* selectedAppBackUp = selectedApp;
        selectedApp = nil;
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            // Base64 encode the data
            NSString* urlStr;
            if(selectedContainer) {
                urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, selectedAppBackUp, selectedContainer];
            } else {
                urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@", runningLC, selectedAppBackUp];
            }
            
            NSURL* url = [NSURL URLWithString:urlStr];
            if([[NSClassFromString(@"UIApplication") sharedApplication] canOpenURL:url]){
                [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];
                
                NSString *launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
                // also pass url scheme to another lc
                if(launchUrl) {
                    [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];

                    // Base64 encode the data
                    NSData *data = [launchUrl dataUsingEncoding:NSUTF8StringEncoding];
                    NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
                    
                    NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", runningLC, encodedUrl];
                    NSURL* url = [NSURL URLWithString: finalUrl];
                    
                    [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];

                }
            }
        });

    }
    NSSetUncaughtExceptionHandler(&exceptionHandler);
    if (selectedApp || isSideStore) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        if(launchUrl) {
            lcLaunchURL = launchUrl;
            [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        }
        NSString *appError = invokeAppMain(selectedApp, selectedContainer, argc, argv);
        if (appError) {
            if(isLiveProcess) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
                    [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: appError}]];
                    exit(1);
                });
                // spin and wait for iOS to terminate
                CFRunLoopRun();
            } else {
                [lcUserDefaults setObject:appError forKey:@"error"];
                // potentially unrecovable state, exit now
                return 1;
            }
        }
    }
    
    if(isLiveProcess) {
        NSLog(@"LiveProcess should not launch lcui!");
        return 0;
    }
    
    // put back cookies
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *libraryURL = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;;
    NSURL *cookies2URL = [libraryURL URLByAppendingPathComponent:@"Cookies2"];
    
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:cookies2URL.path isDirectory:&isDir] && isDir) {
        NSError *error = nil;
        NSURL *cookiesURL  = [libraryURL URLByAppendingPathComponent:@"Cookies"];
        // Remove old Caches folder if exists
        if ([fm fileExistsAtPath:cookiesURL.path]) {
            if ([fm removeItemAtURL:cookiesURL error:&error]) {
                [fm moveItemAtURL:cookies2URL toURL:cookiesURL error:&error];
            } else{
                NSLog(@"Failed to remove old Cookies folder: %@", error);
            }
        }
    }
    
    void *LiveContainerSwiftUIHandle = dlopen("@executable_path/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI", RTLD_LAZY);
    NSCAssert(LiveContainerSwiftUIHandle, @"%s", dlerror());
    
    if(sideStoreExist) {
        void* sideStoreHandle = dlopen("@executable_path/Frameworks/SideStoreSupport.framework/SideStoreSupport", RTLD_LAZY);
    }

    if ([lcUserDefaults boolForKey:@"LCLoadTweaksToSelf"]) {
        NSString *tweakFolder = nil;
        if (isSharedBundle) {
            NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
            tweakFolder = [appGroupPath.path stringByAppendingPathComponent:@"LiveContainer/Tweaks"];
        } else {
            NSString *docPath = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject.path;
            tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
        }
        setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
        extern void DyldHookLoadableIntoProcess(void);
        DyldHookLoadableIntoProcess();
#endif
        dlopen("@executable_path/Frameworks/TweakLoader.dylib", RTLD_LAZY);
    }

    int (*LiveContainerSwiftUIMain)(void) = dlsym(LiveContainerSwiftUIHandle, "main");
    return LiveContainerSwiftUIMain();

}

#ifdef DEBUG
int callAppMain(int argc, char *argv[], char *envp[]) {
    assert(appMain != NULL);
    __attribute__((musttail)) return appMain(argc, argv, envp);
}
#endif
