#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰 (400 增益 + 齿音穿透)
    FightMode_Old,      // 旧清晰 (600 增益 + 饱满洪亮)
    FightMode_Super     // 超级清晰 (1000 封顶增益 + 极致清晰洪亮)
} FightAudioMode;

static BOOL kForceOpenMic = YES;      // 强制开麦
static BOOL kOffSeatSpeak = NO;       // 台下直接开麦
static FightAudioMode kCurrentFightMode = FightMode_New;

static float kNewFightGain = 400.0f;
static float kOldFightGain = 600.0f;
static float kSuperFightGain = 1000.0f;
static float kVoiceGainRatio = 1.0f;

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// ---------------------- 前置函数声明 ----------------------
static void ApplyCrystalLoudVoiceDSP(id zegoApi);
static void StartKeepAliveService(void);
static UIWindow *GetKeyWindow(void);
static void TriggerOffSeatSpeak(BOOL enable);

// ---------------------- 接口声明 (严格对齐逆向报告 8.2/8.5 节) ----------------------
@interface ZegoAudioRoomApi : NSObject
@property (nonatomic, strong) id liveRoomApi; // 报告8.5确认: ZegoLiveRoomApi *liveRoomApi
- (BOOL)startPublish;
- (BOOL)startPublishWithStreamID:(NSString *)streamID;
- (void)stopPublish;
- (BOOL)startPlayStream:(NSString *)streamID;
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) ZegoAudioRoomApi *zegoEngine;
@property (nonatomic, strong) NSArray *allStreamList;
@property (nonatomic, strong) NSArray *streamList;
@property (nonatomic, strong) NSTimer *startPushTimer;  // 报告8.2确认: 推流心跳定时器
@property (nonatomic, copy) NSString *roomId;
@property (nonatomic, copy) NSString *userId;
- (void)setupENgine;
- (void)startPublishing;
- (void)stopPublishing;
- (void)muteMic:(BOOL)mute;
- (void)muteAllRemote:(BOOL)mute;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)checkAllStreams;
- (void)changeRoleToChat:(NSInteger)role;
- (void)removeStreamListAll;       // 报告4.2.2确认
- (void)saveStreamListAll:(NSArray *)streams;
- (void)onStreamUpdated:(NSUInteger)type stream:(NSArray *)streams;
@end

@interface SKAudioManager : NSObject
@property (nonatomic, strong) SKAudioZegoManager *manager;
- (void)muteMic:(BOOL)mute;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)changeRoleToChat:(NSInteger)role;
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

// ---------------------- 纯净清晰洪亮调音矩阵 ----------------------
static void ApplyCrystalLoudVoiceDSP(id zegoApi) {
    if (!zegoApi) return;

    // 强制保持扬声器开启，防止全哑
    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) {
        [zegoApi enableSpeaker:YES];
    }

    // 强制保持麦克风开启
    if ((kForceOpenMic || kOffSeatSpeak) && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

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

    // 关停 3A 压制
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 封顶纯净音量增益
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    // 极致清晰度 EQ
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            [zegoApi setAudioEqualizerGain:-12.0f index:0];
            [zegoApi setAudioEqualizerGain:-8.0f  index:1];
            [zegoApi setAudioEqualizerGain:0.0f   index:2];
            [zegoApi setAudioEqualizerGain:-8.0f  index:3];
            [zegoApi setAudioEqualizerGain:-10.0f index:4];
            [zegoApi setAudioEqualizerGain:16.0f  index:5];
            [zegoApi setAudioEqualizerGain:22.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:16.0f  index:8];
            [zegoApi setAudioEqualizerGain:10.0f  index:9];
        } else if (kCurrentFightMode == FightMode_Old) {
            [zegoApi setAudioEqualizerGain:-8.0f  index:0];
            [zegoApi setAudioEqualizerGain:-4.0f  index:1];
            [zegoApi setAudioEqualizerGain:4.0f   index:2];
            [zegoApi setAudioEqualizerGain:-4.0f  index:3];
            [zegoApi setAudioEqualizerGain:-6.0f  index:4];
            [zegoApi setAudioEqualizerGain:18.0f  index:5];
            [zegoApi setAudioEqualizerGain:24.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:18.0f  index:8];
            [zegoApi setAudioEqualizerGain:12.0f  index:9];
        } else if (kCurrentFightMode == FightMode_Super) {
            [zegoApi setAudioEqualizerGain:0.0f   index:0];
            [zegoApi setAudioEqualizerGain:4.0f   index:1];
            [zegoApi setAudioEqualizerGain:8.0f   index:2];
            [zegoApi setAudioEqualizerGain:-2.0f  index:3];
            [zegoApi setAudioEqualizerGain:-4.0f  index:4];
            [zegoApi setAudioEqualizerGain:24.0f  index:5];
            [zegoApi setAudioEqualizerGain:24.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:24.0f  index:8];
            [zegoApi setAudioEqualizerGain:20.0f  index:9];
        }
    }
}

// ---------------------- 核心：台下直接开麦与拉流防断 ----------------------
static void TriggerOffSeatSpeak(BOOL enable) {
    if (g_activeZegoManager) {
        SKAudioZegoManager *mgr = (SKAudioZegoManager *)g_activeZegoManager;
        // 强制解除下行静音
        [mgr muteAllRemote:NO];
        [mgr enableSpeaker:YES];

        if (enable) {
            [mgr muteMic:NO];
            [mgr startPublishing];
        } else {
            [mgr stopPublishing];
        }
        // 重新拉起拉流列表，确保听得到所有人
        [mgr checkAllStreams];
    }
}

// ---------------------- Hook 业务与底层 SDK ----------------------
%hook SKAudioZegoManager

- (id)init {
    id inst = %orig;
    g_activeZegoManager = inst;
    return inst;
}

- (void)setupENgine {
    %orig;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
    }
}

// 1. 拦截下麦时的角色降级（防止被服务端定时器掐断）
// v7.5.0: 彻底拦截，不调用原始方法，避免 changeRoleToChat: 内部副作用导致推流中断
- (void)changeRoleToChat:(NSInteger)role {
    if (kOffSeatSpeak) {
        return;
    }
    %orig(role);
}

// 2. 拦截静音所有远端（彻底解决听不到对方声音的问题）
- (void)muteAllRemote:(BOOL)mute {
    %orig(NO);
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic || kOffSeatSpeak) {
        %orig(NO);
    } else {
        %orig(mute);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

// 3. 拦截下麦停推指令（解决下麦后1秒被掐断的问题）
- (void)stopPublishing {
    if (kOffSeatSpeak) {
        return;
    }
    %orig;
    [self muteAllRemote:NO];
    [self checkAllStreams];
}

- (void)startPublishing {
    %orig;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
    }
    [self muteAllRemote:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

// 4. 拦截 removeStreamListAll（防止被踢时拉流列表被清空导致全哑）
- (void)removeStreamListAll {
    if (kForceOpenMic || kOffSeatSpeak) {
        // 台下开麦/强制开麦时，拒绝清空拉流列表
        return;
    }
    %orig;
}

// 4b. v7.5.0: 拦截 saveStreamListAll:（确保流列表保存后立即恢复播放）
- (void)saveStreamListAll:(NSArray *)streams {
    %orig(streams);
    if (kForceOpenMic || kOffSeatSpeak) {
        [self muteAllRemote:NO];
        [self enableSpeaker:YES];
        [self checkAllStreams];
    }
}

// 5. 远端流变动时，始终保证拉流播放
- (void)onStreamUpdated:(NSUInteger)type stream:(NSArray *)streams {
    %orig(type, streams);
    // 流更新后强制恢复拉流 + 重新开麦
    [self muteAllRemote:NO];
    [self enableSpeaker:YES];
    if (kForceOpenMic || kOffSeatSpeak) {
        [self muteMic:NO];
    }
    [self checkAllStreams];
}

// 6. 拦截 startPushTimer 的销毁（防止推流心跳被掐断）
- (void)setStartPushTimer:(NSTimer *)timer {
    if (kOffSeatSpeak && timer == nil) {
        // 台下开麦时，拒绝清除推流心跳定时器
        return;
    }
    %orig(timer);
}

%end

%hook SKAudioManager

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic || kOffSeatSpeak) {
        %orig(NO);
    } else {
        %orig(mute);
    }
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (void)changeRoleToChat:(NSInteger)role {
    if (kOffSeatSpeak) {
        return;
    }
    %orig(role);
}

%end

%hook ZegoAudioRoomApi

- (id)initWithAppID:(unsigned int)appID appSignature:(NSData *)appSignature {
    id inst = %orig;
    g_activeZegoEngine = inst;
    return inst;
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (BOOL)enableMic:(BOOL)enable {
    g_activeZegoEngine = self;
    if (kForceOpenMic || kOffSeatSpeak) return %orig(YES);
    return %orig(enable);
}

- (void)setCaptureVolume:(int)volume {
    g_activeZegoEngine = self;
    if (kCurrentFightMode != FightMode_Normal) {
        float baseGain = kNewFightGain;
        if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
        if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
        %orig((int)(baseGain * kVoiceGainRatio));
        return;
    }
    %orig(volume);
}

- (void)stopPublish {
    if (kOffSeatSpeak) {
        return;
    }
    %orig;
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
            if (g_activeZegoEngine) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([g_activeZegoEngine respondsToSelector:@selector(enableSpeaker:)]) {
                        [g_activeZegoEngine enableSpeaker:YES];
                    }
                    if (kCurrentFightMode != FightMode_Normal || kOffSeatSpeak) {
                        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
                    }
                });
            }
            // v7.5.0: 定期检查拉流列表，防止被踢后流列表被清空导致全哑
            if (g_activeZegoManager && (kForceOpenMic || kOffSeatSpeak)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SKAudioZegoManager *mgr = (SKAudioZegoManager *)g_activeZegoManager;
                    [mgr muteAllRemote:NO];
                    [mgr checkAllStreams];
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
    NSArray *items = @[@"新清晰音量 (默认400)", @"旧清晰音量 (默认600)", @"超级清晰音量 (默认1000)", @"人声音量权重"];
    for (int i = 0; i < items.count; i++) {
        CGFloat y = 8 + i * 58;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, self.debugPageView.frame.size.width - 24, 16)];
        lbl.text = items[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 18, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 500 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 800;  slider.value = kNewFightGain; }
        if (i == 1) { slider.minimumValue = 300; slider.maximumValue = 1200; slider.value = kOldFightGain; }
        if (i == 2) { slider.minimumValue = 500; slider.maximumValue = 2000; slider.value = kSuperFightGain; }
        if (i == 3) { slider.minimumValue = 0.5f; slider.maximumValue = 2.0f;  slider.value = kVoiceGainRatio; }
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
    ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
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
    ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
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
