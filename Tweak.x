#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击 (500 增益 + 清晰咬字)
    FightMode_Old,      // 旧清晰搏击 (1000 增益 + 电台撕拉)
    FightMode_Super     // 超级战斗 (1500 增益 + 极限过载爆音)
} FightAudioMode;

static BOOL kForceOpenMic = YES;
static BOOL kSmartNoiseFilter = NO;
static FightAudioMode kCurrentFightMode = FightMode_New;

// 独立增益
static float kNewFightGain = 500.0f;
static float kOldFightGain = 1000.0f;
static float kSuperFightGain = 1500.0f;
static float kVoiceGainRatio = 1.0f;

static NSString *kCurrentMusicFile = nil;
static __weak id g_activeZegoApi = nil;
static id g_zegoMusicPlayer = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// 本地测试播放器
static AVAudioPlayer *g_safeTestPlayer = nil;

// ---------------------- 前置函数声明 ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi);
static void StartKeepAliveService(void);
static NSString *GetSafeDir(NSString *subDir);
static UIWindow *GetKeyWindow(void);

@interface NSObject (ZegoSDKDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)enableMic:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;

// Zego 媒体播放器推流接口
- (void)setAudioStreamType:(int)type;
- (void)setProcessType:(int)type;
- (bool)start:(NSString *)path;
- (bool)stop;
- (void)setPublishVolume:(int)volume;
- (void)setPlayoutVolume:(int)volume;
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

// ---------------------- 核心调音矩阵（二、三版最稳生效方案） ----------------------
static void ApplyPreciseRadioFightDSP(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    // 2. 正常模式恢复
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

    // 3. 彻底关死 3A，防止声音被系统压制削弱
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 4. 设置麦克风推流采集增益 (500 / 1000 / 1500)
    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    // 5. 注入电台撕裂与 50Hz 嗡鸣 EQ 曲线（全频段直通，推向全房间）
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            // 新清晰搏击：500 音量 + 极高清晰咬字
            [zegoApi setAudioEqualizerGain:8.0f index:0];   // 31Hz
            [zegoApi setAudioEqualizerGain:12.0f index:1];  // 62Hz 50Hz嗡鸣
            [zegoApi setAudioEqualizerGain:6.0f index:2];   // 125Hz
            [zegoApi setAudioEqualizerGain:-6.0f index:4];  // 500Hz 削减浑浊空腔
            [zegoApi setAudioEqualizerGain:12.0f index:5];  // 1kHz
            [zegoApi setAudioEqualizerGain:18.0f index:6];  // 2kHz 清晰穿透
            [zegoApi setAudioEqualizerGain:20.0f index:7];  // 4kHz 齿音强化
            [zegoApi setAudioEqualizerGain:14.0f index:8];  // 8kHz
            [zegoApi setAudioEqualizerGain:10.0f index:9];  // 16kHz
        } else if (kCurrentFightMode == FightMode_Old) {
            // 旧清晰搏击：1000 音量 + 强力电台过载撕拉
            [zegoApi setAudioEqualizerGain:14.0f index:0];
            [zegoApi setAudioEqualizerGain:18.0f index:1];  // 62Hz 强力嗡鸣
            [zegoApi setAudioEqualizerGain:14.0f index:2];
            [zegoApi setAudioEqualizerGain:-2.0f index:4];
            [zegoApi setAudioEqualizerGain:16.0f index:5];
            [zegoApi setAudioEqualizerGain:22.0f index:6];  // 2kHz 强力撕裂
            [zegoApi setAudioEqualizerGain:24.0f index:7];  // 4kHz
            [zegoApi setAudioEqualizerGain:18.0f index:8];
            [zegoApi setAudioEqualizerGain:14.0f index:9];
        } else if (kCurrentFightMode == FightMode_Super) {
            // 超级战斗：1500 音量 + 全频段最大 +24dB 极限过载轰炸
            for (int i = 0; i < 10; i++) {
                [zegoApi setAudioEqualizerGain:24.0f index:i];
            }
        }
    }
}

// ---------------------- Hook 业务与底层 SDK ----------------------
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyPreciseRadioFightDSP(self);
    });
    return res;
}

%end

// ---------------------- 保活守护线程（确保永远在线，不被房间重置） ----------------------
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

// ---------------------- 音乐管理器 (标准 SDK 推流) ----------------------
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.musicFiles.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MCell"];
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

- (void)publishTrack:(UIButton *)b {
    if (b.tag >= (NSInteger)self.musicFiles.count) return;
    kCurrentMusicFile = self.musicFiles[b.tag];
    NSString *fullPath = [GetSafeDir(@"FightMusic") stringByAppendingPathComponent:kCurrentMusicFile];
    self.statusLabel.text = [NSString stringWithFormat:@"推流中: %@", kCurrentMusicFile];

    // 调用官方标准媒体播放器推流
    if (!g_zegoMusicPlayer) {
        Class cls = NSClassFromString(@"ZegoMediaPlayer");
        if (cls) g_zegoMusicPlayer = [[cls alloc] init];
    }
    if (g_zegoMusicPlayer) {
        @try {
            [g_zegoMusicPlayer stop];
            if ([g_zegoMusicPlayer respondsToSelector:@selector(setAudioStreamType:)]) {
                [g_zegoMusicPlayer setAudioStreamType:2]; // 混入上行推流 + 本地监听
            }
            if ([g_zegoMusicPlayer respondsToSelector:@selector(setPublishVolume:)]) {
                [g_zegoMusicPlayer setPublishVolume:100];
            }
            if ([g_zegoMusicPlayer respondsToSelector:@selector(setPlayoutVolume:)]) {
                [g_zegoMusicPlayer setPlayoutVolume:100];
            }
            [g_zegoMusicPlayer start:fullPath];
        } @catch (NSException *e) {}
    }
}

- (void)deleteTrack:(UIButton *)b {
    if (b.tag >= (NSInteger)self.musicFiles.count) return;
    NSString *f = self.musicFiles[b.tag];
    [[NSFileManager defaultManager] removeItemAtPath:[GetSafeDir(@"FightMusic") stringByAppendingPathComponent:f] error:nil];
    if ([kCurrentMusicFile isEqualToString:f]) [self stopPlayMusic];
    [self.musicFiles removeObjectAtIndex:b.tag];
    [self.tableView reloadData];
}

- (void)stopPlayMusic {
    if (g_zegoMusicPlayer) {
        @try { [g_zegoMusicPlayer stop]; } @catch (NSException *e) {}
    }
    kCurrentMusicFile = nil;
    self.statusLabel.text = @"已停止推流";
}

@end

// ---------------------- 设置页 ----------------------
@interface SettingManagerView : UIView
@property (nonatomic, strong) UILabel *testStatusLabel;
@end

@implementation SettingManagerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, frame.size.width - 24, 22)];
        title.text = @"音频推流状态监控：";
        title.font = [UIFont boldSystemFontOfSize:12.5];
        title.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
        [self addSubview:title];

        self.testStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 45, frame.size.width - 24, 80)];
        self.testStatusLabel.text = @"• 搏击模式：已启用 Zego 原生上行推流通道\n• 3A 状态：已彻底关闭 AGC/ANS/AEC\n• 增益控制：麦克风过载直通模式\n• 只要开麦说话，全房间必定同步听到过载搏击声";
        self.testStatusLabel.numberOfLines = 0;
        self.testStatusLabel.font = [UIFont systemFontOfSize:11];
        self.testStatusLabel.textColor = [UIColor whiteColor];
        [self addSubview:self.testStatusLabel];

        // 版本信息
        CGFloat y = 135;
        NSArray *info = @[
            @"FightVoicePro v4.0.0",
            @"",
            @"推流模式: Zego 原生上行推流",
            @"  setCaptureVolume: 500/1000/1500",
            @"  10段EQ 极限过载 (+24dB)",
            @"  彻底关闭 3A (AGC/ANS/AEC)",
            @"",
            @"保活: 0.8s 定时刷新 DSP",
            @"音乐推流: ZegoMediaPlayer 标准接口",
            @"  setAudioStreamType:2 混入推流",
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

- (void)tabClicked:(UIButton *)b {
    self.funcPageView.hidden = (b.tag != 200);
    self.debugPageView.hidden = (b.tag != 201);
    self.musicPageView.hidden = (b.tag != 202);
    self.settingPageView.hidden = (b.tag != 203);
    if (b.tag == 202) [self.musicPageView refreshFileList];
}

- (void)onSliderChanged:(UISlider *)s {
    if (s.tag == 500) kNewFightGain = s.value;
    if (s.tag == 501) kOldFightGain = s.value;
    if (s.tag == 502) kSuperFightGain = s.value;
    if (s.tag == 503) kVoiceGainRatio = s.value;
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)onFuncSwitch:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
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
    ApplyPreciseRadioFightDSP(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 双指双击手势与窗口 Hook ----------------------
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
    // 去重：已存在双指双击手势则跳过
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

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[HUDGestureHandler shared] attachToWindow:self];
    StartKeepAliveService();
}
%end
