#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>
#import <stdlib.h>
#import <pthread.h>

#define kDefaultNoiseFile @"/Library/Application Support/com.battlemaster/tv_snow.mp3"

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
static dispatch_source_t g_auxPushTimer = nil;

// 线程安全互斥锁与 PCM 内存池
static pthread_mutex_t g_pcmMutex = PTHREAD_MUTEX_INITIALIZER;
static int16_t *g_musicPcmBuffer = NULL;
static size_t g_musicPcmSize = 0;
static size_t g_musicPcmOffset = 0;

static double g_hum50HzPhase = 0.0;
static double g_tvHScanPhase = 0.0;
static double g_pulsePhase = 0.0;

@interface NSObject (ZegoSDKDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)enableMic:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (void)enableAux:(bool)enable;
- (bool)setAudioAuxData:(const void *)data dataLen:(int)dataLen sampleRate:(int)sampleRate channelCount:(int)channelCount;
@end

// ---------------------- 前置函数声明 ----------------------
static void LoadMP3ToPCM(NSString *filePath);
static void ApplyPreciseRadioFightDSP(id zegoApi);
static void StartAuxDataInjector(void);
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

// ---------------------- 电视无信号雪花合成 ----------------------
static inline int16_t GenerateTVSnowSample(float noiseLevelDB, float humLevelDB) {
    float whiteNoise = (((float)rand() / (float)RAND_MAX) * 2.0f - 1.0f);
    float noiseAmp = 32767.0f * powf(10.0f, noiseLevelDB / 20.0f);

    g_hum50HzPhase += 50.0 / 44100.0;
    if (g_hum50HzPhase >= 1.0) g_hum50HzPhase -= 1.0;
    float humAmp = 32767.0f * powf(10.0f, humLevelDB / 20.0f);
    float hum = sinf(g_hum50HzPhase * 2.0 * M_PI) * humAmp;

    g_tvHScanPhase += 15625.0 / 44100.0;
    if (g_tvHScanPhase >= 1.0) g_tvHScanPhase -= 1.0;
    float hScan = sinf(g_tvHScanPhase * 2.0 * M_PI) * (noiseAmp * 0.15f);

    g_pulsePhase += 20.0 / 44100.0;
    if (g_pulsePhase >= 1.0) g_pulsePhase -= 1.0;
    float tearMod = (sinf(g_pulsePhase * 2.0 * M_PI) > -0.2) ? 1.0f : 0.3f;

    float result = (whiteNoise * noiseAmp * tearMod) + hum + hScan;
    if (result > 32767.0f) result = 32767.0f;
    if (result < -32768.0f) result = -32768.0f;
    return (int16_t)result;
}

// ---------------------- 线程安全 MP3 解码 ----------------------
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

    // 锁外 malloc + memcpy (耗时操作不阻塞音频推流线程)
    if (pcmData.length > 0) {
        size_t newSize = pcmData.length / sizeof(int16_t);
        int16_t *newBuf = (int16_t *)malloc(pcmData.length);
        if (!newBuf) return;
        memcpy(newBuf, pcmData.bytes, pcmData.length);

        // 锁内仅做原子指针置换 (极短临界区)
        int16_t *oldBufToFree = NULL;
        pthread_mutex_lock(&g_pcmMutex);
        oldBufToFree = g_musicPcmBuffer;
        g_musicPcmBuffer = newBuf;
        g_musicPcmSize = newSize;
        g_musicPcmOffset = 0;
        pthread_mutex_unlock(&g_pcmMutex);

        // 锁外释放旧缓冲区 (避免 free 阻塞音频线程)
        if (oldBufToFree) {
            free(oldBufToFree);
        }
    }
}

// ---------------------- Aux 持续灌流 ----------------------
static void StartAuxDataInjector() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LoadMP3ToPCM(kDefaultNoiseFile);

        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_auxPushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(g_auxPushTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(20 * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler(g_auxPushTimer, ^{
            if (!g_activeZegoApi || kCurrentFightMode == FightMode_Normal) return;

            int sampleCount = 882;
            int16_t frameBuffer[882];

            float noiseDB = -18.0f;
            float humDB = -15.0f;
            if (kCurrentFightMode == FightMode_Old) { noiseDB = -15.0f; humDB = -13.0f; }
            if (kCurrentFightMode == FightMode_Super) { noiseDB = -12.0f; humDB = -11.0f; }

            pthread_mutex_lock(&g_pcmMutex);
            if (g_musicPcmBuffer && g_musicPcmSize > 0) {
                for (int i = 0; i < sampleCount; i++) {
                    frameBuffer[i] = g_musicPcmBuffer[g_musicPcmOffset++];
                    if (g_musicPcmOffset >= g_musicPcmSize) g_musicPcmOffset = 0;
                }
            } else {
                for (int i = 0; i < sampleCount; i++) {
                    frameBuffer[i] = GenerateTVSnowSample(noiseDB, humDB);
                }
            }
            pthread_mutex_unlock(&g_pcmMutex);

            id zegoApi = g_activeZegoApi;
            if (zegoApi && [zegoApi respondsToSelector:@selector(setAudioAuxData:dataLen:sampleRate:channelCount:)]) {
                [zegoApi setAudioAuxData:frameBuffer dataLen:sampleCount * (int)sizeof(int16_t) sampleRate:44100 channelCount:1];
            }
        });
        dispatch_resume(g_auxPushTimer);
    });
}

// ---------------------- 核心调音与 3A 锁定 ----------------------
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

    if ([zegoApi respondsToSelector:@selector(enableAux:)]) {
        [zegoApi enableAux:YES];
    }

    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        [zegoApi setAudioEqualizerGain:6.0f index:0];
        [zegoApi setAudioEqualizerGain:8.0f index:1];
        [zegoApi setAudioEqualizerGain:4.0f index:2];
        [zegoApi setAudioEqualizerGain:0.0f index:3];
        [zegoApi setAudioEqualizerGain:0.0f index:4];
        [zegoApi setAudioEqualizerGain:6.0f index:5];
        [zegoApi setAudioEqualizerGain:10.0f index:6];
        [zegoApi setAudioEqualizerGain:12.0f index:7];
        [zegoApi setAudioEqualizerGain:8.0f index:8];
        [zegoApi setAudioEqualizerGain:6.0f index:9];
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
    StartAuxDataInjector();
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(weakSelf);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    StartAuxDataInjector();
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(weakSelf);
    });
    return res;
}

%end

// ---------------------- 注入启动 ----------------------
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
        self.statusLabel.text = @"默认噪音";
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
    LoadMP3ToPCM(kDefaultNoiseFile);
    kCurrentMusicFile = nil;
    self.statusLabel.text = @"默认噪音";
}

- (void)stopPlayMusic {
    pthread_mutex_lock(&g_pcmMutex);
    if (g_musicPcmBuffer) {
        free(g_musicPcmBuffer);
        g_musicPcmBuffer = NULL;
        g_musicPcmSize = 0;
        g_musicPcmOffset = 0;
    }
    pthread_mutex_unlock(&g_pcmMutex);
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
        @"FightVoicePro v2.3.0",
        @"",
        @"推流通道: ZegoAudioAux",
        @"  enableAux: + setAudioAuxData:",
        @"  20ms 定时注入 (882 samples/frame)",
        @"  推流时机: startPublishing 后激活",
        @"",
        @"线程安全: pthread_mutex 保护 PCM",
        @"  切歌/默认噪音时无 Use-After-Free",
        @"",
        @"TV 雪花 DSP 参数:",
        @"  白噪声: 全频段随机脉冲",
        @"  50Hz: 交流工频场电嗡鸣",
        @"  15625Hz: 显像管行频啸叫",
        @"  20Hz: 场扫描失步切音",
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
