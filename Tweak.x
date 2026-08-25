#import <UIKit/UIKit.h>
#import <substrate.h>
#import <math.h>
#import <AudioToolbox/AudioToolbox.h>

// ========================================================================
// 声控物语搏击音效插件 v13.0.0 (Studio One 机架级：磁力电流冲击波)
// 核心特性：讲话瞬间触发 50Hz 亚低频冲击波 + 磁力电流饱和 + 5000 极限声压
// ========================================================================

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_BroadcastLoud, // 广播级清晰
    FightMode_ShockWave      // 视频同款：磁力电流冲击波轰炸模式
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static BOOL kAudioInjection = NO;
static BOOL kShockWaveEnabled = YES;      // 磁力电流冲击波总开关
static FightAudioMode kCurrentFightMode = FightMode_ShockWave;

static float kVoiceGainRatio = 1.6f;      // 人声增益 (5000 级)
static float kShockWaveIntensity = 4000.0f;// 冲击波基础能量 (4000 级)
static float kMagneticDrive = 2.2f;       // 电流磁力饱和度

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;
static dispatch_source_t g_keepAliveTimer = nil;
static BOOL g_isPublishing = NO;

// ========================================================================
// Part 1: Studio One 机架级 DSP 引擎 (磁力电流 + 动态冲击波合成)
// ========================================================================
typedef struct {
    float gate_env;
    float shock_env;
    double sub_phase;      // 55Hz 亚低频冲击波相位
    double current_phase;  // 120Hz 电流磁环相位

    // 双二阶 EQ 状态
    float b0_h, b1_h, b2_h, a1_h, a2_h;
    float x1_h, x2_h, y1_h, y2_h;
    float b0_l, b1_l, b2_l, a1_l, a2_l;
    float x1_l, x2_l, y1_l, y2_l;
} StudioOneRackDSP;

static StudioOneRackDSP g_rackDSP;
static BOOL g_rackInited = NO;

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

static inline void InitStudioOneRack(StudioOneRackDSP *m, float sampleRate) {
    memset(m, 0, sizeof(StudioOneRackDSP));
    // 2.8kHz 穿透咬字 (+16dB, Q=1.0)
    CalcBiquadPeaking(2800.0f, 16.0f, 1.0f, sampleRate, &m->b0_h, &m->b1_h, &m->b2_h, &m->a1_h, &m->a2_h);
    // 80Hz 冲击波能量 (+12dB, Q=1.2)
    CalcBiquadPeaking(80.0f, 12.0f, 1.2f, sampleRate, &m->b0_l, &m->b1_l, &m->b2_l, &m->a1_l, &m->a2_l);
}

// 核心算法：磁力电流饱和器 (模拟 Saturn 2 电子管击穿带电质感)
static inline float ApplyMagneticSaturation(float x, float drive) {
    float driven = x * drive;
    // 非对称饱和产生丰富的偶次磁力泛音
    float magnetic = driven / (1.0f + fabsf(driven));
    // 注入高频电流脉冲调制
    float currentHarmonic = 0.25f * (driven * driven * driven - driven);
    return magnetic + currentHarmonic * 0.15f;
}

static inline void ProcessStudioOneRackMastering(StudioOneRackDSP *m, int16_t *samples, uint32_t count) {
    const float sampleRate = 44100.0f;
    const double subFreq = 58.0;      // 58Hz 震撼心跳冲击波频率
    const double subInc = 2.0 * M_PI * subFreq / sampleRate;

    const double currentFreq = 116.0; // 116Hz 磁力电流共振频
    const double currentInc = 2.0 * M_PI * currentFreq / sampleRate;

    const float gateThresh = 0.006f;
    const float gateAttack = 0.12f;   // 极速触发
    const float gateRelease = 0.001f;

    for (uint32_t i = 0; i < count; i++) {
        float rawIn = (float)samples[i] / 32768.0f;
        float absIn = fabsf(rawIn);

        // 1. 人声探测门限 (只要一开口立刻触发)
        if (absIn > m->gate_env) m->gate_env += gateAttack * (absIn - m->gate_env);
        else m->gate_env += gateRelease * (absIn - m->gate_env);

        float isSpeaking = 0.0f;
        if (m->gate_env > gateThresh) {
            isSpeaking = (m->gate_env - gateThresh) / (0.08f - gateThresh);
            if (isSpeaking > 1.0f) isSpeaking = 1.0f;
        }

        // 2. 生成联动磁力冲击波 (4000 档位能量)
        float shockWave = 0.0f;
        if (kShockWaveEnabled && isSpeaking > 0.05f) {
            float subBass = sin(m->sub_phase);
            float magneticPulse = sin(m->current_phase);
            // 冲击波强度由 4000 参数驱动
            float shockScale = (kShockWaveIntensity / 4000.0f) * 0.45f;
            shockWave = (subBass * 0.7f + magneticPulse * 0.3f) * shockScale * isSpeaking;

            m->sub_phase += subInc;
            if (m->sub_phase >= 2.0 * M_PI) m->sub_phase -= 2.0 * M_PI;
            m->current_phase += currentInc;
            if (m->current_phase >= 2.0 * M_PI) m->current_phase -= 2.0 * M_PI;
        }

        // 3. 人声主轨母带 EQ + 磁力电流饱和 (5000 档位满格)
        float gatedVoice = rawIn * isSpeaking * (kVoiceGainRatio * 1.8f);

        float low_eq = m->b0_l * gatedVoice + m->b1_l * m->x1_l + m->b2_l * m->x2_l - m->a1_l * m->y1_l - m->a2_l * m->y2_l;
        m->x2_l = m->x1_l; m->x1_l = gatedVoice;
        m->y2_l = m->y1_l; m->y1_l = low_eq;

        float full_eq = m->b0_h * low_eq + m->b1_h * m->x1_h + m->b2_h * m->x2_h - m->a1_h * m->y1_h - m->a2_h * m->y2_h;
        m->x2_h = m->x1_h; m->x1_h = low_eq;
        m->y2_h = m->y1_h; m->y1_h = full_eq;

        // 注入磁力电流饱和
        float magneticVoice = ApplyMagneticSaturation(full_eq, kMagneticDrive);

        // 4. 双轨总混音 (人声 5000 级 + 冲击波 4000 级)
        float mix = magneticVoice * 0.75f + shockWave * 0.55f;

        // 5. 广播级前瞻软限幅 (封顶 0.985 防爆音)
        const float ceiling = 0.985f;
        float out = mix;
        if (out > ceiling) {
            out = ceiling + (1.0f - ceiling) * tanhf((out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out > 0.995f) out = 0.995f;
        } else if (out < -ceiling) {
            out = -ceiling - (1.0f - ceiling) * tanhf((-out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out < -0.995f) out = -0.995f;
        }

        samples[i] = (int16_t)(out * 32767.0f);
    }
}

// AudioUnitRender 底层音频截获 Hook
static OSStatus (*orig_AudioUnitRender)(AudioComponentInstance, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static OSStatus hook_AudioUnitRender(AudioComponentInstance inUnit,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inOutputBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    if (status == noErr && ioData != NULL && g_isPublishing && kCurrentFightMode == FightMode_ShockWave) {
        if (!g_rackInited) {
            InitStudioOneRack(&g_rackDSP, 44100.0f);
            g_rackInited = YES;
        }
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            int16_t *samples = (int16_t *)ioData->mBuffers[i].mData;
            UInt32 sampleCount = ioData->mBuffers[i].mDataByteSize / sizeof(int16_t);
            if (sampleCount > 0 && samples) {
                ProcessStudioOneRackMastering(&g_rackDSP, samples, sampleCount);
            }
        }
    }
    return status;
}

// ========================================================================
// Part 2: 即构 SDK 接口声明与电脑级声卡场景
// ========================================================================
@interface ZegoAudioRoomApi : NSObject
- (void)setCaptureVolume:(int)volume;
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (BOOL)setAudioEqualizerGain:(float)gain index:(int)index;
- (BOOL)setAudioBitrate:(int)bitrate;
- (BOOL)setAudioScenario:(int)scenario;
- (BOOL)setAudioChannelCount:(int)count;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) ZegoAudioRoomApi *zegoEngine;
- (void)muteMic:(BOOL)mute;
- (void)startPublishing;
- (void)stopPublishing;
@end

static void ApplyStudioOneProfile(id zegoApi) {
    if (!zegoApi) return;

    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) [zegoApi enableSpeaker:YES];
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) [zegoApi enableMic:YES];

    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        return;
    }

    // 强制电脑专业机架模式：音乐场景 + 双声道立体声 + 128kbps
    if ([zegoApi respondsToSelector:@selector(setAudioScenario:)]) [zegoApi setAudioScenario:1];
    if ([zegoApi respondsToSelector:@selector(setAudioChannelCount:)]) [zegoApi setAudioChannelCount:2];
    if ([zegoApi respondsToSelector:@selector(setAudioBitrate:)]) [zegoApi setAudioBitrate:128000];

    // 关闭 3A 压制，释放无压缩动态
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 锁定 5000 封顶极限捕捉音量
    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:5000];
    }

    // 10段机架 EQ：低频重轰炸 + 中高频磁力刺穿
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        [zegoApi setAudioEqualizerGain:14.0f index:0]; // 31Hz 超低频冲击
        [zegoApi setAudioEqualizerGain:24.0f index:1]; // 62Hz 冲击波轰炸区 (顶格)
        [zegoApi setAudioEqualizerGain:20.0f index:2]; // 125Hz 磁力共振区
        [zegoApi setAudioEqualizerGain:8.0f  index:3]; // 250Hz
        [zegoApi setAudioEqualizerGain:4.0f  index:4]; // 500Hz
        [zegoApi setAudioEqualizerGain:24.0f index:5]; // 1kHz 咬字清晰 (顶格)
        [zegoApi setAudioEqualizerGain:24.0f index:6]; // 2kHz 穿透压制 (顶格)
        [zegoApi setAudioEqualizerGain:24.0f index:7]; // 4kHz 电流声学掩蔽 (顶格)
        [zegoApi setAudioEqualizerGain:22.0f index:8]; // 8kHz 金属泛音
        [zegoApi setAudioEqualizerGain:16.0f index:9]; // 16kHz 空气感
    }
}

// ========================================================================
// Part 3: Hook 层与生命周期
// ========================================================================
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
        ApplyStudioOneProfile(g_activeZegoEngine);
    }
}
- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic) %orig(NO);
    else %orig(mute);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyStudioOneProfile(g_activeZegoEngine);
    });
}
- (void)startPublishing {
    %orig;
    g_isPublishing = YES;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyStudioOneProfile(g_activeZegoEngine);
    });
}
- (void)stopPublishing {
    g_isPublishing = NO;
    %orig;
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
    if (kCurrentFightMode == FightMode_ShockWave) {
        %orig(5000); // 强制 5000 顶格
        return;
    }
    %orig(volume);
}
%end

// ========================================================================
// Part 4: 保活线程与 HUD 面板
// ========================================================================
static void StartKeepAliveService() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.8 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_activeZegoEngine && kCurrentFightMode != FightMode_Normal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ApplyStudioOneProfile(g_activeZegoEngine);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

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
@property (nonatomic, strong) UISwitch *swShockWave;
@property (nonatomic, strong) UISwitch *swShockMode;
@property (nonatomic, strong) UILabel *lblShock;
@property (nonatomic, strong) UILabel *lblVoice;
@end

static BattleMasterHUD *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

@implementation BattleMasterHUD
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.11 alpha:0.96];
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9].CGColor;
        self.clipsToBounds = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];

        UIView *leftTab = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 75, frame.size.height)];
        leftTab.backgroundColor = [UIColor colorWithRed:0.12 green:0.15 blue:0.24 alpha:0.96];
        [self addSubview:leftTab];

        NSArray *tabs = @[@"功能", @"参数"];
        for (int i = 0; i < tabs.count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(5, 16 + i * 50, 65, 38);
            [btn setTitle:tabs[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
            btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
            btn.layer.cornerRadius = 8;
            btn.tag = 200 + i;
            [btn addTarget:self action:@selector(tabClicked:) forControlEvents:UIControlEventTouchUpInside];
            [leftTab addSubview:btn];
        }

        CGFloat rw = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIScrollView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.debugPageView.contentSize = CGSizeMake(rw, 320);
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
    UILabel *proc = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, self.funcPageView.frame.size.width - 20, 20)];
    proc.text = @"⚡ Studio One 机架磁力冲击波";
    proc.textColor = [UIColor colorWithRed:0.4 green:0.85 blue:1.0 alpha:1.0];
    proc.font = [UIFont boldSystemFontOfSize:11.5];
    proc.textAlignment = NSTextAlignmentCenter;
    [self.funcPageView addSubview:proc];

    NSArray *titles = @[@"强制开麦 (防静音)", @"动态磁力冲击波", @"5000+4000 轰炸模式"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 36 + i * 40, self.funcPageView.frame.size.width - 16, 32)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 6;
        [self.funcPageView addSubview:row];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 130, 24)];
        lbl.text = titles[i];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 48, 2, 40, 24)];
        sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        [sw addTarget:self action:@selector(onFuncSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        if (i == 0) { self.swForceMic = sw; [sw setOn:kForceOpenMic]; }
        if (i == 1) { self.swShockWave = sw; [sw setOn:kShockWaveEnabled]; }
        if (i == 2) { self.swShockMode = sw; [sw setOn:YES]; }
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"冲击波能量 (默认4000)", @"人声主轨增益 (5000+)", @"磁力电流饱和度"];
    for (int i = 0; i < items.count; i++) {
        CGFloat y = 8 + i * 62;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, self.debugPageView.frame.size.width - 20, 16)];
        lbl.text = items[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(10, y + 20, self.debugPageView.frame.size.width - 20, 20)];
        slider.tag = 600 + i;
        if (i == 0) { slider.minimumValue = 1000; slider.maximumValue = 6000; slider.value = kShockWaveIntensity; }
        if (i == 1) { slider.minimumValue = 1.0;  slider.maximumValue = 3.0;  slider.value = kVoiceGainRatio; }
        if (i == 2) { slider.minimumValue = 1.0;  slider.maximumValue = 4.0;  slider.value = kMagneticDrive; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)b {
    self.funcPageView.hidden = (b.tag != 200);
    self.debugPageView.hidden = (b.tag != 201);
}

- (void)onSliderChanged:(UISlider *)s {
    if (s.tag == 600) kShockWaveIntensity = s.value;
    if (s.tag == 601) kVoiceGainRatio = s.value;
    if (s.tag == 602) kMagneticDrive = s.value;
    ApplyStudioOneProfile(g_activeZegoEngine);
}

- (void)onFuncSwitch:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swShockWave) kShockWaveEnabled = s.isOn;
    if (s == self.swShockMode) {
        if (s.isOn) kCurrentFightMode = FightMode_ShockWave;
        else kCurrentFightMode = FightMode_Normal;
    }
    ApplyStudioOneProfile(g_activeZegoEngine);
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}
@end

// ========================================================================
// Part 5: 双指双击手势与构造函数挂载
// ========================================================================
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
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 285, 210)];
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
    StartKeepAliveService();
}
%end
