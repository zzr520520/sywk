#import <UIKit/UIKit.h>
#import <substrate.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击
    FightMode_Old,      // 旧清晰搏击
    FightMode_Super     // 超级战斗
} FightAudioMode;

static BOOL kForceOpenMic = NO;
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

// 独立增益
static float kNewFightGain = 500.0f;
static float kOldFightGain = 1000.0f;
static float kSuperFightGain = 1500.0f;
static float kVoiceGainRatio = 1.0f;
static float kEffectVolumePercent = 50.0f; // 效果音音量

static NSString *kCurrentEffectFile = nil; // 当前选中的底噪文件
static NSString *kCurrentMusicFile = nil;  // 当前推流的音乐文件

static __weak id g_activeZegoApi = nil;
static id g_musicPlayer = nil;
static id g_effectPlayer = nil;
static dispatch_source_t g_keepAliveTimer = nil;

@interface NSObject (ZegoAudioCoreAPIs)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableMic:(bool)enable;
// 播放器推流核心
- (void)setAudioStreamType:(int)type;
- (void)setProcessType:(int)type;
- (bool)start:(NSString *)path;
- (void)setPublishVolume:(int)volume;
- (void)setPlayoutVolume:(int)volume;
- (void)setLoopCount:(int)count;
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

// ---------------------- 安全停止播放器 ----------------------
static void SafeStopPlayer(id player) {
    if (!player) return;
    @try {
        if ([player respondsToSelector:@selector(stop)]) {
            [player performSelector:@selector(stop)];
        }
    } @catch (NSException *e) {}
}

// ---------------------- 纯 SDK 推流通道播放引擎 ----------------------
static void PlayTrackToRemoteStream(NSString *filePath, BOOL isMusic) {
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) return;

    Class zPlayerClass = NSClassFromString(@"ZegoMediaPlayer");
    if (!zPlayerClass) return;

    id player = nil;
    if (isMusic) {
        if (!g_musicPlayer) g_musicPlayer = [[zPlayerClass alloc] init];
        player = g_musicPlayer;
    } else {
        if (!g_effectPlayer) g_effectPlayer = [[zPlayerClass alloc] init];
        player = g_effectPlayer;
    }

    if (!player) return;
    @try {
        SafeStopPlayer(player);
        // 核心配置：设置音频流类型为推流输出（2 = PublishStream + Playout）
        if ([player respondsToSelector:@selector(setAudioStreamType:)]) {
            [player setAudioStreamType:2];
        }
        // 核心配置：设置处理类型为 0 (混入推流通道)
        if ([player respondsToSelector:@selector(setProcessType:)]) {
            [player setProcessType:0];
        }
        if ([player respondsToSelector:@selector(setLoopCount:)]) {
            [player setLoopCount:-1]; // 循环推流
        }
        
        int pushVol = isMusic ? 100 : (int)kEffectVolumePercent;
        if ([player respondsToSelector:@selector(setPublishVolume:)]) {
            [player setPublishVolume:pushVol]; // 推向远端房间
        }
        if ([player respondsToSelector:@selector(setPlayoutVolume:)]) {
            [player setPlayoutVolume:pushVol];  // 本地耳机监听
        }
        if ([player respondsToSelector:@selector(start:)]) {
            [player start:filePath];
        }
    } @catch (NSException *e) {}
}

static void StopStreamPlayer(BOOL isMusic) {
    id player = isMusic ? g_musicPlayer : g_effectPlayer;
    SafeStopPlayer(player);
}

// ---------------------- 调音矩阵（去除低频海浪轰鸣，保留纯正电台撕拉感） ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    if (kSmartNoiseFilter) {
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(setNoiseSuppressMode:)]) [zegoApi setNoiseSuppressMode:2];
        if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:YES];
    }

    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            for (int i = 0; i < 10; i++) [zegoApi setAudioEqualizerGain:0.0f index:i];
        }
        StopStreamPlayer(NO);
        return;
    }

    // 关闭限幅保护
    if (!kSmartNoiseFilter) {
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
        if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    }
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 音量计算
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    // 严密修复海浪声：切除 0(31Hz) 和 1(62Hz)，突出 1k~4kHz 撕拉清晰感
    @try {
        if (kCurrentFightMode == FightMode_New) {
            [zegoApi setAudioEqualizerGain:-12.0f index:0]; // 切除超低频海浪声
            [zegoApi setAudioEqualizerGain:-6.0f index:1];
            [zegoApi setAudioEqualizerGain:2.0f index:2];   // 125Hz 适度饱满
            [zegoApi setAudioEqualizerGain:-10.0f index:4]; // 500Hz 削减空腔音
            [zegoApi setAudioEqualizerGain:12.0f index:5];  // 1kHz
            [zegoApi setAudioEqualizerGain:16.0f index:6];  // 2kHz
            [zegoApi setAudioEqualizerGain:18.0f index:7];  // 4kHz 极度清晰
            [zegoApi setAudioEqualizerGain:12.0f index:8];  // 8kHz
            [zegoApi setAudioEqualizerGain:8.0f index:9];
        } else if (kCurrentFightMode == FightMode_Old) {
            [zegoApi setAudioEqualizerGain:-10.0f index:0];
            [zegoApi setAudioEqualizerGain:2.0f index:1];
            [zegoApi setAudioEqualizerGain:8.0f index:2];
            [zegoApi setAudioEqualizerGain:-4.0f index:4];
            [zegoApi setAudioEqualizerGain:16.0f index:5];
            [zegoApi setAudioEqualizerGain:20.0f index:6];  // 强力过载撕拉
            [zegoApi setAudioEqualizerGain:20.0f index:7];
            [zegoApi setAudioEqualizerGain:14.0f index:8];
        } else if (kCurrentFightMode == FightMode_Super) {
            [zegoApi setAudioEqualizerGain:-8.0f index:0]; // 依然切除31Hz防海浪
            for (int i = 1; i < 10; i++) {
                [zegoApi setAudioEqualizerGain:22.0f index:i];
            }
        }
    } @catch (NSException *e) {}

    // 更新伴随效果音音量
    if (g_effectPlayer && [g_effectPlayer respondsToSelector:@selector(setPublishVolume:)]) {
        [g_effectPlayer setPublishVolume:(int)kEffectVolumePercent];
    }
}

// ---------------------- 保活线程 ----------------------
static void StartAudioKeepAliveService() {
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

// ---------------------- Hook ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    StartAudioKeepAliveService();
    return inst;
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
        if (kCurrentEffectFile && kCurrentFightMode != FightMode_Normal) {
            PlayTrackToRemoteStream([GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile], NO);
        }
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
        if (kCurrentEffectFile && kCurrentFightMode != FightMode_Normal) {
            PlayTrackToRemoteStream([GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile], NO);
        }
    });
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
        if (kCurrentEffectFile && kCurrentFightMode != FightMode_Normal) {
            PlayTrackToRemoteStream([GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile], NO);
        }
    });
    return res;
}

- (bool)stopPublishing {
    StopStreamPlayer(NO);
    StopStreamPlayer(YES);
    return %orig;
}

%end

%hook SKAudioZegoManager

- (void)enableMic:(BOOL)enable {
    if (kForceOpenMic) {
        %orig(YES);
    } else {
        %orig(enable);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(g_activeZegoApi);
        if ((enable || kForceOpenMic) && kCurrentEffectFile && kCurrentFightMode != FightMode_Normal) {
            PlayTrackToRemoteStream([GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile], NO);
        } else if (!enable && !kForceOpenMic) {
            StopStreamPlayer(NO);
        }
    });
}

%end

// ---------------------- 音乐管理视图 (纯 SDK 远端推流) ----------------------
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
        StopStreamPlayer(YES);
        kCurrentMusicFile = nil;
    }
    [self.musicFiles removeObjectAtIndex:btn.tag];
    [self.tableView reloadData];
}

- (void)publishTrack:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.musicFiles.count) return;
    kCurrentMusicFile = self.musicFiles[btn.tag];
    NSString *fullPath = [GetSafeDir(@"FightMusic") stringByAppendingPathComponent:kCurrentMusicFile];
    self.statusLabel.text = [NSString stringWithFormat:@"远端推流中: %@", kCurrentMusicFile];
    PlayTrackToRemoteStream(fullPath, YES);
}

- (void)stopPlayMusic {
    StopStreamPlayer(YES);
    kCurrentMusicFile = nil;
    self.statusLabel.text = @"已停止推流";
}

@end

// ---------------------- 设置页（多底噪自由选用管理） ----------------------
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
        self.statusLabel.text = kCurrentEffectFile ? [NSString stringWithFormat:@"当前: %@", kCurrentEffectFile] : @"未启用底噪";
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
        StopStreamPlayer(NO);
        self.statusLabel.text = @"未启用底噪";
    } else {
        kCurrentEffectFile = picked;
        self.statusLabel.text = [NSString stringWithFormat:@"当前: %@", kCurrentEffectFile];
        if (kCurrentFightMode != FightMode_Normal) {
            PlayTrackToRemoteStream([GetSafeDir(@"FightEffects") stringByAppendingPathComponent:kCurrentEffectFile], NO);
        }
    }
    [self.tableView reloadData];
}

- (void)deleteEffect:(UIButton *)btn {
    if (btn.tag >= (NSInteger)self.effectFiles.count) return;
    NSString *fileName = self.effectFiles[btn.tag];
    [[NSFileManager defaultManager] removeItemAtPath:[GetSafeDir(@"FightEffects") stringByAppendingPathComponent:fileName] error:nil];
    if ([kCurrentEffectFile isEqualToString:fileName]) {
        StopStreamPlayer(NO);
        kCurrentEffectFile = nil;
        self.statusLabel.text = @"未启用底噪";
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

        // 2. 右侧页面
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
