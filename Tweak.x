#import <UIKit/UIKit.h>
#import <substrate.h>

// ---------------------- 全局参数与状态 ----------------------
typedef enum : NSUInteger {
    AudioMode_Normal = 0,
    AudioMode_NewFight,   // 新清晰搏击
    AudioMode_OldFight,   // 旧清晰搏击
    AudioMode_SuperFight  // 超级战斗
} AudioFightMode;

static BOOL kForceOpenMic = NO;
static BOOL kDoubleVoice = NO;
static AudioFightMode kCurrentMode = AudioMode_NewFight;

// 动态调试参数 (可在调试页实时拖动)
static float kDebugGain = 400.0f;       // 采集音量增益
static float kDebugBassGain = 8.0f;     // 低频打击感 (125Hz)
static float kDebugClarityGain = 10.0f; // 高频清晰度 (4kHz)
static float kDebugEchoGain = 40.0f;    // 双音回声强度

static __weak id g_activeZegoApi = nil;

@interface NSObject (ZegoSDKDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableMic:(bool)enable;
- (bool)setReverbEchoParam:(id)param;
- (bool)enableReverb:(bool)enable;
@end

// ---------------------- 核心音频流矩阵调度 ----------------------
static void SyncGlobalAudioMatrix(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦
    if (kForceOpenMic) {
        [zegoApi enableMic:YES];
    }

    // 2. 双音效果（上传给房间所有人听到）
    // 利用运行时动态构建 ZegoReverbEchoParam 回声回响对象推流
    if (kDoubleVoice) {
        Class echoCls = NSClassFromString(@"ZegoReverbEchoParam");
        if (echoCls) {
            id echoParam = [[echoCls alloc] init];
            // 配置全房间可听的双重音质感
            @try {
                [echoParam setValue:@(kDebugEchoGain / 100.0f) forKey:@"inGain"];
                [echoParam setValue:@(0.6f) forKey:@"outGain"];
                [echoParam setValue:@(120) forKey:@"delay"]; // 120ms 延时，产生明显双重声
                [echoParam setValue:@(0.5f) forKey:@"decay"];
                [zegoApi setReverbEchoParam:echoParam];
            } @catch (NSException *e) {}
        }
    } else {
        [zegoApi setReverbEchoParam:nil];
    }

    // 3. 战斗/搏击/调试调音模式注入
    if (kCurrentMode == AudioMode_Normal) {
        [zegoApi enableAGC:YES];
        [zegoApi enableNoiseSuppress:YES];
        [zegoApi setCaptureVolume:100];
        for (int i = 0; i < 10; i++) {
            [zegoApi setAudioEqualizerGain:0.0f index:i];
        }
        return;
    }

    // 只要开启任一战斗模式，强制抹杀 3A 压制
    [zegoApi enableAGC:NO];
    [zegoApi enableNoiseSuppress:NO];

    if (kCurrentMode == AudioMode_NewFight) {
        [zegoApi setCaptureVolume:(int)kDebugGain];
        [zegoApi setAudioEqualizerGain:2.0f index:2];
        [zegoApi setAudioEqualizerGain:-6.0f index:4]; // 压低浑浊
        [zegoApi setAudioEqualizerGain:8.0f index:6];
        [zegoApi setAudioEqualizerGain:kDebugClarityGain index:7]; // 极高咬字清晰
    } else if (kCurrentMode == AudioMode_OldFight) {
        [zegoApi setCaptureVolume:(int)kDebugGain];
        [zegoApi setAudioEqualizerGain:kDebugBassGain index:2];    // 重低频爆发
        [zegoApi setAudioEqualizerGain:5.0f index:3];
        [zegoApi setAudioEqualizerGain:-2.0f index:4];
        [zegoApi setAudioEqualizerGain:6.0f index:6];
        [zegoApi setAudioEqualizerGain:7.0f index:7];
    } else if (kCurrentMode == AudioMode_SuperFight) {
        [zegoApi setCaptureVolume:650]; // 极限音量轰炸
        [zegoApi setAudioEqualizerGain:12.0f index:2];
        [zegoApi setAudioEqualizerGain:5.0f index:5];
        [zegoApi setAudioEqualizerGain:10.0f index:6];
        [zegoApi setAudioEqualizerGain:12.0f index:7];
    }
}

// ---------------------- Hook 业务层与 SDK ----------------------
// 1. Hook 应用业务管理器 SKAudioZegoManager，防止上麦重置参数
%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    // 上麦完成后强行刷新参数
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SyncGlobalAudioMatrix(g_activeZegoApi);
    });
}

%end

// 2. Hook 底层 ZegoLiveRoomApi
%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    return inst;
}

- (bool)setCaptureVolume:(int)volume {
    g_activeZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) {
        int v = (kCurrentMode == AudioMode_SuperFight) ? 650 : (int)kDebugGain;
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
    SyncGlobalAudioMatrix(self);
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    SyncGlobalAudioMatrix(self);
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    SyncGlobalAudioMatrix(self);
    return res;
}

%end

// ---------------------- 完整 UI 面板（含调试/功能切换） ----------------------
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

        // 1. 左侧 Tab 栏
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

        // 2. 右侧面板容器
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

// 构建功能页
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

// 构建调试页（滑块微调）
- (void)setupDebugPage {
    NSArray *debugItems = @[@"音量增益", @"低频打击", @"高频清晰", @"双音强度"];
    for (int i = 0; i < debugItems.count; i++) {
        CGFloat y = 10 + i * 50;
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
        if (i == 3) { slider.minimumValue = 0; slider.maximumValue = 100; slider.value = kDebugEchoGain; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)btn {
    if (btn.tag == 200) { // 功能
        self.funcPageView.hidden = NO;
        self.debugPageView.hidden = YES;
    } else if (btn.tag == 201) { // 调试
        self.funcPageView.hidden = YES;
        self.debugPageView.hidden = NO;
    }
}

- (void)onSliderChanged:(UISlider *)slider {
    if (slider.tag == 300) kDebugGain = slider.value;
    if (slider.tag == 301) kDebugBassGain = slider.value;
    if (slider.tag == 302) kDebugClarityGain = slider.value;
    if (slider.tag == 303) kDebugEchoGain = slider.value;
    SyncGlobalAudioMatrix(g_activeZegoApi);
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
    SyncGlobalAudioMatrix(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 注入启动与手势唤醒 ----------------------
static BattleMasterHUD *g_hudView = nil;
static NSTimeInterval g_lastTap = 0;

@interface HUDGestureProxy : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)registerOnWindow:(UIWindow *)window;
@end

@implementation HUDGestureProxy
+ (instancetype)shared {
    static HUDGestureProxy *p;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ p = [[HUDGestureProxy alloc] init]; });
    return p;
}
- (void)registerOnWindow:(UIWindow *)window {
    if (!window) return;
    for (UIGestureRecognizer *g in window.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]] && ((UITapGestureRecognizer *)g).numberOfTouchesRequired == 2) {
            return;
        }
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [window addGestureRecognizer:tap];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g1 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)g2 {
    return YES;
}
- (void)onTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastTap < 0.45) return;
    g_lastTap = now;

    // 兼容 iOS 13+ 获取 keyWindow 的方式
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

    if (!g_hudView) {
        g_hudView = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 275, 225)];
        [targetWindow addSubview:g_hudView];
        return;
    }
    if (g_hudView.hidden || g_hudView.alpha < 0.1f) {
        if (g_hudView.superview != targetWindow) [targetWindow addSubview:g_hudView];
        [targetWindow bringSubviewToFront:g_hudView];
        g_hudView.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ g_hudView.alpha = 1.0f; }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{ g_hudView.alpha = 0.0f; } completion:^(BOOL f) { g_hudView.hidden = YES; }];
    }
}
@end

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureProxy shared] registerOnWindow:self];
}
%end
