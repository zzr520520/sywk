#import <UIKit/UIKit.h>
#import <substrate.h>
#import <math.h>
#import <AudioToolbox/AudioToolbox.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_BroadcastLoud, // 广播级清晰响亮 (平衡)
    FightMode_HyperDominator // 终极制霸 (128kbps + 双频轰炸 + 极限压限 + 软门限)
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static FightAudioMode kCurrentFightMode = FightMode_HyperDominator;
static float kMasterDrive = 2.0f; // 默认极限强度 (约 +21.3dB 均方根拉伸)

// ---------------------- 终极双频段母带级 DSP 引擎 ----------------------
typedef struct {
    float env;
    float gate_env;

    // 1. 2.8kHz 人耳敏感穿透滤波器 (High-Mid)
    float b0_h, b1_h, b2_h, a1_h, a2_h;
    float x1_h, x2_h, y1_h, y2_h;

    // 2. 120Hz 胸腔震撼低频滤波器 (Body-Low)
    float b0_l, b1_l, b2_l, a1_l, a2_l;
    float x1_l, x2_l, y1_l, y2_l;

    // 侧链高通
    float sc_x1, sc_y1;
} HyperMaximizer2;

// 双二阶 Peaking 滤波器系数计算
static inline void CalcBiquadPeaking(float f0, float gainDB, float Q, float sampleRate,
                                     float *b0, float *b1, float *b2, float *a1, float *a2) {
    float A = powf(10.0f, gainDB / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / sampleRate;
    float alpha = sinf(w0) / (2.0f * Q);

    float b0_tmp = 1.0f + alpha * A;
    float b1_tmp = -2.0f * cosf(w0);
    float b2_tmp = 1.0f - alpha * A;
    float a0_tmp = 1.0f + alpha / A;
    float a1_tmp = -2.0f * cosf(w0);
    float a2_tmp = 1.0f - alpha / A;

    *b0 = b0_tmp / a0_tmp;
    *b1 = b1_tmp / a0_tmp;
    *b2 = b2_tmp / a0_tmp;
    *a1 = a1_tmp / a0_tmp;
    *a2 = a2_tmp / a0_tmp;
}

static inline void InitHyperMaximizer2(HyperMaximizer2 *m, float sampleRate) {
    m->env = 0.0f;
    m->gate_env = 0.0f;
    m->x1_h = m->x2_h = m->y1_h = m->y2_h = 0.0f;
    m->x1_l = m->x2_l = m->y1_l = m->y2_l = 0.0f;
    m->sc_x1 = m->sc_y1 = 0.0f;

    // 高频 2.8kHz 穿透 (+15dB, Q=1.0)
    CalcBiquadPeaking(2800.0f, 15.0f, 1.0f, sampleRate, &m->b0_h, &m->b1_h, &m->b2_h, &m->a1_h, &m->a2_h);
    // 低频 120Hz 胸腔共鸣 (+8dB, Q=1.4)
    CalcBiquadPeaking(120.0f, 8.0f, 1.4f, sampleRate, &m->b0_l, &m->b1_l, &m->b2_l, &m->a1_l, &m->a2_l);
}

// 复合谐波激励器
static inline float ApplyHyperExciter(float x) {
    float x2 = x * fabsf(x);
    float x3 = x2 * x;
    return x + 0.22f * x2 + 0.06f * x3;
}

static inline void ProcessHyperMastering2(HyperMaximizer2 *m,
                                         int16_t *samples,
                                         uint32_t count,
                                         float drive) {
    const float attackCoef = 0.06f;
    const float releaseCoef = 0.0015f;

    // 极限制霸参数：-28dB 深度阈值 + 15:1 压缩比
    const float threshold = 0.040f;
    const float invRatio = 0.066f;
    const float makeUpGain = 5.8f * drive; // 提权补偿增益

    // 软噪声门
    const float gateThreshold = 0.007f;
    const float gateAttack = 0.08f;
    const float gateRelease = 0.0008f;

    for (uint32_t i = 0; i < count; i++) {
        // 前置 1.35 倍硬件级浮点增益提权 (+2.6dB)
        float in = ((float)samples[i] / 32768.0f) * 1.35f;

        // 1. 软噪声门
        float inAbs = fabsf(in);
        if (inAbs > m->gate_env) {
            m->gate_env += gateAttack * (inAbs - m->gate_env);
        } else {
            m->gate_env += gateRelease * (inAbs - m->gate_env);
        }
        float gateGain = 1.0f;
        if (m->gate_env < gateThreshold) {
            gateGain = m->gate_env / gateThreshold;
            gateGain = gateGain * gateGain;
        }
        float gatedIn = in * gateGain;

        // 2. 串联双频段母带 EQ (120Hz 胸腔共鸣 + 2.8kHz 咬字穿透)
        float low_out = m->b0_l * gatedIn + m->b1_l * m->x1_l + m->b2_l * m->x2_l - m->a1_l * m->y1_l - m->a2_l * m->y2_l;
        m->x2_l = m->x1_l; m->x1_l = gatedIn;
        m->y2_l = m->y1_l; m->y1_l = low_out;

        float full_eq = m->b0_h * low_out + m->b1_h * m->x1_h + m->b2_h * m->x2_h - m->a1_h * m->y1_h - m->a2_h * m->y2_h;
        m->x2_h = m->x1_h; m->x1_h = low_out;
        m->y2_h = m->y1_h; m->y1_h = full_eq;

        // 3. 侧链 120Hz 高通检测
        float sc_in = full_eq - m->sc_x1 + 0.98f * m->sc_y1;
        m->sc_x1 = full_eq;
        m->sc_y1 = sc_in;

        // 4. 包络跟随
        float absVal = fabsf(sc_in);
        if (absVal > m->env) {
            m->env += attackCoef * (absVal - m->env);
        } else {
            m->env += releaseCoef * (absVal - m->env);
        }

        // 5. 深度压缩衰减
        float gainReduction = 1.0f;
        if (m->env > threshold) {
            float overDB = (m->env - threshold) / threshold;
            gainReduction = 1.0f / (1.0f + overDB * (1.0f - invRatio));
        }

        // 6. 补偿放大与谐波激发
        float compressed = full_eq * gainReduction * makeUpGain;
        float saturated = ApplyHyperExciter(compressed);

        // 7. 软拐点母带限幅 (安全保留在 0.985，不触发 Opus 丢包检测)
        const float ceiling = 0.985f;
        float out = saturated;
        if (out > ceiling) {
            out = ceiling + (1.0f - ceiling) * tanhf((out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out > 0.992f) out = 0.992f;
        } else if (out < -ceiling) {
            out = -ceiling - (1.0f - ceiling) * tanhf((-out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out < -0.992f) out = -0.992f;
        }

        // 8. 92% 超高密度湿声 + 8% 瞬态干声
        float finalSample = out * 0.92f + gatedIn * 0.08f;

        if (finalSample > 0.998f) finalSample = 0.998f;
        if (finalSample < -0.998f) finalSample = -0.998f;

        samples[i] = (int16_t)(finalSample * 32767.0f);
    }
}

// ---------------------- 接口声明与底层 Hook ----------------------
static HyperMaximizer2 g_hyperMaximizer2;
static BOOL g_hyperInited2 = NO;

@interface ZegoAudioRoomApi : NSObject
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (BOOL)setAudioBitrate:(int)bitrate;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) ZegoAudioRoomApi *zegoEngine;
- (void)muteMic:(BOOL)mute;
@end

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;

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
        if (!g_hyperInited2) {
            InitHyperMaximizer2(&g_hyperMaximizer2, 44100.0f);
            g_hyperInited2 = YES;
        }

        float drive = (kCurrentFightMode == FightMode_HyperDominator) ? kMasterDrive : 1.0f;

        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            int16_t *samples = (int16_t *)ioData->mBuffers[i].mData;
            UInt32 sampleCount = ioData->mBuffers[i].mDataByteSize / sizeof(int16_t);
            ProcessHyperMastering2(&g_hyperMaximizer2, samples, sampleCount, drive);
        }
    }
    return status;
}

// 强制 Opus 128kbps 音乐级码率与全开配置
static void ApplyEngineHiFiConfig(id zegoApi) {
    if (!zegoApi) return;
    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) [zegoApi enableSpeaker:YES];
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) [zegoApi enableMic:YES];

    if (kCurrentFightMode != FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];

        // 强制解锁 128kbps 全频带高码率传输
        if ([zegoApi respondsToSelector:@selector(setAudioBitrate:)]) {
            [zegoApi setAudioBitrate:128000];
        }
    }
}

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
        ApplyEngineHiFiConfig(g_activeZegoEngine);
    }
}
- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic) %orig(NO);
    else %orig(mute);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyEngineHiFiConfig(g_activeZegoEngine);
    });
}
%end

// ---------------------- 悬浮面板与手势 ----------------------
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
@property (nonatomic, strong) UISwitch *swNormalLoud;
@property (nonatomic, strong) UISwitch *swHyperDominator;
@property (nonatomic, strong) UILabel *lblDrive;
@end

static BattleMasterHUD *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

@implementation BattleMasterHUD

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.96];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:0.9].CGColor;
        self.clipsToBounds = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, frame.size.width - 24, 20)];
        title.text = @"🔥 极限制霸 Hyper 2.0 (全频压迫)";
        title.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
        title.font = [UIFont boldSystemFontOfSize:12.5];
        title.textAlignment = NSTextAlignmentCenter;
        [self addSubview:title];

        NSArray *titles = @[@"强制开麦 (防静音)", @"广播级清晰 (平衡)", @"终极制霸 (128k+双频轰炸)"];
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
            if (i == 1) self.swNormalLoud = sw;
            if (i == 2) { self.swHyperDominator = sw; [sw setOn:YES]; }
        }

        self.lblDrive = [[UILabel alloc] initWithFrame:CGRectMake(12, 150, frame.size.width - 24, 18)];
        self.lblDrive.text = [NSString stringWithFormat:@"制霸压限补偿强度: %.2f (+%.1fdB)", kMasterDrive, 20.0f * log10f(5.8f * kMasterDrive)];
        self.lblDrive.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        self.lblDrive.font = [UIFont boldSystemFontOfSize:11];
        [self addSubview:self.lblDrive];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 172, frame.size.width - 24, 20)];
        slider.minimumValue = 1.0;
        slider.maximumValue = 2.8;
        slider.value = kMasterDrive;
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:slider];
    }
    return self;
}

- (void)onSwitchChanged:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swNormalLoud) {
        if (s.isOn) { kCurrentFightMode = FightMode_BroadcastLoud; [self.swHyperDominator setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (s == self.swHyperDominator) {
        if (s.isOn) { kCurrentFightMode = FightMode_HyperDominator; [self.swNormalLoud setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    ApplyEngineHiFiConfig(g_activeZegoEngine);
}

- (void)onSliderChanged:(UISlider *)s {
    kMasterDrive = s.value;
    self.lblDrive.text = [NSString stringWithFormat:@"制霸压限补偿强度: %.2f (+%.1fdB)", kMasterDrive, 20.0f * log10f(5.8f * kMasterDrive)];
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 手势绑定与构造 ----------------------
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

%ctor {
    MSHookFunction((void *)AudioUnitRender, (void *)hook_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureHandler shared] attachToWindow:self];
}
%end
