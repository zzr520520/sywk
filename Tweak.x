#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击 (-18dB 电台噪声 + 50Hz 嗡鸣)
    FightMode_Old,      // 旧清晰搏击 (-15dB 强力撕扯 + 50Hz 强嗡鸣)
    FightMode_Super     // 超级战斗 (-12dB 极限撕扯爆破 + 50Hz 极限嗡鸣)
} FightAudioMode;

static BOOL kForceOpenMic = YES;      // 强制开麦默认开启
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

// 增益控制
static float kNewFightGain = 500.0f;
static float kOldFightGain = 1000.0f;
static float kSuperFightGain = 1500.0f;
static float kVoiceGainRatio = 1.0f;

static NSString *kCurrentMusicFile = nil;

static __weak id g_activeZegoApi = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// MP3 推流内存池
static int16_t *g_musicPcmBuffer = NULL;
static size_t g_musicPcmSize = 0;
static size_t g_musicPcmOffset = 0;

// 信号发生器相位累加器
static double g_hum50HzPhase = 0.0;    // 50Hz 正弦波相位
static double g_tearCarrierPhase = 0.0; // 撕扯载波相位
static double g_pulsePhase = 0.0;      // 脉冲调制相位

@interface NSObject (ZegoAPIs)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)enableMic:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
@end

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

// ---------------------- 硬件级 PCM 撕裂 + 50Hz 嗡鸣 DSP ----------------------
static inline int16_t ProcessBattleDSP(int16_t inputSample, float gain, float noiseLevelDB, float humLevelDB) {
    // 1. 人声音量直接线性放大
    float sample = (float)inputSample * (gain / 100.0f);

    // 2. 叠加 50Hz 强正弦波嗡鸣 (-15dB 左右：amplitude ≈ 32767 * 10^(dB/20))
    g_hum50HzPhase += 50.0 / 44100.0;
    if (g_hum50HzPhase >= 1.0) g_hum50HzPhase -= 1.0;
    float humAmp = 32767.0f * powf(10.0f, humLevelDB / 20.0f);
    float humSignal = sinf(g_hum50HzPhase * 2.0 * M_PI) * humAmp;

    // 3. 产生 -12dB ~ -18dB 明显响亮的机械电台撕拉调制
    g_pulsePhase += 16.0 / 44100.0;
    if (g_pulsePhase >= 1.0) g_pulsePhase -= 1.0;
    float pulse = (sinf(g_pulsePhase * 2.0 * M_PI) > 0.0) ? 1.0f : 0.35f;

    g_tearCarrierPhase += 2200.0 / 44100.0;
    if (g_tearCarrierPhase >= 1.0) g_tearCarrierPhase -= 1.0;
    float noiseAmp = 32767.0f * powf(10.0f, noiseLevelDB / 20.0f);
    float tearNoise = sinf(g_tearCarrierPhase * 2.0 * M_PI) * noiseAmp * pulse;

    // 4. 全频段混合 (人声 + 50Hz嗡鸣 + 响亮机械撕裂噪声)
    sample = (sample * pulse) + humSignal + tearNoise;

    // 5. 硬削顶 (Hard-Clipping 保持过载失真感)
    if (sample > 32767.0f) sample = 32767.0f;
    if (sample < -32768.0f) sample = -32768.0f;

    return (int16_t)sample;
}

// ---------------------- 核心 Hook: 强制开麦与音频流 ----------------------
// 1. 强制拦截业务层 SKAudioZegoManager 开麦状态
%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
}

- (BOOL)micEnabled {
    if (kForceOpenMic) return YES;
    return %orig;
}

%end

// 2. 拦截麦克风权限管理器
%hook SKMicrophonePermissionManager

+ (BOOL)hasMicrophonePermission {
    if (kForceOpenMic) return YES;
    return %orig;
}

%end

// 3. 拦截 ZegoLiveRoomApi
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

// 拦截底层麦克风采集帧，全通灌入 DSP 与 MP3
- (void)onCaptureAudioFrame:(void *)audioFrame {
    %orig;
    if (!audioFrame || kCurrentFightMode == FightMode_Normal) return;

    int16_t *samples = (int16_t *)*(void **)audioFrame;
    int sampleCount = *(int *)((char *)audioFrame + sizeof(void *));
    if (!samples || sampleCount <= 0) return;

    float gain = kNewFightGain;
    float noiseDB = -18.0f;
    float humDB = -15.0f;

    if (kCurrentFightMode == FightMode_Old) {
        gain = kOldFightGain;
        noiseDB = -15.0f;
        humDB = -13.0f;
    } else if (kCurrentFightMode == FightMode_Super) {
        gain = kSuperFightGain;
        noiseDB = -12.0f;
        humDB = -11.0f;
    }

    gain *= kVoiceGainRatio;

    for (int i = 0; i < sampleCount; i++) {
        // 混入 MP3
        if (g_musicPcmBuffer && g_musicPcmSize > 0) {
            int16_t music = g_musicPcmBuffer[g_musicPcmOffset++];
            if (g_musicPcmOffset >= g_musicPcmSize) g_musicPcmOffset = 0;
            samples[i] = (int16_t)((samples[i] + music) / 2);
        }
        // 注入 50Hz 嗡鸣与机械撕扯
        samples[i] = ProcessBattleDSP(samples[i], gain, noiseDB, humDB);
    }
}

%end

// ---------------------- 彻底禁用 3A 与保留全频段 ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

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

    // 必须关闭：自动增益、降噪、瞬态噪声抑制、噪声门
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 全频段 EQ 直通放行，禁用高通/低切，低频段微调提升
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        [zegoApi setAudioEqualizerGain:6.0f index:0];  // 31Hz 保留低频嗡鸣
        [zegoApi setAudioEqualizerGain:8.0f index:1];  // 62Hz 50Hz正弦波增强区
        [zegoApi setAudioEqualizerGain:4.0f index:2];  // 125Hz
        [zegoApi setAudioEqualizerGain:0.0f index:3];  // 250Hz 直通
        [zegoApi setAudioEqualizerGain:0.0f index:4];  // 500Hz 直通
        [zegoApi setAudioEqualizerGain:6.0f index:5];  // 1kHz
        [zegoApi setAudioEqualizerGain:10.0f index:6]; // 2kHz
        [zegoApi setAudioEqualizerGain:12.0f index:7]; // 4kHz 清晰齿音
        [zegoApi setAudioEqualizerGain:8.0f index:8];  // 8kHz
        [zegoApi setAudioEqualizerGain:6.0f index:9];  // 16kHz
    }
}

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

// ---------------------- MP3 解码模块 ----------------------
static void LoadMP3ToPCM(NSString *filePath) {
    if (g_musicPcmBuffer) {
        free(g_musicPcmBuffer);
        g_musicPcmBuffer = NULL;
        g_musicPcmSize = 0;
        g_musicPcmOffset = 0;
    }
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
            char *buf = (char *)malloc(len);
            CMBlockBufferCopyDataBytes(block, 0, len, buf);
            [pcmData appendBytes:buf length:len];
            free(buf);
            CFRelease(sampleBuffer);
        } else {
            break;
        }
    }

    if (pcmData.length > 0) {
        g_musicPcmSize = pcmData.length / sizeof(int16_t);
        g_musicPcmBuffer = (int16_t *)malloc(pcmData.length);
        if (g_musicPcmBuffer) {
            memcpy(g_musicPcmBuffer, pcmData.bytes, pcmData.length);
            g_musicPcmOffset = 0;
        }
    }
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

        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(145, 8, frame.size.width - 150, 26)];
        self.statusLabel.text = @"未推流音乐";
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

- (void)stopPlayMusic {
    if (g_musicPcmBuffer) {
        free(g_musicPcmBuffer);
        g_musicPcmBuffer = NULL;
        g_musicPcmSize = 0;
        g_musicPcmOffset = 0;
    }
    kCurrentMusicFile = nil;
    self.statusLabel.text = @"已停止推流";
}

@end

// ---------------------- 主面板 HUD ----------------------
@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;
@property (nonatomic, strong) MusicManagerView *musicPageView;
@property (nonatomic, strong) UIView *settingPageView;
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

        self.settingPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rw, frame.size.height)];
        self.settingPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.settingPageView.hidden = YES;
        [self addSubview:self.settingPageView];

        [self setupFuncPage];
        [self setupDebugPage];
        [self setupSettingPage];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:self.musicPageView.tableView] ||
        [touch.view isDescendantOfView:self.debugPageView]) {
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

- (void)setupSettingPage {
    NSArray *info = @[
        @"FightVoicePro v2.1.0",
        @"",
        @"DSP 参数:",
        @"  脉冲调制: 16Hz",
        @"  撕扯载波: 2200Hz",
        @"  嗡鸣频率: 50Hz",
        @"  采样率: 44100Hz / 16-bit",
        @"",
        @"强制开麦: 多重Hook拦截",
        @"  - ZegoLiveRoomApi.enableMic:",
        @"  - SKAudioZegoManager.enableMic:",
        @"  - SKMicrophonePermissionManager",
        @"",
        @"3A 状态: AGC/ANS/AEC 强制关闭",
        @"EQ: 全频段直通 (20Hz~20kHz)",
        @"保活: 0.8s 定时刷新 DSP",
        @"",
        @"构建: GitHub Actions CI"
    ];

    CGFloat y = 10;
    for (NSString *line in info) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, self.settingPageView.frame.size.width - 24, 18)];
        lbl.text = line;
        lbl.font = [UIFont systemFontOfSize:10];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        if (line.length > 0 && [line characterAtIndex:0] == ' ') {
            lbl.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        } else if (line.length > 0 && [line containsString:@":"]) {
            lbl.textColor = [UIColor colorWithRed:0.9 green:0.8 blue:0.4 alpha:1.0];
            lbl.font = [UIFont boldSystemFontOfSize:10.5];
        }
        [self.settingPageView addSubview:lbl];
        y += 18;
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

// ---------------------- 双指双击手势唤醒 ----------------------
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

// ---------------------- 注入启动 ----------------------
%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    StartKeepAliveService();
    [[HUDGestureHandler shared] attachToWindow:self];
}

%end
