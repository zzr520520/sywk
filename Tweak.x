#import <UIKit/UIKit.h>
#import <substrate.h>

typedef enum : NSUInteger {
    AudioMode_Normal = 0,
    AudioMode_NewFight,   // 新清晰搏击
    AudioMode_OldFight,   // 旧清晰搏击
    AudioMode_SuperFight  // 超级战斗
} AudioFightMode;

static BOOL kForceOpenMic = NO;
static BOOL kDoubleVoice = NO;
static AudioFightMode kCurrentMode = AudioMode_NewFight;

static float kDebugGain = 400.0f;
static float kDebugBassGain = 8.0f;
static float kDebugClarityGain = 10.0f;

static __weak id g_activeZegoApi = nil;

@interface NSObject (ZegoSafeDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableMic:(bool)enable;
- (bool)enableReverb:(bool)enable;
- (bool)setReverbPreset:(int)preset;
@end

// ---------------------- 安全音频矩阵应用 ----------------------
static void SyncGlobalAudioMatrix(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    // 2. 双音/混响效果（使用原生安全预设，杜绝 KVC 崩溃）
    if (kDoubleVoice) {
        if ([zegoApi respondsToSelector:@selector(enableReverb:)]) {
            [zegoApi enableReverb:YES];
        }
        // 预设模式：2 为 KTV/混响双音回响模式
        if ([zegoApi respondsToSelector:@selector(setReverbPreset:)]) {
            [zegoApi setReverbPreset:2];
        }
    } else {
        if ([zegoApi respondsToSelector:@selector(enableReverb:)]) {
            [zegoApi enableReverb:NO];
        }
    }

    // 3. 战斗音效与增益
    if (kCurrentMode == AudioMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
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

    // 关闭 3A 压制
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];

    // 安全设置音量
    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        int targetGain = (kCurrentMode == AudioMode_SuperFight) ? 600 : (int)kDebugGain;
        [zegoApi setCaptureVolume:targetGain];
    }

    // 安全设置 EQ（@try 防止底层断言崩溃）
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        @try {
            if (kCurrentMode == AudioMode_NewFight) {
                [zegoApi setAudioEqualizerGain:2.0f index:2];
                [zegoApi setAudioEqualizerGain:-4.0f index:4];
                [zegoApi setAudioEqualizerGain:8.0f index:6];
                [zegoApi setAudioEqualizerGain:kDebugClarityGain index:7];
            } else if (kCurrentMode == AudioMode_OldFight) {
                [zegoApi setAudioEqualizerGain:kDebugBassGain index:2];
                [zegoApi setAudioEqualizerGain:4.0f index:3];
                [zegoApi setAudioEqualizerGain:-2.0f index:4];
                [zegoApi setAudioEqualizerGain:6.0f index:6];
                [zegoApi setAudioEqualizerGain:7.0f index:7];
            } else if (kCurrentMode == AudioMode_SuperFight) {
                [zegoApi setAudioEqualizerGain:10.0f index:2];
                [zegoApi setAudioEqualizerGain:4.0f index:5];
                [zegoApi setAudioEqualizerGain:8.0f index:6];
                [zegoApi setAudioEqualizerGain:10.0f index:7];
            }
        } @catch (NSException *e) {}
    }
}

// ---------------------- Hook 业务层 SKAudioZegoManager ----------------------
%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    // 上麦完成后延迟刷新参数
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SyncGlobalAudioMatrix(g_activeZegoApi);
    });
}

%end

// ---------------------- Hook Zego 核心 API ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    return inst;
}

- (bool)setCaptureVolume:(int)volume {
    g_activeZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) {
        int v = (kCurrentMode == AudioMode_SuperFight) ? 600 : (int)kDebugGain;
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

// 推流建立后延迟注入，防止底层音频引擎未就绪导致崩溃
- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SyncGlobalAudioMatrix(self);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SyncGlobalAudioMatrix(self);
    });
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SyncGlobalAudioMatrix(self);
    });
    return res;
}

%end

// ---------------------- 浮窗与控制交互 ----------------------
@interface SafeHUDView : UIView
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIView *debugPageView;
@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swDoubleVoice;
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

@implementation SafeHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // 左侧栏
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

        // 右侧容器
        CGFloat rightW = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.92];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.92];
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        [self buildFuncPage];
        [self buildDebugPage];
    }
    return self;
}

- (void)buildFuncPage {
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

- (void)buildDebugPage {
    NSArray *debugItems = @[@"音量增益", @"低频打击", @"高频清晰"];
    for (int i = 0; i < debugItems.count; i++) {
        CGFloat y = 15 + i * 55;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 160, 18)];
        lbl.text = debugItems[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 20, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 300 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 600; slider.value = kDebugGain; }
        if (i == 1) { slider.minimumValue = 0; slider.maximumValue = 15; slider.value = kDebugBassGain; }
        if (i == 2) { slider.minimumValue = 0; slider.maximumValue = 15; slider.value = kDebugClarityGain; }
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

// ---------------------- 全局手势唤醒 ----------------------
static SafeHUDView *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

@interface SafeGestureManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToWindow:(UIWindow *)window;
@end

@implementation SafeGestureManager
+ (instancetype)shared {
    static SafeGestureManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ m = [[SafeGestureManager alloc] init]; });
    return m;
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
        g_hudInstance = [[SafeHUDView alloc] initWithFrame:CGRectMake(25, 120, 275, 225)];
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
    [[SafeGestureManager shared] attachToWindow:self];
}
%end
