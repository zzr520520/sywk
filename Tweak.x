#import <UIKit/UIKit.h>
#import <substrate.h>

typedef enum : NSUInteger {
    AudioMode_Normal = 0,
    AudioMode_NewFight,   // 新清晰搏击（高频撕裂+清晰破音）
    AudioMode_OldFight,   // 旧清晰搏击（重低音轰炸+胸腔过载）
    AudioMode_SuperFight  // 超级战斗（全频段极限过载压制）
} AudioFightMode;

static BOOL kForceOpenMic = NO;
static BOOL kDoubleVoice = NO;
static AudioFightMode kCurrentMode = AudioMode_NewFight;

static float kDebugGain = 400.0f;
static float kDebugBassGain = 12.0f;
static float kDebugClarityGain = 12.0f;

static __weak id g_activeZegoApi = nil;
static dispatch_source_t g_keepAliveTimer = nil;

@interface NSObject (ZegoDeepDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableMic:(bool)enable;
- (bool)enableReverb:(bool)enable;
- (bool)setReverbPreset:(int)preset;
@end

// ---------------------- 核心激进化调音矩阵 ----------------------
static void ForceApplyBattleAudio(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦保活
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    // 2. 双音效果
    if (kDoubleVoice) {
        if ([zegoApi respondsToSelector:@selector(enableReverb:)]) [zegoApi enableReverb:YES];
        if ([zegoApi respondsToSelector:@selector(setReverbPreset:)]) [zegoApi setReverbPreset:2];
    } else {
        if ([zegoApi respondsToSelector:@selector(enableReverb:)]) [zegoApi enableReverb:NO];
    }

    // 3. 正常模式恢复
    if (kCurrentMode == AudioMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            @try {
                for (int i = 0; i < 10; i++) {
                    [zegoApi setAudioEqualizerGain:0.0f index:i];
                }
            } @catch (NSException *e) {}
        }
        return;
    }

    // 4. 暴力战斗/破音模式：彻底关闭所有保护性 3A 算法
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO]; // 关闭回声抑制，允许高动态破音

    // 强制数字采集拉满
    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        int v = (kCurrentMode == AudioMode_SuperFight) ? 800 : (int)kDebugGain;
        [zegoApi setCaptureVolume:v];
    }

    // 激进 EQ 曲线：制造硬件级破音与压制感
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        @try {
            if (kCurrentMode == AudioMode_NewFight) {
                // 【新清晰搏击】：全频段拉高制造失真，重点强化 2k~4k 咬字撕裂感
                [zegoApi setAudioEqualizerGain:6.0f index:1];  // 62Hz
                [zegoApi setAudioEqualizerGain:8.0f index:2];  // 125Hz
                [zegoApi setAudioEqualizerGain:6.0f index:3];  // 250Hz
                [zegoApi setAudioEqualizerGain:-2.0f index:4]; // 500Hz
                [zegoApi setAudioEqualizerGain:10.0f index:5]; // 1kHz
                [zegoApi setAudioEqualizerGain:12.0f index:6]; // 2kHz
                [zegoApi setAudioEqualizerGain:kDebugClarityGain index:7]; // 4kHz 撕裂穿透
                [zegoApi setAudioEqualizerGain:10.0f index:8]; // 8kHz
            } else if (kCurrentMode == AudioMode_OldFight) {
                // 【旧清晰搏击】：超重低频轰炸破音，拳拳到肉
                [zegoApi setAudioEqualizerGain:12.0f index:1]; // 62Hz 极限低音
                [zegoApi setAudioEqualizerGain:kDebugBassGain index:2]; // 125Hz 轰炸
                [zegoApi setAudioEqualizerGain:10.0f index:3]; // 250Hz
                [zegoApi setAudioEqualizerGain:4.0f index:4];  // 500Hz
                [zegoApi setAudioEqualizerGain:8.0f index:6];  // 2kHz
                [zegoApi setAudioEqualizerGain:8.0f index:7];  // 4kHz
            } else if (kCurrentMode == AudioMode_SuperFight) {
                // 【超级战斗】：全频段全开过载（真正的轰炸压制）
                for (int i = 0; i < 10; i++) {
                    [zegoApi setAudioEqualizerGain:12.0f index:i];
                }
            }
        } @catch (NSException *e) {}
    }
}

// ---------------------- 保活守护线程（确保永远在线） ----------------------
static void StartAudioKeepAliveService() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        // 每 0.8 秒强制覆盖并保活一次
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.8 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_activeZegoApi && kCurrentMode != AudioMode_Normal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ForceApplyBattleAudio(g_activeZegoApi);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- Hook 业务与底层 SDK ----------------------
%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ForceApplyBattleAudio(g_activeZegoApi);
    });
}

%end

%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    StartAudioKeepAliveService();
    return inst;
}

// 拦截 App 内部下发低音量的行为，强制拦截并替换为超额音量
- (bool)setCaptureVolume:(int)volume {
    g_activeZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) {
        int v = (kCurrentMode == AudioMode_SuperFight) ? 800 : (int)kDebugGain;
        return %orig(v);
    }
    return %orig(volume);
}

- (bool)enableAGC:(bool)enable {
    g_activeZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)enableNoiseSuppress:(bool)enable {
    g_activeZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_activeZegoApi = self;
    bool res = %orig;
    ForceApplyBattleAudio(self);
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    ForceApplyBattleAudio(self);
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    ForceApplyBattleAudio(self);
    return res;
}

%end

// ---------------------- 浮窗 UI ----------------------
@interface BattleMasterHUD : UIView
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIView *debugPageView;
@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swDoubleVoice;
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

@implementation BattleMasterHUD

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UIView *leftTab = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 75, frame.size.height)];
        leftTab.backgroundColor = [UIColor colorWithRed:0.75 green:0.88 blue:1.0 alpha:0.96];
        [self addSubview:leftTab];

        NSArray *tabs = @[@"功能", @"调试", @"音乐", @"设置"];
        for (int i = 0; i < tabs.count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(5, 12 + i * 46, 65, 36);
            [btn setTitle:tabs[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor colorWithRed:0.18 green:0.38 blue:0.78 alpha:1.0] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
            btn.layer.cornerRadius = 8;
            btn.tag = 200 + i;
            [btn addTarget:self action:@selector(tabClicked:) forControlEvents:UIControlEventTouchUpInside];
            [leftTab addSubview:btn];
        }

        CGFloat rightW = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.92];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.92];
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        [self setupFuncPage];
        [self setupDebugPage];
    }
    return self;
}

- (void)setupFuncPage {
    UILabel *procLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, self.funcPageView.frame.size.width - 24, 24)];
    procLabel.text = @"选择进程: 声控物语 (活跃)";
    procLabel.textColor = [UIColor whiteColor];
    procLabel.font = [UIFont systemFontOfSize:11.5];
    procLabel.textAlignment = NSTextAlignmentCenter;
    procLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    procLabel.layer.cornerRadius = 12;
    procLabel.clipsToBounds = YES;
    [self.funcPageView addSubview:procLabel];

    NSArray *titles = @[@"强制开麦", @"双音效果", @"新清晰搏击效果", @"旧清晰搏击效果", @"超级战斗效果"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 38 + i * 36, self.funcPageView.frame.size.width - 16, 32)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 6;
        [self.funcPageView addSubview:row];

        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 120, 24)];
        titleLbl.text = titles[i];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:12];
        [row addSubview:titleLbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 50, 1, 40, 24)];
        sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        [sw addTarget:self action:@selector(onFuncSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        if (i == 0) self.swForceMic = sw;
        if (i == 1) self.swDoubleVoice = sw;
        if (i == 2) { self.swNewFight = sw; [sw setOn:YES]; }
        if (i == 3) self.swOldFight = sw;
        if (i == 4) self.swSuperFight = sw;
    }
}

- (void)setupDebugPage {
    NSArray *debugItems = @[@"极限增益", @"低频轰炸", @"高频撕裂清晰度"];
    for (int i = 0; i < debugItems.count; i++) {
        CGFloat y = 15 + i * 55;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 160, 18)];
        lbl.text = debugItems[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 20, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 300 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 800; slider.value = kDebugGain; }
        if (i == 1) { slider.minimumValue = 0; slider.maximumValue = 20; slider.value = kDebugBassGain; }
        if (i == 2) { slider.minimumValue = 0; slider.maximumValue = 20; slider.value = kDebugClarityGain; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)btn {
    if (btn.tag == 200) {
        self.funcPageView.hidden = NO;
        self.debugPageView.hidden = YES;
    } else if (btn.tag == 201) {
        self.funcPageView.hidden = YES;
        self.debugPageView.hidden = NO;
    }
}

- (void)onSliderChanged:(UISlider *)slider {
    if (slider.tag == 300) kDebugGain = slider.value;
    if (slider.tag == 301) kDebugBassGain = slider.value;
    if (slider.tag == 302) kDebugClarityGain = slider.value;
    ForceApplyBattleAudio(g_activeZegoApi);
}

- (void)onFuncSwitch:(UISwitch *)sender {
    if (sender == self.swForceMic) kForceOpenMic = sender.isOn;
    if (sender == self.swDoubleVoice) kDoubleVoice = sender.isOn;
    if (sender == self.swNewFight) {
        if (sender.isOn) { kCurrentMode = AudioMode_NewFight; [self.swOldFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentMode = AudioMode_Normal; }
    }
    if (sender == self.swOldFight) {
        if (sender.isOn) { kCurrentMode = AudioMode_OldFight; [self.swNewFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentMode = AudioMode_Normal; }
    }
    if (sender == self.swSuperFight) {
        if (sender.isOn) { kCurrentMode = AudioMode_SuperFight; [self.swNewFight setOn:NO animated:YES]; [self.swOldFight setOn:NO animated:YES]; }
        else { kCurrentMode = AudioMode_Normal; }
    }
    ForceApplyBattleAudio(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 手势与挂钩入口 ----------------------
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
    // 避免重复添加手势
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

    // 兼容 iOS 13+ 获取 keyWindow
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        targetWindow = w;
                        break;
                    }
                }
                if (targetWindow) break;
            }
        }
    }
    if (!targetWindow) {
        targetWindow = [UIApplication sharedApplication].windows.firstObject;
    }

    if (!g_hudInstance) {
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 275, 225)];
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
}
%end
