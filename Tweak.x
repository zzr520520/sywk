#import <UIKit/UIKit.h>
#import <substrate.h>
#import <math.h>
#import <AudioToolbox/AudioToolbox.h>

// ========================================================================
// v12.0.0: v8.5 Zego API 主控 + v10.0.0 HyperMaximizer2 + v12.0 PC 声卡模拟层
// 核心策略：setCaptureVolume + setAudioEqualizerGain + 关3A = 主力生效通道
//          AudioUnitRender HyperMaximizer2 = 二级增强
//          PCSoundCardMode = PC 端大声卡直推模拟（宽带胸腔 + 高频泛音 + 立体声展宽）
// ========================================================================

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,         // 新清晰 (400 增益 + 齿音穿透)
    FightMode_Old,         // 旧清晰 (800 增益 + 饱满洪亮)
    FightMode_Super        // 震撼超级压制 (3000~5000 + 胸腔共鸣 + 极致清晰)
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static BOOL kAudioInjection = NO;         // AUX 全房信号注入
static BOOL kHyperEnhance = YES;          // HyperMaximizer2 二级增强开关
static BOOL kPCSoundCardMode = NO;        // v12.0 模拟电脑声卡模式
static FightAudioMode kCurrentFightMode = FightMode_Super;

static float kNewFightGain = 400.0f;
static float kOldFightGain = 800.0f;
static float kSuperFightGain = 3000.0f;
static float kVoiceGainRatio = 1.2f;
static float kHyperDrive = 2.0f;          // HyperMaximizer2 驱动强度
static float kVirtualPreAmp = 4.5f;       // 虚拟话放暴力提权倍数（模拟硬件过载）

// v12.0 PC 声卡模拟参数
static float kPCSoundCardWidth = 1.6f;    // 立体声展宽系数 (1.0~2.5)
static float kPCSoundCardAir = 1.0f;      // 高频泛音空气感强度 (0.5~2.0)
static float kPCSoundCardChest = 1.0f;    // 宽带胸腔压迫感强度 (0.5~2.0)
static int   kPCSoundCardBitrate = 128000; // PC 声卡模式码率

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;
static dispatch_source_t g_keepAliveTimer = nil;
static BOOL g_isPublishing = NO;          // 推流状态标记

// ========================================================================
// Part 1: v10.0.0 HyperMaximizer2 双频段母带 DSP（二级增强层）
// 仅在 AudioUnitRender 拦截到音频时生效，不拦截则完全不影响
// ========================================================================
typedef struct {
    float env;
    float gate_env;
    float b0_h, b1_h, b2_h, a1_h, a2_h;
    float x1_h, x2_h, y1_h, y2_h;
    float b0_l, b1_l, b2_l, a1_l, a2_l;
    float x1_l, x2_l, y1_l, y2_l;
    float sc_x1, sc_y1;
} HyperMaximizer2;

static HyperMaximizer2 g_hyperMax;
static BOOL g_hyperInited = NO;

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

static inline void InitHyperMax(HyperMaximizer2 *m, float sampleRate) {
    memset(m, 0, sizeof(HyperMaximizer2));
    CalcBiquadPeaking(2800.0f, 12.0f, 1.0f, sampleRate, &m->b0_h, &m->b1_h, &m->b2_h, &m->a1_h, &m->a2_h);
    CalcBiquadPeaking(120.0f, 6.0f, 1.4f, sampleRate, &m->b0_l, &m->b1_l, &m->b2_l, &m->a1_l, &m->a2_l);
}

static inline float ApplyHyperExciter(float x) {
    float x2 = x * fabsf(x);
    return x + 0.18f * x2 + 0.04f * x2 * x;
}

static inline void ProcessHyperMastering(HyperMaximizer2 *m, int16_t *samples, uint32_t count, float drive) {
    const float attackCoef = 0.06f;
    const float releaseCoef = 0.0015f;
    const float threshold = 0.040f;
    const float invRatio = 0.066f;
    const float makeUpGain = 4.5f * drive;
    const float gateThreshold = 0.012f;
    const float gateAttack = 0.08f;
    const float gateRelease = 0.0008f;

    for (uint32_t i = 0; i < count; i++) {
        float in = ((float)samples[i] / 32768.0f) * kVirtualPreAmp;

        float inAbs = fabsf(in);
        if (inAbs > m->gate_env) m->gate_env += gateAttack * (inAbs - m->gate_env);
        else m->gate_env += gateRelease * (inAbs - m->gate_env);
        float gateGain = 1.0f;
        if (m->gate_env < gateThreshold) {
            gateGain = m->gate_env / gateThreshold;
            gateGain = gateGain * gateGain;
        }
        float gatedIn = in * gateGain;

        float low_out = m->b0_l * gatedIn + m->b1_l * m->x1_l + m->b2_l * m->x2_l - m->a1_l * m->y1_l - m->a2_l * m->y2_l;
        m->x2_l = m->x1_l; m->x1_l = gatedIn;
        m->y2_l = m->y1_l; m->y1_l = low_out;

        float full_eq = m->b0_h * low_out + m->b1_h * m->x1_h + m->b2_h * m->x2_h - m->a1_h * m->y1_h - m->a2_h * m->y2_h;
        m->x2_h = m->x1_h; m->x1_h = low_out;
        m->y2_h = m->y1_h; m->y1_h = full_eq;

        float sc_in = full_eq - m->sc_x1 + 0.98f * m->sc_y1;
        m->sc_x1 = full_eq;
        m->sc_y1 = sc_in;

        float absVal = fabsf(sc_in);
        if (absVal > m->env) m->env += attackCoef * (absVal - m->env);
        else m->env += releaseCoef * (absVal - m->env);

        float gainReduction = 1.0f;
        if (m->env > threshold) {
            float overDB = (m->env - threshold) / threshold;
            gainReduction = 1.0f / (1.0f + overDB * (1.0f - invRatio));
        }

        float compressed = full_eq * gainReduction * makeUpGain;
        float saturated = ApplyHyperExciter(compressed);

        const float ceiling = 0.985f;
        float out = saturated;
        if (out > ceiling) {
            out = ceiling + (1.0f - ceiling) * tanhf((out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out > 0.992f) out = 0.992f;
        } else if (out < -ceiling) {
            out = -ceiling - (1.0f - ceiling) * tanhf((-out - ceiling) / (1.0f - ceiling + 0.001f));
            if (out < -0.992f) out = -0.992f;
        }

        float finalSample = out * 0.92f + gatedIn * 0.08f;
        if (finalSample > 0.998f) finalSample = 0.998f;
        if (finalSample < -0.998f) finalSample = -0.998f;
        samples[i] = (int16_t)(finalSample * 32767.0f);
    }
}

// AudioUnitRender 二级增强层（仅在推流时激活，不拦截即构则自动空转）
static OSStatus (*orig_AudioUnitRender)(AudioComponentInstance, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static OSStatus hook_AudioUnitRender(AudioComponentInstance inUnit,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inOutputBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    if (status == noErr && ioData != NULL && kHyperEnhance && g_isPublishing &&
        kCurrentFightMode != FightMode_Normal) {
        if (!g_hyperInited) {
            InitHyperMax(&g_hyperMax, 44100.0f);
            g_hyperInited = YES;
        }
        float drive = kHyperDrive;
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            int16_t *samples = (int16_t *)ioData->mBuffers[i].mData;
            UInt32 sampleCount = ioData->mBuffers[i].mDataByteSize / sizeof(int16_t);
            if (sampleCount > 0 && samples) {
                ProcessHyperMastering(&g_hyperMax, samples, sampleCount, drive);
            }
        }
    }
    return status;
}

// ========================================================================
// Part 2: v8.5 接口声明（Zego SDK 原生 API = 真正生效的通道）
// ========================================================================
@interface ZegoAudioRoomApi : NSObject
- (void)setCaptureVolume:(int)volume;
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (BOOL)enableAux:(BOOL)enable;
- (BOOL)setAuxVolume:(int)volume;
- (BOOL)setAudioEqualizerGain:(float)gain index:(int)index;
- (BOOL)setAudioBitrate:(int)bitrate;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (BOOL)setAudioChannelCount:(int)count;          // v12.0 声道数设置
- (BOOL)setCaptureStereoSideGain:(float)gain;     // v12.0 立体声展宽
- (BOOL)enableHeadphoneAEC:(BOOL)enable;          // v12.0 耳机回声消除
- (BOOL)setVoiceChangerParam:(float)param type:(int)type; // v12.0 音效参数
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
- (void)stopPublishing;
@end

// ========================================================================
// Part 3: v8.5 主力调音链（Zego SDK API）+ 清晰度优化 EQ
// 核心生效路径：setCaptureVolume → setAudioEqualizerGain → 关3A
// v12.0 新增：PC 声卡模拟层（立体声展宽 + 高频泛音 + 宽带胸腔 + 128kbps 全频带）
// ========================================================================
static void ApplyCrystalLoudVoiceDSP(id zegoApi) {
    if (!zegoApi) return;

    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) [zegoApi enableSpeaker:YES];
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) [zegoApi enableMic:YES];

    if (kCurrentFightMode == FightMode_Normal && !kPCSoundCardMode) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            for (int i = 0; i < 10; i++) [zegoApi setAudioEqualizerGain:0.0f index:i];
        }
        if ([zegoApi respondsToSelector:@selector(setAudioBitrate:)]) {
            [zegoApi setAudioBitrate:48000];
        }
        return;
    }

    // 彻底关停 3A 压制（v8.5 核心策略：释放无压缩动态）
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 增益计算（v8.5 核心策略：setCaptureVolume 真实生效）
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);
    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    // 码率设置：PC 声卡模式强制 128kbps 全频带音乐场景
    if ([zegoApi respondsToSelector:@selector(setAudioBitrate:)]) {
        int bitrate = kPCSoundCardMode ? kPCSoundCardBitrate : 128000;
        [zegoApi setAudioBitrate:bitrate];
    }

    // v12.0 PC 声卡模拟：双声道立体声驱动
    if (kPCSoundCardMode) {
        if ([zegoApi respondsToSelector:@selector(setAudioChannelCount:)]) {
            [zegoApi setAudioChannelCount:2];  // 强制双声道立体声
        }
        if ([zegoApi respondsToSelector:@selector(setCaptureStereoSideGain:)]) {
            [zegoApi setCaptureStereoSideGain:kPCSoundCardWidth];
        }
        if ([zegoApi respondsToSelector:@selector(enableHeadphoneAEC:)]) {
            [zegoApi enableHeadphoneAEC:NO];  // 解除底噪抑制，释放全频带动态
        }
    }

    // AUX 混音注入
    if ([zegoApi respondsToSelector:@selector(enableAux:)]) {
        [zegoApi enableAux:kAudioInjection];
        if (kAudioInjection && [zegoApi respondsToSelector:@selector(setAuxVolume:)]) {
            [zegoApi setAuxVolume:100];
        }
    }

    // 10 段 EQ（清晰度优化版：削减 250-500Hz 浑浊区，提升 4-8kHz 空气感）
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            // 新清晰：齿音穿透，中低频适度削减防糊
            float airBoost = kPCSoundCardMode ? (4.0f * kPCSoundCardAir) : 0.0f;
            float chestBoost = kPCSoundCardMode ? (2.0f * kPCSoundCardChest) : 0.0f;
            [zegoApi setAudioEqualizerGain:-10.0f index:0]; // 31Hz
            [zegoApi setAudioEqualizerGain:-6.0f  index:1]; // 62Hz
            [zegoApi setAudioEqualizerGain:-2.0f + chestBoost index:2]; // 125Hz
            [zegoApi setAudioEqualizerGain:-8.0f  index:3]; // 250Hz 削浑浊
            [zegoApi setAudioEqualizerGain:-10.0f index:4]; // 500Hz 削闷
            [zegoApi setAudioEqualizerGain:14.0f  index:5]; // 1kHz 咬字
            [zegoApi setAudioEqualizerGain:22.0f  index:6]; // 2kHz 穿透
            [zegoApi setAudioEqualizerGain:24.0f  index:7]; // 4kHz 极致清晰
            [zegoApi setAudioEqualizerGain:18.0f + airBoost index:8]; // 8kHz 泛音明亮
            [zegoApi setAudioEqualizerGain:12.0f + airBoost * 0.8f index:9]; // 16kHz 空气感
        } else if (kCurrentFightMode == FightMode_Old) {
            // 旧清晰：饱满浑厚，中低频适度保留
            float airBoost = kPCSoundCardMode ? (4.0f * kPCSoundCardAir) : 0.0f;
            float chestBoost = kPCSoundCardMode ? (3.0f * kPCSoundCardChest) : 0.0f;
            [zegoApi setAudioEqualizerGain:-4.0f  index:0]; // 31Hz
            [zegoApi setAudioEqualizerGain:6.0f + chestBoost * 0.5f index:1]; // 62Hz
            [zegoApi setAudioEqualizerGain:10.0f + chestBoost index:2]; // 125Hz 胸腔
            [zegoApi setAudioEqualizerGain:-2.0f  index:3]; // 250Hz 微削
            [zegoApi setAudioEqualizerGain:-4.0f  index:4]; // 500Hz 削闷
            [zegoApi setAudioEqualizerGain:16.0f  index:5]; // 1kHz
            [zegoApi setAudioEqualizerGain:24.0f  index:6]; // 2kHz
            [zegoApi setAudioEqualizerGain:24.0f  index:7]; // 4kHz
            [zegoApi setAudioEqualizerGain:20.0f + airBoost index:8]; // 8kHz
            [zegoApi setAudioEqualizerGain:14.0f + airBoost * 0.8f index:9]; // 16kHz
        } else if (kCurrentFightMode == FightMode_Super) {
            // 震撼超级压制：胸腔共鸣 + 极致清晰穿透（清晰度优化版）
            float airBoost = kPCSoundCardMode ? (6.0f * kPCSoundCardAir) : 0.0f;
            float chestBoost = kPCSoundCardMode ? (4.0f * kPCSoundCardChest) : 0.0f;
            [zegoApi setAudioEqualizerGain:4.0f + chestBoost * 0.3f index:0]; // 31Hz 微增
            [zegoApi setAudioEqualizerGain:12.0f + chestBoost * 0.6f index:1]; // 62Hz 冲击力
            [zegoApi setAudioEqualizerGain:18.0f + chestBoost index:2]; // 125Hz 胸腔厚重共鸣
            [zegoApi setAudioEqualizerGain:6.0f + chestBoost * 0.4f index:3]; // 250Hz 适度饱满（降低防浑浊）
            [zegoApi setAudioEqualizerGain:2.0f   index:4]; // 500Hz 微增（降低防闷）
            [zegoApi setAudioEqualizerGain:24.0f  index:5]; // 1kHz 咬字清晰（顶格）
            [zegoApi setAudioEqualizerGain:24.0f  index:6]; // 2kHz 穿透压制（顶格）
            [zegoApi setAudioEqualizerGain:24.0f  index:7]; // 4kHz 声学掩蔽（顶格）
            [zegoApi setAudioEqualizerGain:22.0f + airBoost index:8]; // 8kHz 泛音明亮（提升清晰度）
            [zegoApi setAudioEqualizerGain:16.0f + airBoost * 0.8f index:9]; // 16kHz 空气感
        }
    }
}

// AUX 混音 PCM 生成
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

// ========================================================================
// Part 4: v8.5 Hook 层（SKAudioZegoManager + ZegoAudioRoomApi + ZegoAudioAux）
// ========================================================================
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
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    }
}
- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic) %orig(NO);
    else %orig(mute);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}
- (void)startPublishing {
    %orig;
    g_isPublishing = YES;
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

// ========================================================================
// Part 5: 0.8s 保活守护线程（v8.5 核心：持续重申增益与 EQ 防漂移）
// ========================================================================
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
                        if (kAudioInjection && [g_activeZegoEngine respondsToSelector:@selector(setAuxVolume:)]) {
                            [g_activeZegoEngine setAuxVolume:100];
                        }
                    }
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ========================================================================
// Part 6: HUD 控制面板（v8.5 布局 + v10.0.0 Hyper 驱动滑块）
// ========================================================================
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
@property (nonatomic, strong) UISwitch *swHyper;
@property (nonatomic, strong) UISwitch *swPCSoundCard;  // v12.0 模拟电脑声卡
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

static BattleMasterHUD *g_hudInstance = nil;
static NSTimeInterval g_lastTapStamp = 0;

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
        self.debugPageView.contentSize = CGSizeMake(rw, 400);
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
    proc.text = @"声控物语 v12.0 (PC声卡模拟版)";
    proc.textColor = [UIColor whiteColor];
    proc.font = [UIFont systemFontOfSize:11];
    proc.textAlignment = NSTextAlignmentCenter;
    proc.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    proc.layer.cornerRadius = 10;
    proc.clipsToBounds = YES;
    [self.funcPageView addSubview:proc];

    NSArray *titles = @[@"强制开麦", @"全房信号注入", @"Hyper二级增强", @"模拟电脑声卡", @"新清晰效果", @"旧清晰效果", @"超级震撼压制"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 30 + i * 32, self.funcPageView.frame.size.width - 16, 28)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 5;
        [self.funcPageView addSubview:row];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 2, 140, 24)];
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
        if (i == 2) { self.swHyper = sw; [sw setOn:kHyperEnhance]; }
        if (i == 3) { self.swPCSoundCard = sw; [sw setOn:kPCSoundCardMode]; }
        if (i == 4) self.swNewFight = sw;
        if (i == 5) self.swOldFight = sw;
        if (i == 6) { self.swSuperFight = sw; [sw setOn:YES]; }
    }
}

- (void)setupDebugPage {
    NSArray *items = @[
        @"新清晰音量 (默认400)",
        @"旧清晰音量 (默认800)",
        @"超级震撼增益 (至5000)",
        @"人声动态权重 (至3.0)",
        @"Hyper驱动强度 (至2.8)",
        @"虚拟话放增益 (1.0~6.0)",
        @"PC声卡立体声展宽 (1.0~2.5)",
        @"PC声卡高频泛音 (0.5~2.0)",
        @"PC声卡胸腔压迫 (0.5~2.0)"
    ];
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
        if (i == 2) { slider.minimumValue = 500; slider.maximumValue = 5000; slider.value = kSuperFightGain; }
        if (i == 3) { slider.minimumValue = 0.5; slider.maximumValue = 3.0;  slider.value = kVoiceGainRatio; }
        if (i == 4) { slider.minimumValue = 1.0; slider.maximumValue = 2.8;  slider.value = kHyperDrive; }
        if (i == 5) { slider.minimumValue = 1.0; slider.maximumValue = 6.0;  slider.value = kVirtualPreAmp; }
        if (i == 6) { slider.minimumValue = 1.0; slider.maximumValue = 2.5;  slider.value = kPCSoundCardWidth; }
        if (i == 7) { slider.minimumValue = 0.5; slider.maximumValue = 2.0;  slider.value = kPCSoundCardAir; }
        if (i == 8) { slider.minimumValue = 0.5; slider.maximumValue = 2.0;  slider.value = kPCSoundCardChest; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
    self.debugPageView.contentSize = CGSizeMake(self.debugPageView.frame.size.width, 8 + items.count * 58 + 20);
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
    if (s.tag == 504) kHyperDrive = s.value;
    if (s.tag == 505) kVirtualPreAmp = s.value;
    if (s.tag == 506) kPCSoundCardWidth = s.value;
    if (s.tag == 507) kPCSoundCardAir = s.value;
    if (s.tag == 508) kPCSoundCardChest = s.value;
    ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
}

- (void)onFuncSwitch:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swInjection) {
        kAudioInjection = s.isOn;
        if (g_activeZegoEngine && [g_activeZegoEngine respondsToSelector:@selector(enableAux:)]) {
            [g_activeZegoEngine enableAux:kAudioInjection];
            if (kAudioInjection) [g_activeZegoEngine setAuxVolume:100];
        }
    }
    if (s == self.swHyper) kHyperEnhance = s.isOn;
    if (s == self.swPCSoundCard) {
        kPCSoundCardMode = s.isOn;
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

// ========================================================================
// Part 7: 手势挂载与构造函数
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
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 285, 260)];
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
