#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>

// ---------------------- 状态管理 ----------------------
typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰搏击（高清晰+轻度撕裂）
    FightMode_Old,      // 旧清晰搏击（中等过载+胸腔共鸣）
    FightMode_Super     // 超级搏击（双倍音量+极限撕裂轰炸+断流吞字）
} FightAudioMode;

static BOOL kForceOpenMic = NO;       // 强制开麦
static BOOL kSmartNoiseFilter = NO;   // 智能屏蔽滋啦杂音（保留人声）
static FightAudioMode kCurrentFightMode = FightMode_New;

static float kMasterGain = 800.0f;    // 翻倍总增益 (100~1200)
static float kHighClarity = 15.0f;    // 高频撕裂清晰度 (0~24dB)

static __weak id g_activeZegoApi = nil;
static id g_zegoMediaPlayer = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// ---------------------- 核心接口声明 ----------------------
@interface NSObject (ZegoEnhancedDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setNoiseSuppressMode:(int)mode;
- (bool)enableTransientNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableMic:(bool)enable;
- (bool)setPlayVolume:(int)volume;
// 播放器接口（stop 不声明返回值，用 performSelector 调用避免歧义）
- (bool)start:(NSString *)path;
- (void)setPublishVolume:(int)volume;
- (void)setPlayoutVolume:(int)volume;
@end

// ---------------------- 核心激进化调音矩阵 ----------------------
static void ApplyEnhancedAudioDSP(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦
    if (kForceOpenMic && [zegoApi respondsToSelector:@selector(enableMic:)]) {
        [zegoApi enableMic:YES];
    }

    // 2. 智能屏蔽滋啦杂音（仅过滤突发过载底噪/爆音，放行人声）
    if (kSmartNoiseFilter) {
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(setNoiseSuppressMode:)]) [zegoApi setNoiseSuppressMode:2]; // 高阶瞬态降噪
        if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:YES];
    }

    // 3. 正常模式恢复
    if (kCurrentFightMode == FightMode_Normal) {
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:YES];
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:YES];
        if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:YES];
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) [zegoApi setCaptureVolume:100];
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            @try {
                for (int i = 0; i < 10; i++) [zegoApi setAudioEqualizerGain:0.0f index:i];
            } @catch (NSException *e) {}
        }
        return;
    }

    // 4. 彻底关闭自身麦克风的 3A 压制，释放翻倍能量
    if (!kSmartNoiseFilter) {
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
        if ([zegoApi respondsToSelector:@selector(enableTransientNoiseSuppress:)]) [zegoApi enableTransientNoiseSuppress:NO];
    }
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    // 5. 翻倍音量注入 (极限增益 + 24dB 全频过载)
    int targetVolume = (kCurrentFightMode == FightMode_Super) ? 1000 : (int)kMasterGain;
    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:targetVolume];
    }

    // 6. 频段压制与破音调校（制造吞字断流效果）
    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        @try {
            if (kCurrentFightMode == FightMode_New) {
                // 【新清晰搏击】：清晰微破音，强化 2k~4k 人声齿音
                [zegoApi setAudioEqualizerGain:6.0f index:1];  // 62Hz
                [zegoApi setAudioEqualizerGain:8.0f index:2];  // 125Hz
                [zegoApi setAudioEqualizerGain:-4.0f index:4]; // 500Hz 削减浑浊
                [zegoApi setAudioEqualizerGain:10.0f index:6]; // 2kHz
                [zegoApi setAudioEqualizerGain:kHighClarity index:7]; // 4kHz 极度清晰
                [zegoApi setAudioEqualizerGain:10.0f index:8]; // 8kHz
            } else if (kCurrentFightMode == FightMode_Old) {
                // 【旧清晰搏击】：中等过载，重低音加厚
                [zegoApi setAudioEqualizerGain:14.0f index:1]; // 62Hz
                [zegoApi setAudioEqualizerGain:16.0f index:2]; // 125Hz 饱满打击
                [zegoApi setAudioEqualizerGain:8.0f index:3];  // 250Hz
                [zegoApi setAudioEqualizerGain:12.0f index:6]; // 2kHz
                [zegoApi setAudioEqualizerGain:14.0f index:7]; // 4kHz
            } else if (kCurrentFightMode == FightMode_Super) {
                // 【超级搏击（翻倍极限爆破 + 频段吞字断流）】
                // 全频段强推至 +20dB~+24dB，制造最大物理过载，直接覆盖对手人声
                for (int i = 0; i < 10; i++) {
                    [zegoApi setAudioEqualizerGain:20.0f index:i];
                }
                [zegoApi setAudioEqualizerGain:24.0f index:6]; // 2kHz 极限抢占
                [zegoApi setAudioEqualizerGain:24.0f index:7]; // 4kHz 极限抢占
            }
        } @catch (NSException *e) {}
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
                    ApplyEnhancedAudioDSP(g_activeZegoApi);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- Hook 底层与业务 ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id inst = %orig;
    g_activeZegoApi = inst;
    StartKeepAliveService();
    return inst;
}

- (bool)setCaptureVolume:(int)volume {
    g_activeZegoApi = self;
    if (kCurrentFightMode != FightMode_Normal) {
        int v = (kCurrentFightMode == FightMode_Super) ? 1000 : (int)kMasterGain;
        return %orig(v);
    }
    return %orig(volume);
}

- (bool)enableAGC:(bool)enable {
    g_activeZegoApi = self;
    if (kCurrentFightMode != FightMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)enableNoiseSuppress:(bool)enable {
    g_activeZegoApi = self;
    // 智能降噪模式下不受战斗模式的强制关闭影响
    if (kSmartNoiseFilter) return %orig(YES);
    if (kCurrentFightMode != FightMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyEnhancedAudioDSP(self);
    });
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyEnhancedAudioDSP(self);
    });
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_activeZegoApi = self;
    bool res = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyEnhancedAudioDSP(self);
    });
    return res;
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
        ApplyEnhancedAudioDSP(g_activeZegoApi);
    });
}

%end

// ---------------------- 音乐模块（修复上麦推流） ----------------------
@interface MusicManagerView : UIView <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *musicFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@end

@implementation MusicManagerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.musicFiles = [NSMutableArray array];

        UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        importBtn.frame = CGRectMake(10, 8, 80, 26);
        [importBtn setTitle:@"+ 导入MP3" forState:UIControlStateNormal];
        [importBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        importBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        importBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        importBtn.layer.cornerRadius = 6;
        [importBtn addTarget:self action:@selector(importMusic) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:importBtn];

        UIButton *stopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        stopBtn.frame = CGRectMake(98, 8, 65, 26);
        [stopBtn setTitle:@"停止播放" forState:UIControlStateNormal];
        [stopBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        stopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
        stopBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:1.0];
        stopBtn.layer.cornerRadius = 6;
        [stopBtn addTarget:self action:@selector(stopPlayMusic) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:stopBtn];

        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(170, 8, frame.size.width - 175, 26)];
        self.statusLabel.text = @"未播放";
        self.statusLabel.font = [UIFont systemFontOfSize:10];
        self.statusLabel.textColor = [UIColor lightGrayColor];
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

- (NSString *)musicDirectory {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *musicDir = [doc stringByAppendingPathComponent:@"FightMusic"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:musicDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:musicDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return musicDir;
}

- (void)refreshFileList {
    [self.musicFiles removeAllObjects];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self musicDirectory] error:nil];
    for (NSString *f in files) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"mp3"] || [f.pathExtension.lowercaseString isEqualToString:@"m4a"] || [f.pathExtension.lowercaseString isEqualToString:@"wav"]) {
            [self.musicFiles addObject:f];
        }
    }
    [self.tableView reloadData];
}

- (void)importMusic {
    // 兼容 iOS 13+ 获取 keyWindow
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

    UIViewController *rootVC = keyWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio", @"public.mp3"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [rootVC presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        NSString *dest = [[self musicDirectory] stringByAppendingPathComponent:url.lastPathComponent];
        [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dest error:nil];
    }
    [self refreshFileList];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.musicFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MusicCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MusicCell"];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        cell.layer.cornerRadius = 6;
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:11];

        UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        sendBtn.frame = CGRectMake(0, 0, 52, 22);
        [sendBtn setTitle:@"上麦发" forState:UIControlStateNormal];
        [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
        sendBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.75 blue:0.35 alpha:1.0];
        sendBtn.layer.cornerRadius = 4;
        cell.accessoryView = sendBtn;
    }
    NSString *fileName = self.musicFiles[indexPath.row];
    cell.textLabel.text = fileName;
    UIButton *btn = (UIButton *)cell.accessoryView;
    btn.tag = indexPath.row;
    [btn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [btn addTarget:self action:@selector(playAndPublishTrack:) forControlEvents:UIControlEventTouchUpInside];
    return cell;
}

// 修复后的 MP3 上麦推流逻辑
- (void)playAndPublishTrack:(UIButton *)btn {
    NSString *fileName = self.musicFiles[btn.tag];
    NSString *fullPath = [[self musicDirectory] stringByAppendingPathComponent:fileName];
    self.statusLabel.text = [NSString stringWithFormat:@"推流中: %@", fileName];

    // 1. 获取/初始化 ZegoMediaPlayer 单例
    if (!g_zegoMediaPlayer) {
        Class zegoPlayerCls = NSClassFromString(@"ZegoMediaPlayer");
        if (zegoPlayerCls) {
            g_zegoMediaPlayer = [[zegoPlayerCls alloc] init];
        }
    }

    if (g_zegoMediaPlayer) {
        @try {
            // 用 performSelector 调用 stop 避免方法签名冲突
            if ([g_zegoMediaPlayer respondsToSelector:@selector(stop)]) {
                [g_zegoMediaPlayer performSelector:@selector(stop)];
            }
            // 设置播放器类型为推流混音伴奏模式
            if ([g_zegoMediaPlayer respondsToSelector:@selector(setProcessType:)]) {
                [g_zegoMediaPlayer performSelector:@selector(setProcessType:) withObject:@(0)];
            }
            if ([g_zegoMediaPlayer respondsToSelector:@selector(setPublishVolume:)]) {
                [g_zegoMediaPlayer setPublishVolume:100]; // 混入上行推流
            }
            if ([g_zegoMediaPlayer respondsToSelector:@selector(setPlayoutVolume:)]) {
                [g_zegoMediaPlayer setPlayoutVolume:100];  // 本地耳机耳返
            }
            if ([g_zegoMediaPlayer respondsToSelector:@selector(start:)]) {
                [g_zegoMediaPlayer start:fullPath];
            }
            return;
        } @catch (NSException *e) {}
    }

    // 2. 备用硬件链路混音
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:fullPath] error:&err];
    self.audioPlayer.numberOfLoops = 0;
    self.audioPlayer.volume = 1.0f;
    [self.audioPlayer prepareToPlay];
    [self.audioPlayer play];
}

- (void)stopPlayMusic {
    if (g_zegoMediaPlayer) {
        @try {
            if ([g_zegoMediaPlayer respondsToSelector:@selector(stop)]) {
                [g_zegoMediaPlayer performSelector:@selector(stop)];
            }
        } @catch (NSException *e) {}
    }
    if (self.audioPlayer && [self.audioPlayer isPlaying]) {
        [self.audioPlayer stop];
    }
    self.statusLabel.text = @"已停止";
}

@end

// ---------------------- 完整 UI 面板 ----------------------
@interface BattleMasterHUD : UIView
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIView *debugPageView;
@property (nonatomic, strong) MusicManagerView *musicPageView;

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
        [self addGestureRecognizer:pan];

        // 左侧 Tab 栏
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

        // 右侧区域
        CGFloat rightW = frame.size.width - 75;
        self.funcPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.funcPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        [self addSubview:self.funcPageView];

        self.debugPageView = [[UIView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.debugPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.debugPageView.hidden = YES;
        [self addSubview:self.debugPageView];

        self.musicPageView = [[MusicManagerView alloc] initWithFrame:CGRectMake(75, 0, rightW, frame.size.height)];
        self.musicPageView.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.94];
        self.musicPageView.hidden = YES;
        [self addSubview:self.musicPageView];

        [self setupFuncPage];
        [self setupDebugPage];
    }
    return self;
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
    NSArray *debugItems = @[@"翻倍总音量增益", @"高频撕裂清晰度"];
    for (int i = 0; i < debugItems.count; i++) {
        CGFloat y = 15 + i * 55;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 160, 18)];
        lbl.text = debugItems[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 20, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 300 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 1200; slider.value = kMasterGain; }
        if (i == 1) { slider.minimumValue = 0; slider.maximumValue = 24; slider.value = kHighClarity; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
}

- (void)tabClicked:(UIButton *)btn {
    self.funcPageView.hidden = YES;
    self.debugPageView.hidden = YES;
    self.musicPageView.hidden = YES;

    if (btn.tag == 200) {
        self.funcPageView.hidden = NO;
    } else if (btn.tag == 201) {
        self.debugPageView.hidden = NO;
    } else if (btn.tag == 202) {
        self.musicPageView.hidden = NO;
        [self.musicPageView refreshFileList];
    }
}

- (void)onSliderChanged:(UISlider *)slider {
    if (slider.tag == 300) kMasterGain = slider.value;
    if (slider.tag == 301) kHighClarity = slider.value;
    ApplyEnhancedAudioDSP(g_activeZegoApi);
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
    ApplyEnhancedAudioDSP(g_activeZegoApi);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// ---------------------- 注入与手势唤醒 ----------------------
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

    // 兼容 iOS 13+ 获取 keyWindow
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        targetWindow = w;
                        break;
                    }
                }
                if (targetWindow) break;
            }
        }
    }
    if (!targetWindow) {
        targetWindow = [UIApplication sharedApplication].windows.firstObject;
    }

    if (!g_hudInstance) {
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 280, 230)];
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
