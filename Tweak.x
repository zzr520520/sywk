#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰 (800 增益 + 高穿透咬字)
    FightMode_Old,      // 旧清晰 (1500 增益 + 饱满洪亮)
    FightMode_Super     // 超级清晰 (2500 极限增益 + 极致清晰洪亮)
} FightAudioMode;

static BOOL kForceOpenMic = YES;      // 强制开麦
static BOOL kOffSeatSpeak = NO;       // 台下直接开麦
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

// 极限增益控制
static float kNewFightGain = 800.0f;
static float kOldFightGain = 1500.0f;
static float kSuperFightGain = 2500.0f;
static float kVoiceGainRatio = 1.0f;

static __weak id g_activeZegoApi = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// ---------------------- 前置函数声明 ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi);
static void StartKeepAliveService(void);
static UIWindow *GetKeyWindow(void);
static void TriggerOffSeatSpeak(BOOL enable);

@interface NSObject (ZegoEnhancedSDKDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)enableMic:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag;
- (bool)stopPublishing;
@end

// 业务层类声明
@interface SKVoiceRoomManager : NSObject
+ (instancetype)shareInstance;
+ (instancetype)defaultManager;
- (void)takeSeat:(NSInteger)seatIndex;
- (void)reqUserMicroSeat:(NSInteger)index;
- (void)joinMic;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
// 注意: enableMic: 不在此声明，因 NSObject(ZegoEnhancedSDKDeclarations) 已声明 - (bool)enableMic:(bool)enable
// 此处重复声明会导致方法签名冲突编译错误
- (void)startPublish;
- (void)stopPublish;
@end

// ---------------------- 兼容 iOS 13+ 获取 keyWindow ----------------------
static UIWindow *GetKeyWindow() {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        keyWindow = w;
                        break;
                    }
                }
                if (keyWindow) break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    return keyWindow;
}

// ---------------------- 极限大音量 + 高度清晰咬字调音矩阵 (无任何背景音) ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制保持麦克风开启
    if ((kForceOpenMic || kOffSeatSpeak) && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    // 2. 正常模式恢复
    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            for (int i = 0; i < 10; i++) [zegoApi setAudioEqualizerGain:0.0f index:i];
        }
        return;
    }

    // 3. 彻底关闭 3A，释放硬件全部动态
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 4. 麦克风硬件推流增益拉满 (800 / 1500 / 2500)
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    // 5. 纯人声清晰度极致雕刻（削弱低频闷音，拉满 1k~4kHz 穿透频段）
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            // 【新清晰】：人声极致清晰、齿音透亮
            [zegoApi setAudioEqualizerGain:-12.0f index:0]; // 31Hz 切除超低频防闷
            [zegoApi setAudioEqualizerGain:-8.0f index:1];  // 62Hz 切除低频浑浊
            [zegoApi setAudioEqualizerGain:0.0f index:2];   // 125Hz 保留基础声线
            [zegoApi setAudioEqualizerGain:-6.0f index:3];  // 250Hz 消除鼻音发闷
            [zegoApi setAudioEqualizerGain:-10.0f index:4]; // 500Hz 消除空腔浑浊
            [zegoApi setAudioEqualizerGain:16.0f index:5];  // 1kHz 人声洪亮穿透
            [zegoApi setAudioEqualizerGain:22.0f index:6];  // 2kHz 人声咬字清晰度
            [zegoApi setAudioEqualizerGain:24.0f index:7];  // 4kHz 齿音极度清晰
            [zegoApi setAudioEqualizerGain:16.0f index:8];  // 8kHz 亮感
            [zegoApi setAudioEqualizerGain:10.0f index:9];  // 16kHz
        } else if (kCurrentFightMode == FightMode_Old) {
            // 【旧清晰】：饱满洪亮 + 极高清晰
            [zegoApi setAudioEqualizerGain:-8.0f index:0];
            [zegoApi setAudioEqualizerGain:-4.0f index:1];
            [zegoApi setAudioEqualizerGain:4.0f index:2];
            [zegoApi setAudioEqualizerGain:-4.0f index:3];
            [zegoApi setAudioEqualizerGain:-6.0f index:4];
            [zegoApi setAudioEqualizerGain:18.0f index:5];
            [zegoApi setAudioEqualizerGain:24.0f index:6];
            [zegoApi setAudioEqualizerGain:24.0f index:7];
            [zegoApi setAudioEqualizerGain:18.0f index:8];
            [zegoApi setAudioEqualizerGain:12.0f index:9];
        } else if (kCurrentFightMode == FightMode_Super) {
            // 【超级清晰】：全频段最大功率输出 + 清晰咬字锁定
            [zegoApi setAudioEqualizerGain:0.0f index:0];
            [zegoApi setAudioEqualizerGain:4.0f index:1];
            [zegoApi setAudioEqualizerGain:8.0f index:2];
            [zegoApi setAudioEqualizerGain:0.0f index:3];
            [zegoApi setAudioEqualizerGain:-2.0f index:4];
            [zegoApi setAudioEqualizerGain:24.0f index:5];
            [zegoApi setAudioEqualizerGain:24.0f index:6];
            [zegoApi setAudioEqualizerGain:24.0f index:7];
            [zegoApi setAudioEqualizerGain:24.0f index:8];
            [zegoApi setAudioEqualizerGain:20.0f index:9];
        }
    }
}

// ---------------------- 核心：台下直接开麦触发（业务层接口） ----------------------
static void TriggerOffSeatSpeak(BOOL enable) {
    Class audioMgrCls = NSClassFromString(@"SKAudioZegoManager");
    Class roomMgrCls = NSClassFromString(@"SKVoiceRoomManager");

    if (enable) {
        // 1. 业务层绕过麦位，强制请求发言推流
        if (audioMgrCls && [audioMgrCls respondsToSelector:@selector(sharedManager)]) {
            id audioMgr = [audioMgrCls sharedManager];
            if (audioMgr) {
                if ([audioMgr respondsToSelector:@selector(enableMic:)]) {
                    [audioMgr performSelector:@selector(enableMic:) withObject:@YES];
                }
                if ([audioMgr respondsToSelector:@selector(startPublish)]) {
                    [audioMgr performSelector:@selector(startPublish)];
                }
            }
        }

        // 2. 尝试向 1 号麦位发送虚拟绑定，走通业务推流
        if (roomMgrCls) {
            id roomMgr = nil;
            if ([roomMgrCls respondsToSelector:@selector(shareInstance)]) {
                roomMgr = [roomMgrCls shareInstance];
            } else if ([roomMgrCls respondsToSelector:@selector(defaultManager)]) {
                roomMgr = [roomMgrCls defaultManager];
            }

            if (roomMgr) {
                if ([roomMgr respondsToSelector:@selector(takeSeat:)]) [roomMgr takeSeat:1];
                if ([roomMgr respondsToSelector:@selector(reqUserMicroSeat:)]) [roomMgr reqUserMicroSeat:1];
                if ([roomMgr respondsToSelector:@selector(joinMic)]) [roomMgr joinMic];
            }
        }
    } else {
        if (audioMgrCls && [audioMgrCls respondsToSelector:@selector(sharedManager)]) {
            id audioMgr = [audioMgrCls sharedManager];
            if (audioMgr && [audioMgr respondsToSelector:@selector(stopPublish)]) {
                [audioMgr performSelector:@selector(stopPublish)];
            }
        }
    }
}

// ---------------------- Hook 业务与底层 ----------------------
%hook SKAudioRoomMicroSetting

- (BOOL)isMute {
    if (kForceOpenMic || kOffSeatSpeak) return NO;
    return %orig;
}

- (BOOL)isUserOnMic:(NSString *)uid {
    if (kOffSeatSpeak) return YES;
    return %orig;
}

%end

%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic || kOffSeatSpeak) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(g_activeZegoApi);
    });
}

- (BOOL)micEnabled {
    if (kForceOpenMic || kOffSeatSpeak) return YES;
    return %orig;
}

%end

%hook SKMicrophonePermissionManager

+ (BOOL)hasMicrophonePermission {
    if (kForceOpenMic || kOffSeatSpeak) return YES;
    return %orig;
}

%end

%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    return inst;
}

- (bool)loginRoom:(NSString *)roomID role:(int)role completionBlock:(id)block {
    return %orig;
}

- (bool)loginRoom:(NSString *)roomID roomName:(NSString *)roomName role:(int)role completionBlock:(id)block {
    return %orig;
}

- (bool)enableMic:(bool)enable {
    g_activeZegoApi = self;
    if (kForceOpenMic || kOffSeatSpeak) return %orig(YES);
    return %orig(enable);
}

- (bool)setCaptureVolume:(int)volume {
    g_activeZegoApi = self;
    if (kCurrentFightMode != FightMode_Normal) {
        float baseGain = kNewFightGain;
        if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
        if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
        return %orig((int)(baseGain * kVoiceGainRatio));
    }
    return %orig(volume);
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

%end

// ---------------------- 保活守护线程 ----------------------
static void StartKeepAliveService() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.8 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_activeZegoApi && (kCurrentFightMode != FightMode_Normal || kOffSeatSpeak)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ApplyPreciseRadioFightDSP(g_activeZegoApi);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- 主面板 HUD ----------------------
@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;
@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swOffSeatSpeak;
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

@implementation BattleMasterHUD

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];

        UIView *leftTab = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 75, frame.size.height)];
        leftTab.backgroundColor = [UIColor colorWithRed:0.75 green:0.88 blue:1.0 alpha:0.96];
        [self addSubview:leftTab];

        NSArray *tabs = @[@"功能", @"调试"];
        for (int i = 0; i < tabs.count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(5, 16 + i * 50, 65, 38);
            [btn setTitle:tabs[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor colorWithRed:0.18 green:0.38 blue:0.78 alpha:1.0] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
            btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
            btn.layer.cornerRadius = 8;
            btn.tag = 200 + i;
            [btn addTarget:self action:@selector(tabClicked:) forControlEvents:UIControlEventTouchUpInside];
            [leftTab addSubview:btn];
        }

        CGFloat rw = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIScrollView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.debugPageView.contentSize = CGSizeMake(rw, 280);
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        [self setupFuncPage];
        [self setupDebugPage];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:self.debugPageView]) return NO;
    return YES;
}

- (void)setupFuncPage {
    UILabel *proc = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, self.funcPageView.frame.size.width - 24, 20)];
    proc.text = @"选择进程: 声控物语 (活跃)";
    proc.textColor = [UIColor whiteColor];
    proc.font = [UIFont systemFontOfSize:11];
    proc.textAlignment = NSTextAlignmentCenter;
    proc.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    proc.layer.cornerRadius = 10;
    proc.clipsToBounds = YES;
    [self.funcPageView addSubview:proc];

    NSArray *titles = @[@"强制开麦", @"台下直接开麦", @"屏蔽滋啦杂音", @"新清晰效果", @"旧清晰效果", @"超级清晰效果"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 30 + i * 32, self.funcPageView.frame.size.width - 16, 28)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 5;
        [self.funcPageView addSubview:row];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 2, 120, 24)];
        lbl.text = titles[i];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 48, 0, 40, 24)];
        sw.transform = CGAffineTransformMakeScale(0.68, 0.68);
        [sw addTarget:self action:@selector(onFuncSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        if (i == 0) { self.swForceMic = sw; [sw setOn:kForceOpenMic]; }
        if (i == 1) { self.swOffSeatSpeak = sw; [sw setOn:kOffSeatSpeak]; }
        if (i == 3) { self.swNewFight = sw; [sw setOn:YES]; }
        if (i == 4) self.swOldFight = sw;
        if (i == 5) self.swSuperFight = sw;
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"新清晰音量 (默认800)", @"旧清晰音量 (默认1500)", @"超级清晰音量 (默认2500)", @"人声音量权重"];
    for (int i = 0; i < items.count; i++) {
        CGFloat y = 8 + i * 58;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, self.debugPageView.frame.size.width - 24, 16)];
        lbl.text = items[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 18, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 500 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 1500; slider.value = kNewFightGain; }
        if (i == 1) { slider.minimumValue = 500; slider.maximumValue = 2500; slider.value = kOldFightGain; }
        if (i == 2) { slider.minimumValue = 1000; slider.maximumValue = 4000; slider.value = kSuperFightGain; }
        if (i == 3) { slider.minimumValue = 0.5f; slider.maximumValue = 2.0f; slider.value = kVoiceGainRatio; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)b {
    self.funcPageView.hidden = (b.tag != 200);
    self.debugPageView.hidden = (b.tag != 201);
}

- (void)onSliderChanged:(UISlider *)s {
    if (s.tag == 500) kNewFightGain = s.value;
    if (s.tag == 501) kOldFightGain = s.value;
    if (s.tag == 502) kSuperFightGain = s.value;
    if (s.tag == 503) kVoiceGainRatio = s.value;
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)onFuncSwitch:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swOffSeatSpeak) {
        kOffSeatSpeak = s.isOn;
        TriggerOffSeatSpeak(kOffSeatSpeak);
    }
    if (s == self.swNewFight) {
        if (s.isOn) { kCurrentFightMode = FightMode_New; [self.swOldFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (s == self.swOldFight) {
        if (s.isOn) { kCurrentFightMode = FightMode_Old; [self.swNewFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (s == self.swSuperFight) {
        if (s.isOn) { kCurrentFightMode = FightMode_Super; [self.swNewFight setOn:NO animated:YES]; [self.swOldFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 双指双击手势与窗口 Hook ----------------------
static BattleMasterHUD *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

@interface HUDGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToWindow:(UIWindow *)window;
@end

@implementation HUDGestureHandler

+ (instancetype)shared {
    static HUDGestureHandler *h;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ h = [[HUDGestureHandler alloc] init]; });
    return h;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    // 去重：已存在双指双击手势则跳过
    for (UIGestureRecognizer *g in window.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]] && ((UITapGestureRecognizer *)g).numberOfTouchesRequired == 2) {
            return;
        }
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [window addGestureRecognizer:tap];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g1 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)g2 {
    return YES;
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastTapStamp < 0.45) return;
    g_lastTapStamp = now;

    UIWindow *targetWindow = GetKeyWindow();
    if (!targetWindow) return;

    if (!g_hudInstance) {
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 285, 230)];
        [targetWindow addSubview:g_hudInstance];
        return;
    }
    if (g_hudInstance.hidden || g_hudInstance.alpha < 0.1f) {
        if (g_hudInstance.superview != targetWindow) [targetWindow addSubview:g_hudInstance];
        [targetWindow bringSubviewToFront:g_hudInstance];
        g_hudInstance.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ g_hudInstance.alpha = 1.0f; }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{ g_hudInstance.alpha = 0.0f; } completion:^(BOOL f) { g_hudInstance.hidden = YES; }];
    }
}

@end

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureHandler shared] attachToWindow:self];
    StartKeepAliveService();
}
%end
