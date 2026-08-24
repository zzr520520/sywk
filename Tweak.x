#import <UIKit/UIKit.h>
#import <substrate.h>
#import <math.h>
#import <AudioToolbox/AudioToolbox.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_RawLoud,    // 纯净 6 倍暴增益
    FightMode_Dominator   // 极限制霸：12~30 倍饱和暴增益 + 广播级压限（轰炸全场）
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static FightAudioMode kCurrentFightMode = FightMode_Dominator;
static float kPcmGainMultiplier = 12.0f; // 默认 12 倍原始 PCM 乘法放大

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;

// ---------------------- 广播级 Soft-Clipping (软饱和限幅算法) ----------------------
// 将暴增益后的波形限制在 [-32767, 32767]，并用非线性曲线产生极致响度和共鸣感
static inline short ApplyLoudLimiter(int sample, float multiplier) {
    float x = ((float)sample * multiplier) / 32768.0f;
    // 快速非线性饱和限幅曲线：x / (1 + |x|)
    float saturated = x / (1.0f + fabsf(x));
    float outSample = saturated * 32767.0f;
    if (outSample > 32767.0f) outSample = 32767.0f;
    if (outSample < -32767.0f) outSample = -32767.0f;
    return (short)outSample;
}

// ---------------------- 接口声明 (逆向报告结构) ----------------------
@interface ZegoAudioRoomApi : NSObject
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
- (void)muteMic:(BOOL)mute;
@end

// ---------------------- 1. 核心突破：Hook 麦克风底层 PCM 原始采集 ----------------------
// 即构 SDK 底层使用 AudioUnit 进行录音，在此处直接截获并放大原始 PCM 缓冲
static OSStatus (*orig_AudioUnitRender)(AudioComponentInstance inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData);

static OSStatus hook_AudioUnitRender(AudioComponentInstance inUnit,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inOutputBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    if (status == noErr && ioData != NULL && kCurrentFightMode != FightMode_Normal) {
        float mult = kPcmGainMultiplier;
        if (kCurrentFightMode == FightMode_RawLoud) mult = 6.0f;
        if (kCurrentFightMode == FightMode_Dominator) mult = kPcmGainMultiplier;

        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            short *samples = (short *)ioData->mBuffers[i].mData;
            UInt32 sampleCount = ioData->mBuffers[i].mDataByteSize / sizeof(short);

            // 对每一个音频采样点直接进行乘法放大与声学饱和
            for (UInt32 s = 0; s < sampleCount; s++) {
                samples[s] = ApplyLoudLimiter(samples[s], mult);
            }
        }
    }
    return status;
}

// ---------------------- 2. 关闭 SDK 内部压制 ----------------------
static void ApplyAggressiveDSP(id zegoApi) {
    if (!zegoApi) return;

    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) [zegoApi enableSpeaker:YES];
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) [zegoApi enableMic:YES];

    if (kCurrentFightMode != FightMode_Normal) {
        // 彻底关闭 3A 压制，不让 SDK 削减我们放大的波形
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100]; // 保持满格

        // 雕刻 EQ：增强 125Hz-250Hz 胸腔共鸣 + 2kHz-4kHz 穿透
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            [zegoApi setAudioEqualizerGain:12.0f index:1]; // 62Hz
            [zegoApi setAudioEqualizerGain:24.0f index:2]; // 125Hz 饱满胸腔
            [zegoApi setAudioEqualizerGain:18.0f index:3]; // 250Hz
            [zegoApi setAudioEqualizerGain:8.0f  index:4]; // 500Hz
            [zegoApi setAudioEqualizerGain:24.0f index:5]; // 1kHz 咬字
            [zegoApi setAudioEqualizerGain:24.0f index:6]; // 2kHz
            [zegoApi setAudioEqualizerGain:24.0f index:7]; // 4kHz 绝对掩蔽穿透
            [zegoApi setAudioEqualizerGain:16.0f index:8]; // 8kHz
        }
    }
}

// ---------------------- 业务 Hook ----------------------
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
        ApplyAggressiveDSP(g_activeZegoEngine);
    }
}

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic) %orig(NO);
    else %orig(mute);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyAggressiveDSP(g_activeZegoEngine);
    });
}

- (void)startPublishing {
    %orig;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyAggressiveDSP(g_activeZegoEngine);
    });
}

%end

// ---------------------- 窗口获取与主面板 ----------------------
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
@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swRaw;
@property (nonatomic, strong) UISwitch *swDominator;
@property (nonatomic, strong) UILabel *lblMult;
@end

static BattleMasterHUD *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

@implementation BattleMasterHUD

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.15 alpha:0.96];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:0.9].CGColor;
        self.clipsToBounds = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, frame.size.width - 24, 20)];
        title.text = @"⚡ 麦克风 PCM 物理级暴增益控制台";
        title.textColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
        title.font = [UIFont boldSystemFontOfSize:12.5];
        title.textAlignment = NSTextAlignmentCenter;
        [self addSubview:title];

        NSArray *titles = @[@"强制开麦 (防静音)", @"6倍纯净暴增益", @"极限制霸模式 (压限饱和)"];
        for (int i = 0; i < titles.count; i++) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(12, 38 + i * 36, frame.size.width - 24, 30)];
            row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            row.layer.cornerRadius = 6;
            [self addSubview:row];

            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 3, 160, 24)];
            lbl.text = titles[i];
            lbl.textColor = [UIColor whiteColor];
            lbl.font = [UIFont boldSystemFontOfSize:11.5];
            [row addSubview:lbl];

            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 48, 1, 40, 24)];
            sw.transform = CGAffineTransformMakeScale(0.7, 0.7);
            [sw addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:sw];

            if (i == 0) { self.swForceMic = sw; [sw setOn:kForceOpenMic]; }
            if (i == 1) self.swRaw = sw;
            if (i == 2) { self.swDominator = sw; [sw setOn:YES]; }
        }

        self.lblMult = [[UILabel alloc] initWithFrame:CGRectMake(12, 150, frame.size.width - 24, 18)];
        self.lblMult.text = [NSString stringWithFormat:@"PCM 放大倍数: %.1f 倍", kPcmGainMultiplier];
        self.lblMult.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        self.lblMult.font = [UIFont boldSystemFontOfSize:11];
        [self addSubview:self.lblMult];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 172, frame.size.width - 24, 20)];
        slider.minimumValue = 1.0;
        slider.maximumValue = 30.0; // 最高开放至 30 倍物理放大
        slider.value = kPcmGainMultiplier;
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:slider];
    }
    return self;
}

- (void)onSwitchChanged:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swRaw) {
        if (s.isOn) { kCurrentFightMode = FightMode_RawLoud; [self.swDominator setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (s == self.swDominator) {
        if (s.isOn) { kCurrentFightMode = FightMode_Dominator; [self.swRaw setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    ApplyAggressiveDSP(g_activeZegoEngine);
}

- (void)onSliderChanged:(UISlider *)s {
    kPcmGainMultiplier = s.value;
    self.lblMult.text = [NSString stringWithFormat:@"PCM 放大倍数: %.1f 倍", kPcmGainMultiplier];
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 手势挂载 ----------------------
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
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 280, 205)];
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

// ---------------------- 构造函数：Hook 核心 AudioUnitRender ----------------------
%ctor {
    MSHookFunction((void *)AudioUnitRender, (void *)hook_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureHandler shared] attachToWindow:self];
}
%end
