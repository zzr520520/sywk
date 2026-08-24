#import <UIKit/UIKit.h>
#import <substrate.h>
#import <math.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰 (400 增益 + 齿音穿透)
    FightMode_Old,      // 旧清晰 (800 增益 + 饱满洪亮)
    FightMode_Super     // 震撼超级压制 (3000~5000 增益 + 广播级胸腔震撼共鸣 + 极致清晰)
} FightAudioMode;

static BOOL kForceOpenMic = YES;          // 强制开麦
static BOOL kAudioInjection = NO;         // 全局音频信号注入
static FightAudioMode kCurrentFightMode = FightMode_Super;

static float kNewFightGain = 400.0f;
static float kOldFightGain = 800.0f;
static float kSuperFightGain = 3000.0f;   // 默认超级增益提至 3000
static float kVoiceGainRatio = 1.2f;

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// ---------------------- 接口声明 (严格对齐逆向分析报告) ----------------------
@interface ZegoAudioRoomApi : NSObject
- (void)setCaptureVolume:(int)volume;
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (BOOL)enableAux:(BOOL)enable;
- (BOOL)setAuxVolume:(int)volume;
- (BOOL)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
@end

@interface ZegoAudioAux : NSObject
- (void)onAuxData:(void *)pData dataLen:(int *)pDataLen sampleRate:(int *)pSampleRate channelCount:(int *)pChannelCount;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) ZegoAudioRoomApi *zegoEngine;
@property (nonatomic, strong) ZegoAudioAux *audioAux;
@property (nonatomic, strong) NSArray *allStreamList;
- (void)muteMic:(BOOL)mute;
- (void)muteAllRemote:(BOOL)mute;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)startPublishing;
@end

// ---------------------- 广播级震撼洪亮母带调音矩阵 ----------------------
static void ApplyCrystalLoudVoiceDSP(id zegoApi) {
    if (!zegoApi) return;

    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) {
        [zegoApi enableSpeaker:YES];
    }
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
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

    // 彻底关停 3A 压制，释放无压缩动态
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            // 清晰穿透
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
            // 饱满浑厚
            [zegoApi setAudioEqualizerGain:-4.0f  index:0];
            [zegoApi setAudioEqualizerGain:8.0f   index:1];
            [zegoApi setAudioEqualizerGain:12.0f  index:2];
            [zegoApi setAudioEqualizerGain:0.0f   index:3];
            [zegoApi setAudioEqualizerGain:-2.0f  index:4];
            [zegoApi setAudioEqualizerGain:18.0f  index:5];
            [zegoApi setAudioEqualizerGain:24.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:18.0f  index:8];
            [zegoApi setAudioEqualizerGain:12.0f  index:9];
        } else if (kCurrentFightMode == FightMode_Super) {
            // 【震撼超级压制模式】：低频胸腔共鸣增强 + 核心中频力量 + 极致齿音咬字穿透
            [zegoApi setAudioEqualizerGain:6.0f   index:0]; // 31Hz 超低频微增
            [zegoApi setAudioEqualizerGain:16.0f  index:1]; // 62Hz 冲击力
            [zegoApi setAudioEqualizerGain:20.0f  index:2]; // 125Hz 胸腔厚重共鸣 (关键洪亮频段)
            [zegoApi setAudioEqualizerGain:14.0f  index:3]; // 250Hz 人声基音饱满
            [zegoApi setAudioEqualizerGain:8.0f   index:4]; // 500Hz 力量感
            [zegoApi setAudioEqualizerGain:24.0f  index:5]; // 1kHz 咬字清晰
            [zegoApi setAudioEqualizerGain:24.0f  index:6]; // 2kHz 穿透压制 (封顶)
            [zegoApi setAudioEqualizerGain:24.0f  index:7]; // 4kHz 声学掩蔽 (封顶)
            [zegoApi setAudioEqualizerGain:20.0f  index:8]; // 8kHz 泛音明亮
            [zegoApi setAudioEqualizerGain:16.0f  index:9]; // 16kHz 空气感
        }
    }
}

// ---------------------- 生成强穿透脉冲 PCM 音频数据 ----------------------
static void GeneratePulseInterferencePCM(short *buffer, int samples, int sampleRate) {
    static double phase = 0.0;
    static int pulseCounter = 0;
    double freq = 2400.0;
    double phaseInc = 2.0 * M_PI * freq / (double)sampleRate;

    pulseCounter++;
    BOOL isPulseOn = (pulseCounter % 40 < 20);

    for (int i = 0; i < samples; i++) {
        if (isPulseOn) {
            buffer[i] = (short)(sin(phase) * 28000.0);
            phase += phaseInc;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;
        } else {
            buffer[i] = 0;
        }
    }
}

// ---------------------- AUX 混音注入通道 Hook ----------------------
%hook ZegoAudioAux

- (void)onAuxData:(void *)pData dataLen:(int *)pDataLen sampleRate:(int *)pSampleRate channelCount:(int *)pChannelCount {
    if (kAudioInjection && pData && pDataLen) {
        int rate = 44100;
        int channels = 1;
        int maxBytes = *pDataLen;
        if (maxBytes <= 0) maxBytes = 2048;

        int samples = maxBytes / sizeof(short);
        short *pcmBuf = (short *)pData;
        GeneratePulseInterferencePCM(pcmBuf, samples, rate);

        if (pSampleRate) *pSampleRate = rate;
        if (pChannelCount) *pChannelCount = channels;
        *pDataLen = maxBytes;
        return;
    }
    %orig(pData, pDataLen, pSampleRate, pChannelCount);
}

%end

// ---------------------- 业务音频管理器 Hook ----------------------
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
        if ([self.zegoEngine respondsToSelector:@selector(enableAux:)]) {
            [self.zegoEngine enableAux:kAudioInjection];
            [self.zegoEngine setAuxVolume:100];
        }
    }
}

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic) {
        %orig(NO);
    } else {
        %orig(mute);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

- (void)startPublishing {
    %orig;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
        if ([self.zegoEngine respondsToSelector:@selector(enableAux:)]) {
            [self.zegoEngine enableAux:kAudioInjection];
            [self.zegoEngine setAuxVolume:100];
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

%end

%hook ZegoAudioRoomApi

- (id)initWithAppID:(unsigned int)appID appSignature:(NSData *)appSignature {
    id inst = %orig;
    g_activeZegoEngine = inst;
    return inst;
}

- (BOOL)enableMic:(BOOL)enable {
    g_activeZegoEngine = self;
    if (kForceOpenMic) return %orig(YES);
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
                    if (kCurrentFightMode != FightMode_Normal) {
                        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
                    }
                    if ([g_activeZegoEngine respondsToSelector:@selector(enableAux:)]) {
                        [g_activeZegoEngine enableAux:kAudioInjection];
                        if (kAudioInjection) {
                            [g_activeZegoEngine setAuxVolume:100];
                        }
                    }
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- 窗口获取与主面板 HUD ----------------------
static UIWindow *GetKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
}

@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;

@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swInjection;
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
        self.debugPageView.contentSize = CGSizeMake(rw, 290);
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

    NSArray *titles = @[@"强制开麦", @"全房信号注入(广播)", @"屏蔽滋啦杂音", @"新清晰效果", @"旧清晰效果", @"超级震撼压制"];
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
        if (i == 1) { self.swInjection = sw; [sw setOn:kAudioInjection]; }
        if (i == 3) self.swNewFight = sw;
        if (i == 4) self.swOldFight = sw;
        if (i == 5) { self.swSuperFight = sw; [sw setOn:YES]; } // 默认开启超级震撼压制
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"新清晰音量 (默认400)", @"旧清晰音量 (默认800)", @"超级震撼增益 (开放至5000)", @"人声动态权重 (放大至3.0)"];
    for (int i = 0; i < items.count; i++) {
        CGFloat y = 8 + i * 58;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, self.debugPageView.frame.size.width - 24, 16)];
        lbl.text = items[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 18, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 500 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 1000; slider.value = kNewFightGain; }
        if (i == 1) { slider.minimumValue = 300; slider.maximumValue = 1500; slider.value = kOldFightGain; }
        if (i == 2) { slider.minimumValue = 500; slider.maximumValue = 5000; slider.value = kSuperFightGain; } // 上限开放至 5000
        if (i == 3) { slider.minimumValue = 0.5; slider.maximumValue = 3.0;  slider.value = kVoiceGainRatio; }   // 权重上限开放至 3.0
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
    if (s == self.swInjection) {
        kAudioInjection = s.isOn;
        if (g_activeZegoEngine && [g_activeZegoEngine respondsToSelector:@selector(enableAux:)]) {
            [g_activeZegoEngine enableAux:kAudioInjection];
            if (kAudioInjection) {
                [g_activeZegoEngine setAuxVolume:100];
            }
        }
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

// ---------------------- 手势与窗口装载 ----------------------
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
    for (UIGestureRecognizer *g in window.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.delegate == self) return;
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
