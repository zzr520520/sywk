#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <cmath>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击 (500 音量 + 清晰机械撕扯)
    FightMode_Old,      // 旧清晰搏击 (1000 音量 + 重度撕扯)
    FightMode_Super     // 超级战斗 (1500 音量 + 极限爆裂撕扯)
} FightAudioMode;

static BOOL kForceOpenMic = NO;
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

// 独立增益
static float kNewFightGain = 500.0f;
static float kOldFightGain = 1000.0f;
static float kSuperFightGain = 1500.0f;
static float kVoiceGainRatio = 1.0f;
static float kEffectVolumePercent = 60.0f;

static NSString *kCurrentEffectFile = nil;
static NSString *kCurrentMusicFile = nil;

static __weak id g_activeZegoApi = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// MP3 解码缓存与推流指针
static int16_t *g_musicPcmBuffer = NULL;
static size_t g_musicPcmSize = 0;
static size_t g_musicPcmOffset = 0;

// 效果音 PCM 缓存
static int16_t *g_effectPcmBuffer = NULL;
static size_t g_effectPcmSize = 0;
static size_t g_effectPcmOffset = 0;

// 机械撕扯调制相位累加器
static double g_phase = 0.0;
static double g_pulsePhase = 0.0;

@interface NSObject (ZegoHardwareAPIs)
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

// ---------------------- MP3/音频解码至 PCM 内存池 ----------------------
static void LoadAudioToPCMBuffer(NSString *filePath, int16_t **outBuffer, size_t *outSize) {
    if (*outBuffer) {
        free(*outBuffer);
        *outBuffer = NULL;
        *outSize = 0;
    }
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) return;

    NSURL *url = [NSURL fileURLWithPath:filePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) return;

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) return;

    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO),
        AVSampleRateKey: @(44100),
        AVNumberOfChannelsKey: @(1)
    };

    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:outputSettings];
    [reader addOutput:output];
    [reader startReading];

    NSMutableData *fullData = [NSMutableData data];
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer) {
            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
            size_t length = CMBlockBufferGetDataLength(blockBuffer);
            if (length > 0) {
                char *temp = (char *)malloc(length);
                if (temp) {
                    CMBlockBufferCopyDataBytes(blockBuffer, 0, length, temp);
                    [fullData appendBytes:temp length:length];
                    free(temp);
                }
            }
            CFRelease(sampleBuffer);
        } else {
            break;
        }
    }

    if (fullData.length > 0) {
        *outSize = fullData.length / sizeof(int16_t);
        *outBuffer = (int16_t *)malloc(fullData.length);
        if (*outBuffer) {
            memcpy(*outBuffer, fullData.bytes, fullData.length);
        }
    }
}

static void LoadMP3ToPCMBuffer(NSString *filePath) {
    LoadAudioToPCMBuffer(filePath, &g_musicPcmBuffer, &g_musicPcmSize);
    g_musicPcmOffset = 0;
}

static void LoadEffectToPCMBuffer(NSString *filePath) {
    LoadAudioToPCMBuffer(filePath, &g_effectPcmBuffer, &g_effectPcmSize);
    g_effectPcmOffset = 0;
}

// ---------------------- 核心 DSP 硬件级撕拉音效算法 ----------------------
static inline int16_t ProcessHelicopterRadioSample(int16_t inputSample, float gain, float tearStrength) {
    // 1. 基础音量线性增益放大
    float sample = (float)inputSample * (gain / 100.0f);

    // 2. 音频脉冲撕扯调制（复刻视频同款 18Hz 极速电台断续切音）
    g_pulsePhase += 18.0 / 44100.0;
    if (g_pulsePhase >= 1.0) g_pulsePhase -= 1.0;
    float pulseMod = (sin(g_pulsePhase * 2.0 * M_PI) > 0.0) ? 1.0f : (1.0f - tearStrength * 0.7f);

    // 3. 高频电台金属载波调制 (2400Hz 机械撕拉共振)
    g_phase += 2400.0 / 44100.0;
    if (g_phase >= 1.0) g_phase -= 1.0;
    float carrier = sin(g_phase * 2.0 * M_PI) * (tearStrength * 12000.0f);

    sample = (sample * pulseMod) + carrier;

    // 4. 暴力软/硬削顶（模拟超强过载失真）
    if (sample > 32767.0f) sample = 32767.0f;
    if (sample < -32768.0f) sample = -32768.0f;

    return (int16_t)sample;
}

// ---------------------- PCM 原始音频帧注入 ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    return inst;
}

- (void)onCaptureAudioFrame:(void *)audioFrame {
    %orig;
    if (!audioFrame || kCurrentFightMode == FightMode_Normal) return;

    // 安全获取 PCM 数据指针和采样数
    int16_t *samples = (int16_t *)*(void **)audioFrame;
    int sampleCount = *(int *)((char *)audioFrame + sizeof(void *));

    if (!samples || sampleCount <= 0) return;

    float currentGain = kNewFightGain;
    float tearPower = 0.35f;

    if (kCurrentFightMode == FightMode_Old) {
        currentGain = kOldFightGain;
        tearPower = 0.65f;
    } else if (kCurrentFightMode == FightMode_Super) {
        currentGain = kSuperFightGain;
        tearPower = 1.0f;
    }

    currentGain *= kVoiceGainRatio;

    for (int i = 0; i < sampleCount; i++) {
        // 1. 混入正在推流的 MP3 音乐
        if (g_musicPcmBuffer && g_musicPcmSize > 0) {
            int16_t musicSample = g_musicPcmBuffer[g_musicPcmOffset++];
            if (g_musicPcmOffset >= g_musicPcmSize) g_musicPcmOffset = 0;
            samples[i] = (int16_t)((samples[i] + musicSample) / 2);
        }

        // 2. 混入选中的效果音底噪
        if (g_effectPcmBuffer && g_effectPcmSize > 0) {
            int16_t effectSample = g_effectPcmBuffer[g_effectPcmOffset++];
            if (g_effectPcmOffset >= g_effectPcmSize) g_effectPcmOffset = 0;
            int16_t mixed = (int16_t)((float)effectSample * (kEffectVolumePercent / 100.0f));
            samples[i] = (int16_t)(samples[i] + mixed);
        }

        // 3. 注入机械电台撕拉音效
        samples[i] = ProcessHelicopterRadioSample(samples[i], currentGain, tearPower);
    }
}

%end

// ---------------------- 状态应用 ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        // 清理 PCM 缓冲
        if (g_effectPcmBuffer) {
            free(g_effectPcmBuffer);
            g_effectPcmBuffer = NULL;
            g_effectPcmSize = 0;
            g_effectPcmOffset = 0;
        }
        return;
    }

    // 强制关闭系统 3A，防止切音被当成杂音吃掉
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];
}

// ---------------------- 业务 Hook ----------------------
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

%end

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

        UIView *actionContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 95, 26)];

        UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        sendBtn.frame = CGRectMake(0, 2, 48, 22);
        [sendBtn setTitle:@"上麦发" forState:UIControlStateNormal];
        [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        sendBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.75 blue:0.35 alpha:1.0];
        sendBtn.layer.cornerRadius = 4;
        sendBtn.tag = 1000;
        [actionContainer addSubview:sendBtn];

        UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        delBtn.frame = CGRectMake(52, 2, 40, 22);
        [delBtn setTitle:@"删除" forState:UIControlStateNormal];
        [delBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        delBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:1.0];
        delBtn.layer.cornerRadius = 4;
        delBtn.tag = 2000;
        [actionContainer addSubview:delBtn];

        cell.accessoryView = actionContainer;
    }

    NSString *fileName = self.musicFiles[indexPath.row];
    cell.textLabel.text = fileName;

    UIView *container = (UIView *)cell.accessoryView;
    UIButton *sendBtn = [container viewWithTag:1000];
    UIButton *delBtn = [container viewWithTag:2000];

    [sendBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [delBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    sendBtn.tag = indexPath.row;
    delBtn.tag = indexPath.row;

    [sendBtn addTarget:self action:@selector(publishTrack:) forControlEvents:UIControlEventTouchUpInside];
    [delBtn addTarget:self action:@selector(deleteFile:) forControlEvents:UIControlEventTouchUpInside];

    return cell;
}

- (void)deleteFile:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.musicFiles.count) return;
    NSString *fileName = self.musicFiles[btn.tag];
    [[NSFileManager defaultManager] removeItemAtPath:[GetSafeDir(@"FightMusic") stringByAppendingPathComponent:fileName] error:nil];
    if ([kCurrentMusicFile isEqualToString:fileName]) {
        [self stopPlayMusic];
    }
    [self.musicFiles removeObjectAtIndex:btn.tag];
    [self.tableView reloadData];
}

- (void)publishTrack:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.musicFiles.count) return;
    kCurrentMusicFile = self.musicFiles[btn.tag];
    NSString *fullPath = [GetSafeDir(@"FightMusic") stringByAppendingPathComponent:kCurrentMusicFile];
    self.statusLabel.text = [NSString stringWithFormat:@"底层推流中: %@", kCurrentMusicFile];
    LoadMP3ToPCMBuffer(fullPath);
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

// ---------------------- 设置页 ----------------------
@interface EffectManagerView : UIView <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *effectFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation EffectManagerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.effectFiles = [NSMutableArray array];

        UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        importBtn.frame = CGRectMake(8, 6, 80, 24);
        [importBtn setTitle:@"+ 导入底噪" forState:UIControlStateNormal];
        [importBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        importBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        importBtn.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0];
        importBtn.layer.cornerRadius = 5;
        [importBtn addTarget:self action:@selector(importEffect) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:importBtn];

        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(96, 6, frame.size.width - 100, 24)];
        self.statusLabel.text = @"默认使用内置机械撕裂音";
        self.statusLabel.font = [UIFont systemFontOfSize:10];
        self.statusLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
        [self addSubview:self.statusLabel];

        self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(5, 34, frame.size.width - 10, frame.size.height - 38) style:UITableViewStylePlain];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.delegate = self;
        self.tableView.dataSource = self;
        self.tableView.rowHeight = 34;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        [self addSubview:self.tableView];

        [self refreshFileList];
    }
    return self;
}

- (void)refreshFileList {
    [self.effectFiles removeAllObjects];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:GetSafeDir(@"FightEffects") error:nil];
    for (NSString *f in files) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"mp3"] || [f.pathExtension.lowercaseString isEqualToString:@"wav"]) {
            [self.effectFiles addObject:f];
        }
    }
    [self.tableView reloadData];
}

- (void)importEffect {
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
        NSString *dest = [GetSafeDir(@"FightEffects") stringByAppendingPathComponent:url.lastPathComponent];
        [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dest error:nil];
    }
    [self refreshFileList];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.effectFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EffectCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"EffectCell"];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        cell.layer.cornerRadius = 6;
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:11];

        UIView *actionContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 95, 24)];

        UIButton *useBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        useBtn.frame = CGRectMake(0, 1, 48, 22);
        useBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        useBtn.layer.cornerRadius = 4;
        useBtn.tag = 3000;
        [actionContainer addSubview:useBtn];

        UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        delBtn.frame = CGRectMake(52, 1, 40, 22);
        [delBtn setTitle:@"删除" forState:UIControlStateNormal];
        [delBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        delBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:1.0];
        delBtn.layer.cornerRadius = 4;
        delBtn.tag = 4000;
        [actionContainer addSubview:delBtn];

        cell.accessoryView = actionContainer;
    }

    NSString *fileName = self.effectFiles[indexPath.row];
    cell.textLabel.text = fileName;

    UIView *container = (UIView *)cell.accessoryView;
    UIButton *useBtn = [container viewWithTag:3000];
    UIButton *delBtn = [container viewWithTag:4000];

    [useBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [delBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    useBtn.tag = indexPath.row;
    delBtn.tag = indexPath.row;

    if ([fileName isEqualToString:kCurrentEffectFile]) {
        [useBtn setTitle:@"使用中" forState:UIControlStateNormal];
        [useBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        useBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0];
    } else {
        [useBtn setTitle:@"选用" forState:UIControlStateNormal];
        [useBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        useBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.75 blue:0.35 alpha:1.0];
    }

    [useBtn addTarget:self action:@selector(selectEffect:) forControlEvents:UIControlEventTouchUpInside];
    [delBtn addTarget:self action:@selector(deleteEffect:) forControlEvents:UIControlEventTouchUpInside];

    return cell;
}

- (void)selectEffect:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.effectFiles.count) return;
    NSString *picked = self.effectFiles[btn.tag];
    if ([picked isEqualToString:kCurrentEffectFile]) {
        kCurrentEffectFile = nil;
        if (g_effectPcmBuffer) {
            free(g_effectPcmBuffer);
            g_effectPcmBuffer = NULL;
            g_effectPcmSize = 0;
            g_effectPcmOffset = 0;
        }
        self.statusLabel.text = @"默认使用内置机械撕裂音";
    } else {
        kCurrentEffectFile = picked;
        self.statusLabel.text = [NSString stringWithFormat:@"当前: %@", kCurrentEffectFile];
        NSString *effectPath = [GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile];
        LoadEffectToPCMBuffer(effectPath);
    }
    [self.tableView reloadData];
}

- (void)deleteEffect:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.effectFiles.count) return;
    NSString *fileName = self.effectFiles[btn.tag];
    [[NSFileManager defaultManager] removeItemAtPath:[GetSafeDir(@"FightEffects") stringByAppendingPathComponent:fileName] error:nil];
    if ([kCurrentEffectFile isEqualToString:fileName]) {
        kCurrentEffectFile = nil;
        if (g_effectPcmBuffer) {
            free(g_effectPcmBuffer);
            g_effectPcmBuffer = NULL;
            g_effectPcmSize = 0;
            g_effectPcmOffset = 0;
        }
        self.statusLabel.text = @"默认使用内置机械撕裂音";
    }
    [self.effectFiles removeObjectAtIndex:btn.tag];
    [self.tableView reloadData];
}

@end

// ---------------------- 主 HUD 面板 ----------------------
@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;
@property (nonatomic, strong) MusicManagerView *musicPageView;
@property (nonatomic, strong) EffectManagerView *settingPageView;

@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swNoiseFilter;
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

        CGFloat rightW = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIScrollView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.debugPageView.contentSize = CGSizeMake(rightW, 310);
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        self.musicPageView = [[MusicManagerView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.musicPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.musicPageView.hidden = YES;
        [self addSubview:self.musicPageView];

        self.settingPageView = [[EffectManagerView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
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
        [touch.view isDescendantOfView:self.settingPageView.tableView] ||
        [touch.view isDescendantOfView:self.debugPageView]) {
        return NO;
    }
    return YES;
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

    NSArray *titles = @[@"强制开麦", @"屏蔽滋啦杂音", @"新清晰搏击效果", @"旧清晰搏击效果", @"超级战斗效果"];
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
        if (i == 1) self.swNoiseFilter = sw;
        if (i == 2) { self.swNewFight = sw; [sw setOn:YES]; }
        if (i == 3) self.swOldFight = sw;
        if (i == 4) self.swSuperFight = sw;
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"新清晰音量 (默认500)", @"旧清晰音量 (默认1000)", @"超级战斗音量 (默认1500)", @"人声音量权重", @"效果音推流音量"];
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
        if (i == 4) { slider.minimumValue = 10; slider.maximumValue = 100; slider.value = kEffectVolumePercent; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)btn {
    self.funcPageView.hidden = YES;
    self.debugPageView.hidden = YES;
    self.musicPageView.hidden = YES;
    self.settingPageView.hidden = YES;

    if (btn.tag == 200) {
        self.funcPageView.hidden = NO;
    } else if (btn.tag == 201) {
        self.debugPageView.hidden = NO;
    } else if (btn.tag == 202) {
        self.musicPageView.hidden = NO;
        [self.musicPageView refreshFileList];
    } else if (btn.tag == 203) {
        self.settingPageView.hidden = NO;
        [self.settingPageView refreshFileList];
    }
}

- (void)onSliderChanged:(UISlider *)slider {
    if (slider.tag == 500) kNewFightGain = slider.value;
    if (slider.tag == 501) kOldFightGain = slider.value;
    if (slider.tag == 502) kSuperFightGain = slider.value;
    if (slider.tag == 503) kVoiceGainRatio = slider.value;
    if (slider.tag == 504) kEffectVolumePercent = slider.value;
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)onFuncSwitch:(UISwitch *)sender {
    if (sender == self.swForceMic) kForceOpenMic = sender.isOn;
    if (sender == self.swNoiseFilter) kSmartNoiseFilter = sender.isOn;
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

// ---------------------- 注入启动 ----------------------
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

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureHandler shared] attachToWindow:self];
}
%end
