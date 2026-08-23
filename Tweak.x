#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>
#import <stdlib.h>
#import <pthread.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击 (500 音量 + 电视雪花撕扯)
    FightMode_Old,      // 旧清晰搏击 (1000 音量 + 强力雪花嗡鸣)
    FightMode_Super     // 超级战斗 (1500 音量 + 极限无信号爆裂)
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

static float kNewFightGain = 500.0f;
static float kOldFightGain = 1000.0f;
static float kSuperFightGain = 1500.0f;
static float kVoiceGainRatio = 1.0f;

static NSString *kCurrentMusicFile = nil;
static __weak id g_activeZegoApi = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// 线程安全互斥锁与动态导入 PCM 内存池
static pthread_mutex_t g_pcmMutex = PTHREAD_MUTEX_INITIALIZER;
static int16_t *g_customPcmBuffer = NULL;
static size_t g_customPcmSize = 0;
static size_t g_customPcmOffset = 0;

// 内置默认 PCM 环形缓冲区
#define EMBEDDED_PCM_LEN 44100
static int16_t g_embeddedPcmBuffer[EMBEDDED_PCM_LEN];
static size_t g_embeddedPcmOffset = 0;

// 本地试听播放器
static AVAudioPlayer *g_safeTestPlayer = nil;

@interface NSObject (ZegoStandardDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)enableMic:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (void)enableAux:(bool)enable;
- (void)setAudioCaptureShiftOnMix:(bool)enable;
- (void)setAudioAuxDelegate:(id)delegate;
@end

// ---------------------- 前置函数声明 ----------------------
static void InitEmbeddedPCMData(void);
static NSData *WrapPCMToWavData(const int16_t *pcmData, size_t sampleCount, int sampleRate, int channels);
static void LoadMP3ToPCM(NSString *filePath);
static void ApplyPreciseRadioFightDSP(id zegoApi);
static void StartKeepAliveService(void);

// ---------------------- 路径辅助 ----------------------
static NSString *GetSafeDir(NSString *subDir) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [doc stringByAppendingPathComponent:subDir];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

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

// ---------------------- 启动初始化内置 1秒 电视雪花+50Hz强嗡鸣数据 ----------------------
static void InitEmbeddedPCMData() {
    double humPhase = 0.0;
    double tvScanPhase = 0.0;
    double pulsePhase = 0.0;

    for (int i = 0; i < EMBEDDED_PCM_LEN; i++) {
        // 1. 白噪声基底 (-14dB)
        float whiteNoise = (((float)rand() / (float)RAND_MAX) * 2.0f - 1.0f);
        float noiseAmp = 32767.0f * powf(10.0f, -14.0f / 20.0f);

        // 2. 50Hz 工频场电强嗡鸣 (-12dB)
        humPhase += 50.0 / 44100.0;
        if (humPhase >= 1.0) humPhase -= 1.0;
        float hum = sinf(humPhase * 2.0 * M_PI) * (32767.0f * powf(10.0f, -12.0f / 20.0f));

        // 3. 15.625kHz 显像管高频载波
        tvScanPhase += 15625.0 / 44100.0;
        if (tvScanPhase >= 1.0) tvScanPhase -= 1.0;
        float scan = sinf(tvScanPhase * 2.0 * M_PI) * (noiseAmp * 0.25f);

        // 4. 18Hz 切音撕拉调制
        pulsePhase += 18.0 / 44100.0;
        if (pulsePhase >= 1.0) pulsePhase -= 1.0;
        float pulse = (sinf(pulsePhase * 2.0 * M_PI) > -0.15) ? 1.0f : 0.35f;

        float sample = (whiteNoise * noiseAmp * pulse) + hum + scan;
        if (sample > 32767.0f) sample = 32767.0f;
        if (sample < -32768.0f) sample = -32768.0f;

        g_embeddedPcmBuffer[i] = (int16_t)sample;
    }
}

// ---------------------- 标准 Pull 模式 Aux 数据提供代理 ----------------------
// 引擎每隔 20ms 向代理请求一次数据, 代理直接将内存 PCM 拷贝至 SDK 提供的目标缓冲区
// 完全不丢帧、不卡顿, 由 SDK 负责与麦克风通道混流并推向远端
@interface ZegoAudioAuxProvider : NSObject
+ (instancetype)shared;
@end

@implementation ZegoAudioAuxProvider

+ (instancetype)shared {
    static ZegoAudioAuxProvider *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZegoAudioAuxProvider alloc] init];
    });
    return instance;
}

// Zego 官方标准 Aux Pull 数据索取回调
- (void)onAudioAuxData:(void *)data dataLen:(int *)dataLen sampleRate:(int *)sampleRate channelCount:(int *)channelCount {
    if (!data || !dataLen || *dataLen <= 0 || kCurrentFightMode == FightMode_Normal) {
        if (dataLen) *dataLen = 0;
        return;
    }

    *sampleRate = 44100;
    *channelCount = 1;

    int requiredSamples = *dataLen / (int)sizeof(int16_t);
    int16_t *targetBuffer = (int16_t *)data;

    float gainMultiplier = 1.0f;
    if (kCurrentFightMode == FightMode_Old) gainMultiplier = 1.6f;
    if (kCurrentFightMode == FightMode_Super) gainMultiplier = 2.4f;

    pthread_mutex_lock(&g_pcmMutex);
    if (g_customPcmBuffer && g_customPcmSize > 0) {
        for (int i = 0; i < requiredSamples; i++) {
            int16_t s = g_customPcmBuffer[g_customPcmOffset++];
            if (g_customPcmOffset >= g_customPcmSize) g_customPcmOffset = 0;
            targetBuffer[i] = (int16_t)(s * gainMultiplier);
        }
    } else {
        for (int i = 0; i < requiredSamples; i++) {
            int16_t s = g_embeddedPcmBuffer[g_embeddedPcmOffset++];
            if (g_embeddedPcmOffset >= EMBEDDED_PCM_LEN) g_embeddedPcmOffset = 0;
            targetBuffer[i] = (int16_t)(s * gainMultiplier);
        }
    }
    pthread_mutex_unlock(&g_pcmMutex);
}

// 兼容部分 SDK 版本带 channelIndex 的签名
- (void)onAudioAuxData:(void *)data dataLen:(int *)dataLen sampleRate:(int *)sampleRate channelCount:(int *)channelCount channelIndex:(int)channelIndex {
    [self onAudioAuxData:data dataLen:dataLen sampleRate:sampleRate channelCount:channelCount];
}

@end

// ---------------------- 内存 PCM 数据封装为标准 WAV NSData ----------------------
static NSData *WrapPCMToWavData(const int16_t *pcmData, size_t sampleCount, int sampleRate, int channels) {
    if (!pcmData || sampleCount == 0) return nil;

    uint32_t dataSize = (uint32_t)(sampleCount * sizeof(int16_t));
    uint32_t totalChunkSize = 36 + dataSize;
    uint16_t numChannels = (uint16_t)channels;
    uint32_t sRate = (uint32_t)sampleRate;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);

    NSMutableData *wavData = [NSMutableData dataWithCapacity:44 + dataSize];
    [wavData appendBytes:"RIFF" length:4];
    [wavData appendBytes:&totalChunkSize length:4];
    [wavData appendBytes:"WAVE" length:4];
    [wavData appendBytes:"fmt " length:4];

    uint32_t subchunk1Size = 16;
    uint16_t audioFormat = 1; // PCM
    [wavData appendBytes:&subchunk1Size length:4];
    [wavData appendBytes:&audioFormat length:2];
    [wavData appendBytes:&numChannels length:2];
    [wavData appendBytes:&sRate length:4];
    [wavData appendBytes:&byteRate length:4];
    [wavData appendBytes:&blockAlign length:2];
    [wavData appendBytes:&bitsPerSample length:2];

    [wavData appendBytes:"data" length:4];
    [wavData appendBytes:&dataSize length:4];
    [wavData appendBytes:pcmData length:dataSize];

    return wavData;
}

// ---------------------- 线程安全 MP3 动态导入解码 ----------------------
static void LoadMP3ToPCM(NSString *filePath) {
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) return;

    NSURL *url = [NSURL fileURLWithPath:filePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) return;

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) return;

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO),
        AVSampleRateKey: @(44100),
        AVNumberOfChannelsKey: @(1)
    };

    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    [reader addOutput:output];
    [reader startReading];

    NSMutableData *pcmData = [NSMutableData data];
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer) {
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
            size_t len = CMBlockBufferGetDataLength(block);
            if (len > 0) {
                char *buf = (char *)malloc(len);
                if (buf) {
                    CMBlockBufferCopyDataBytes(block, 0, len, buf);
                    [pcmData appendBytes:buf length:len];
                    free(buf);
                }
            }
            CFRelease(sampleBuffer);
        } else {
            break;
        }
    }

    // 锁外 malloc + memcpy
    if (pcmData.length > 0) {
        size_t newSize = pcmData.length / sizeof(int16_t);
        int16_t *newBuf = (int16_t *)malloc(pcmData.length);
        if (!newBuf) return;
        memcpy(newBuf, pcmData.bytes, pcmData.length);

        int16_t *oldBufToFree = NULL;
        pthread_mutex_lock(&g_pcmMutex);
        oldBufToFree = g_customPcmBuffer;
        g_customPcmBuffer = newBuf;
        g_customPcmSize = newSize;
        g_customPcmOffset = 0;
        pthread_mutex_unlock(&g_pcmMutex);

        if (oldBufToFree) {
            free(oldBufToFree);
        }
    }
}

// ---------------------- 核心调音、Aux 代理绑定与 3A 锁定 ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAux:)]) [zegoApi enableAux:NO];
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            for (int i = 0; i < 10; i++) [zegoApi setAudioEqualizerGain:0.0f index:i];
        }
        return;
    }

    // 1. 注册 Aux Pull 代理并激活混音
    if ([zegoApi respondsToSelector:@selector(setAudioAuxDelegate:)]) {
        [zegoApi setAudioAuxDelegate:[ZegoAudioAuxProvider shared]];
    }
    if ([zegoApi respondsToSelector:@selector(enableAux:)]) {
        [zegoApi enableAux:YES];
    }
    if ([zegoApi respondsToSelector:@selector(setAudioCaptureShiftOnMix:)]) {
        [zegoApi setAudioCaptureShiftOnMix:YES];
    }

    // 2. 彻底关闭 3A
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 3. 麦克风增益与全频段放行
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        [zegoApi setAudioEqualizerGain:8.0f index:0];   // 31Hz
        [zegoApi setAudioEqualizerGain:10.0f index:1];  // 62Hz
        [zegoApi setAudioEqualizerGain:6.0f index:2];   // 125Hz
        [zegoApi setAudioEqualizerGain:2.0f index:3];   // 250Hz
        [zegoApi setAudioEqualizerGain:0.0f index:4];   // 500Hz
        [zegoApi setAudioEqualizerGain:8.0f index:5];   // 1kHz
        [zegoApi setAudioEqualizerGain:12.0f index:6];  // 2kHz
        [zegoApi setAudioEqualizerGain:15.0f index:7];  // 4kHz
        [zegoApi setAudioEqualizerGain:10.0f index:8];  // 8kHz
        [zegoApi setAudioEqualizerGain:8.0f index:9];   // 16kHz
    }
}

// ---------------------- Hook 业务与底层 ----------------------
%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(g_activeZegoApi);
    });
}

- (BOOL)micEnabled {
    if (kForceOpenMic) return YES;
    return %orig;
}

%end

%hook SKMicrophonePermissionManager

+ (BOOL)hasMicrophonePermission {
    if (kForceOpenMic) return YES;
    return %orig;
}

%end

%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    return inst;
}

- (bool)enableMic:(bool)enable {
    g_activeZegoApi = self;
    if (kForceOpenMic) return %orig(YES);
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
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(weakSelf);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(weakSelf);
    });
    return res;
}

%end

// ---------------------- 保活线程 ----------------------
static void StartKeepAliveService() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.8 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_activeZegoApi && kCurrentFightMode != FightMode_Normal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ApplyPreciseRadioFightDSP(g_activeZegoApi);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- 音乐管理视图 ----------------------
@interface MusicManagerView : UIView <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *musicFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation MusicManagerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.musicFiles = [NSMutableArray array];

        UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        importBtn.frame = CGRectMake(8, 8, 70, 26);
        [importBtn setTitle:@"+ 导入" forState:UIControlStateNormal];
        [importBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        importBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        importBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        importBtn.layer.cornerRadius = 6;
        [importBtn addTarget:self action:@selector(importMusic) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:importBtn];

        UIButton *stopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        stopBtn.frame = CGRectMake(84, 8, 55, 26);
        [stopBtn setTitle:@"停止" forState:UIControlStateNormal];
        [stopBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        stopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        stopBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:1.0];
        stopBtn.layer.cornerRadius = 6;
        [stopBtn addTarget:self action:@selector(stopPlayMusic) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:stopBtn];

        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        resetBtn.frame = CGRectMake(143, 8, 55, 26);
        [resetBtn setTitle:@"默认噪音" forState:UIControlStateNormal];
        [resetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        resetBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        resetBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1.0];
        resetBtn.layer.cornerRadius = 6;
        [resetBtn addTarget:self action:@selector(loadDefaultNoise) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:resetBtn];

        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(202, 8, frame.size.width - 207, 26)];
        self.statusLabel.text = @"默认内置雪花嗡鸣";
        self.statusLabel.font = [UIFont systemFontOfSize:10];
        self.statusLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
        [self addSubview:self.statusLabel];

        self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(5, 38, frame.size.width - 10, frame.size.height - 42) style:UITableViewStylePlain];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.delegate = self;
        self.tableView.dataSource = self;
        self.tableView.rowHeight = 36;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        [self addSubview:self.tableView];

        [self refreshFileList];
    }
    return self;
}

- (void)refreshFileList {
    [self.musicFiles removeAllObjects];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:GetSafeDir(@"FightMusic") error:nil];
    for (NSString *f in files) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"mp3"] || [f.pathExtension.lowercaseString isEqualToString:@"wav"] || [f.pathExtension.lowercaseString isEqualToString:@"m4a"]) {
            [self.musicFiles addObject:f];
        }
    }
    [self.tableView reloadData];
}

- (void)importMusic {
    UIWindow *keyWindow = GetKeyWindow();
    UIViewController *rootVC = keyWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio", @"public.mp3"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [rootVC presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        NSString *dest = [GetSafeDir(@"FightMusic") stringByAppendingPathComponent:url.lastPathComponent];
        [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dest error:nil];
    }
    [self refreshFileList];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.musicFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MusicItemCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MusicItemCell"];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        cell.layer.cornerRadius = 6;
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:11];

        UIView *action = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 95, 26)];
        UIButton *send = [UIButton buttonWithType:UIButtonTypeCustom];
        send.frame = CGRectMake(0, 2, 48, 22);
        [send setTitle:@"上麦发" forState:UIControlStateNormal];
        [send setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        send.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        send.backgroundColor = [UIColor colorWithRed:0.25 green:0.75 blue:0.35 alpha:1.0];
        send.layer.cornerRadius = 4;
        send.tag = 100;
        [action addSubview:send];

        UIButton *del = [UIButton buttonWithType:UIButtonTypeCustom];
        del.frame = CGRectMake(52, 2, 40, 22);
        [del setTitle:@"删除" forState:UIControlStateNormal];
        [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        del.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        del.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:1.0];
        del.layer.cornerRadius = 4;
        del.tag = 200;
        [action addSubview:del];
        cell.accessoryView = action;
    }

    cell.textLabel.text = self.musicFiles[indexPath.row];

    UIButton *s = (UIButton *)[cell.accessoryView viewWithTag:100];
    UIButton *d = (UIButton *)[cell.accessoryView viewWithTag:200];

    [s removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [d removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    s.tag = indexPath.row;
    d.tag = indexPath.row;

    [s addTarget:self action:@selector(publishTrack:) forControlEvents:UIControlEventTouchUpInside];
    [d addTarget:self action:@selector(deleteTrack:) forControlEvents:UIControlEventTouchUpInside];

    return cell;
}

- (void)publishTrack:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.musicFiles.count) return;
    kCurrentMusicFile = self.musicFiles[btn.tag];
    self.statusLabel.text = [NSString stringWithFormat:@"推流中: %@", kCurrentMusicFile];
    LoadMP3ToPCM([GetSafeDir(@"FightMusic") stringByAppendingPathComponent:kCurrentMusicFile]);
}

- (void)deleteTrack:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.musicFiles.count) return;
    NSString *f = self.musicFiles[btn.tag];
    [[NSFileManager defaultManager] removeItemAtPath:[GetSafeDir(@"FightMusic") stringByAppendingPathComponent:f] error:nil];
    if ([kCurrentMusicFile isEqualToString:f]) [self stopPlayMusic];
    [self.musicFiles removeObjectAtIndex:btn.tag];
    [self.tableView reloadData];
}

- (void)loadDefaultNoise {
    int16_t *bufToFree = NULL;
    pthread_mutex_lock(&g_pcmMutex);
    bufToFree = g_customPcmBuffer;
    g_customPcmBuffer = NULL;
    g_customPcmSize = 0;
    g_customPcmOffset = 0;
    pthread_mutex_unlock(&g_pcmMutex);

    if (bufToFree) {
        free(bufToFree);
    }

    kCurrentMusicFile = nil;
    self.statusLabel.text = @"默认内置雪花嗡鸣";
}

- (void)stopPlayMusic {
    int16_t *bufToFree = NULL;
    pthread_mutex_lock(&g_pcmMutex);
    bufToFree = g_customPcmBuffer;
    g_customPcmBuffer = NULL;
    g_customPcmSize = 0;
    g_customPcmOffset = 0;
    pthread_mutex_unlock(&g_pcmMutex);

    if (bufToFree) {
        free(bufToFree);
    }
    kCurrentMusicFile = nil;
    self.statusLabel.text = @"已切回内置雪花";
}

@end

// ---------------------- 设置页 (强制扬声器外放 + 确保内存就绪) ----------------------
@interface SettingManagerView : UIView
@property (nonatomic, strong) UILabel *testStatusLabel;
@end

@implementation SettingManagerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        // 打开设置页时再次确保内置 PCM 有数据
        InitEmbeddedPCMData();

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, frame.size.width - 24, 22)];
        title.text = @"本地音频监听测试：";
        title.font = [UIFont boldSystemFontOfSize:12.5];
        title.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
        [self addSubview:title];

        UIButton *startTestBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        startTestBtn.frame = CGRectMake(12, 45, 85, 30);
        [startTestBtn setTitle:@"开始试听" forState:UIControlStateNormal];
        [startTestBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        startTestBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        startTestBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.95 alpha:1.0];
        startTestBtn.layer.cornerRadius = 6;
        [startTestBtn addTarget:self action:@selector(startTestAudio) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:startTestBtn];

        UIButton *stopTestBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        stopTestBtn.frame = CGRectMake(108, 45, 85, 30);
        [stopTestBtn setTitle:@"停止试听" forState:UIControlStateNormal];
        [stopTestBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        stopTestBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        stopTestBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.3 blue:0.3 alpha:1.0];
        stopTestBtn.layer.cornerRadius = 6;
        [stopTestBtn addTarget:self action:@selector(stopTestAudio) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:stopTestBtn];

        self.testStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 85, frame.size.width - 24, 48)];
        self.testStatusLabel.text = @"内置雪花与50Hz强嗡鸣已就绪。点击「开始试听」将在耳机/外放扬声器播放。";
        self.testStatusLabel.numberOfLines = 0;
        self.testStatusLabel.font = [UIFont systemFontOfSize:10.5];
        self.testStatusLabel.textColor = [UIColor whiteColor];
        [self addSubview:self.testStatusLabel];

        // 版本信息
        CGFloat y = 143;
        NSArray *info = @[
            @"FightVoicePro v2.8.0",
            @"",
            @"推流模式: Pull 代理注入 (标准模式)",
            @"  ZegoAudioAuxProvider 单例",
            @"  onAudioAuxData:dataLen:",
            @"  引擎20ms索取, 零丢帧",
            @"",
            @"内置PCM: 纯内存硬编码合成",
            @"  constructor注入即生成",
            @"  白噪声 -14dB + 50Hz嗡鸣 -12dB",
            @"  15625Hz行频 + 18Hz撕拉切音",
            @"",
            @"本地试听: AVAudioPlayer (安全模式)",
            @"  内存PCM封装44字节WAV头",
            @"  强制外放 overrideOutputAudioPort",
            @"  Playback模式 + MixWithOthers",
            @"",
            @"Aux 混音: 三步联动",
            @"  setAudioAuxDelegate: + enableAux:",
            @"  + setAudioCaptureShiftOnMix:",
            @"",
            @"线程安全: pthread_mutex + Double-buffering",
            @"3A 状态: AGC/ANS/AEC 强制关闭",
            @"EQ: 全频段直通 20Hz~20kHz",
            @"保活: 0.8s 定时刷新 DSP",
            @"",
            @"构建: GitHub Actions CI"
        ];

        for (NSString *line in info) {
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, frame.size.width - 24, 18)];
            lbl.text = line;
            lbl.font = [UIFont systemFontOfSize:10];
            if (line.length > 0 && [line characterAtIndex:0] == ' ') {
                lbl.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
            } else if (line.length > 0 && [line containsString:@":"]) {
                lbl.textColor = [UIColor colorWithRed:0.9 green:0.8 blue:0.4 alpha:1.0];
                lbl.font = [UIFont boldSystemFontOfSize:10.5];
            } else {
                lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
            }
            [self addSubview:lbl];
            y += 18;
        }

        UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
        scroll.contentSize = CGSizeMake(frame.size.width, y + 10);
        scroll.backgroundColor = [UIColor clearColor];
        scroll.showsVerticalScrollIndicator = YES;
        for (UIView *sub in [self.subviews copy]) {
            if (sub != scroll) {
                [sub removeFromSuperview];
                [scroll addSubview:sub];
            }
        }
        [self addSubview:scroll];
    }
    return self;
}

- (void)startTestAudio {
    [self stopTestAudio];

    InitEmbeddedPCMData();

    pthread_mutex_lock(&g_pcmMutex);
    int16_t *srcBuf = (g_customPcmBuffer && g_customPcmSize > 0) ? g_customPcmBuffer : g_embeddedPcmBuffer;
    size_t srcLen = (g_customPcmBuffer && g_customPcmSize > 0) ? g_customPcmSize : EMBEDDED_PCM_LEN;

    NSData *wavData = WrapPCMToWavData(srcBuf, srcLen, 44100, 1);
    pthread_mutex_unlock(&g_pcmMutex);

    if (!wavData) {
        self.testStatusLabel.text = @"音频数据装配失败。";
        return;
    }

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
    [session setActive:YES error:&err];
    [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];

    g_safeTestPlayer = [[AVAudioPlayer alloc] initWithData:wavData error:&err];
    if (err || !g_safeTestPlayer) {
        self.testStatusLabel.text = [NSString stringWithFormat:@"播放失败: %@", err.localizedDescription];
        return;
    }

    g_safeTestPlayer.numberOfLoops = -1;
    g_safeTestPlayer.volume = 1.0f;
    [g_safeTestPlayer prepareToPlay];
    [g_safeTestPlayer play];

    self.testStatusLabel.text = kCurrentMusicFile ? [NSString stringWithFormat:@"正在试听MP3: %@", kCurrentMusicFile] : @"正在试听: 内置电台雪花+50Hz强嗡鸣 (大声播放中)";
}

- (void)stopTestAudio {
    if (g_safeTestPlayer && [g_safeTestPlayer isPlaying]) {
        [g_safeTestPlayer stop];
    }
    g_safeTestPlayer = nil;
    self.testStatusLabel.text = @"已停止试听。";
}

@end

// ---------------------- 主面板 HUD ----------------------
@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;
@property (nonatomic, strong) MusicManagerView *musicPageView;
@property (nonatomic, strong) SettingManagerView *settingPageView;
@property (nonatomic, strong) UISwitch *swForceMic;
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
        pan.delegate = self;
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

        CGFloat rw = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIScrollView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.debugPageView.contentSize = CGSizeMake(rw, 280);
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        self.musicPageView = [[MusicManagerView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.musicPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.musicPageView.hidden = YES;
        [self addSubview:self.musicPageView];

        self.settingPageView = [[SettingManagerView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.settingPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.settingPageView.hidden = YES;
        [self addSubview:self.settingPageView];

        [self setupFuncPage];
        [self setupDebugPage];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:self.musicPageView.tableView] ||
        [touch.view isDescendantOfView:self.debugPageView] ||
        [touch.view isDescendantOfView:self.settingPageView]) {
        return NO;
    }
    return YES;
}

- (void)setupFuncPage {
    UILabel *proc = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, self.funcPageView.frame.size.width - 24, 24)];
    proc.text = @"选择进程: 声控物语 (活跃)";
    proc.textColor = [UIColor whiteColor];
    proc.font = [UIFont systemFontOfSize:11.5];
    proc.textAlignment = NSTextAlignmentCenter;
    proc.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    proc.layer.cornerRadius = 12;
    proc.clipsToBounds = YES;
    [self.funcPageView addSubview:proc];

    NSArray *titles = @[@"强制开麦", @"屏蔽滋啦杂音", @"新清晰搏击效果", @"旧清晰搏击效果", @"超级战斗效果"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 38 + i * 36, self.funcPageView.frame.size.width - 16, 32)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 6;
        [self.funcPageView addSubview:row];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 120, 24)];
        lbl.text = titles[i];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:12];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 50, 1, 40, 24)];
        sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        [sw addTarget:self action:@selector(onFuncSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        if (i == 0) { self.swForceMic = sw; [sw setOn:kForceOpenMic]; }
        if (i == 1) { /* 屏蔽滋啦杂音 - 预留 */ }
        if (i == 2) { self.swNewFight = sw; [sw setOn:YES]; }
        if (i == 3) self.swOldFight = sw;
        if (i == 4) self.swSuperFight = sw;
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"新清晰音量 (默认500)", @"旧清晰音量 (默认1000)", @"超级战斗音量 (默认1500)", @"人声音量权重"];
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
        if (i == 1) { slider.minimumValue = 500; slider.maximumValue = 2000; slider.value = kOldFightGain; }
        if (i == 2) { slider.minimumValue = 1000; slider.maximumValue = 3000; slider.value = kSuperFightGain; }
        if (i == 3) { slider.minimumValue = 0.5f; slider.maximumValue = 2.0f; slider.value = kVoiceGainRatio; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)btn {
    self.funcPageView.hidden = (btn.tag != 200);
    self.debugPageView.hidden = (btn.tag != 201);
    self.musicPageView.hidden = (btn.tag != 202);
    self.settingPageView.hidden = (btn.tag != 203);
    if (btn.tag == 202) [self.musicPageView refreshFileList];
}

- (void)onSliderChanged:(UISlider *)slider {
    if (slider.tag == 500) kNewFightGain = slider.value;
    if (slider.tag == 501) kOldFightGain = slider.value;
    if (slider.tag == 502) kSuperFightGain = slider.value;
    if (slider.tag == 503) kVoiceGainRatio = slider.value;
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)onFuncSwitch:(UISwitch *)sender {
    if (sender == self.swForceMic) kForceOpenMic = sender.isOn;
    if (sender == self.swNewFight) {
        if (sender.isOn) { kCurrentFightMode = FightMode_New; [self.swOldFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (sender == self.swOldFight) {
        if (sender.isOn) { kCurrentFightMode = FightMode_Old; [self.swNewFight setOn:NO animated:YES]; [self.swSuperFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    if (sender == self.swSuperFight) {
        if (sender.isOn) { kCurrentFightMode = FightMode_Super; [self.swNewFight setOn:NO animated:YES]; [self.swOldFight setOn:NO animated:YES]; }
        else { kCurrentFightMode = FightMode_Normal; }
    }
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 双指双击手势 ----------------------
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
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 285, 240)];
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

// ---------------------- 注入启动 (合并 UIWindow hook) ----------------------
%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    StartKeepAliveService();
    [[HUDGestureHandler shared] attachToWindow:self];
}

%end

// ---------------------- 构造函数: 动态库加载即初始化 PCM 数据 ----------------------
__attribute__((constructor)) static void InitializeTweak() {
    InitEmbeddedPCMData();
}
