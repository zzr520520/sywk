#import <UIKit/UIKit.h>
#import <substrate.h>

// ---------------------- 状态管理 ----------------------
typedef enum : NSUInteger {
    AudioMode_Normal = 0,
    AudioMode_NewFight,   // 新清晰搏击
    AudioMode_OldFight,   // 旧清晰搏击
    AudioMode_SuperFight  // 超级战斗
} AudioFightMode;

static BOOL kForceOpenMic = NO;       // 强制开麦
static BOOL kDoubleVoice = NO;        // 双音效果
static AudioFightMode kCurrentMode = AudioMode_NewFight; // 默认新清晰搏击
static __weak id g_currentZegoApi = nil;

@interface NSObject (ZegoLiveRoomDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (bool)enableLoopback:(bool)enable;
- (bool)setLoopbackVolume:(int)volume;
- (bool)enableMic:(bool)enable;
@end

// ---------------------- 音频 DSP 调度核心 ----------------------
static void ApplyAudioDSPMatrix(id zegoApi) {
    if (!zegoApi) return;

    // 1. 强制开麦处理
    if (kForceOpenMic) {
        [zegoApi enableMic:YES];
    }

    // 2. 双音效果（开启 Loopback 环回耳返混响叠加）
    if (kDoubleVoice) {
        [zegoApi enableLoopback:YES];
        [zegoApi setLoopbackVolume:100];
    } else {
        [zegoApi enableLoopback:NO];
    }

    // 3. 各种战斗/搏击音效模式分流
    switch (kCurrentMode) {
        case AudioMode_NewFight: {
            // 【新清晰搏击】：极度清晰，中高频刺耳穿透，压低杂音低频
            [zegoApi enableAGC:NO];
            [zegoApi enableNoiseSuppress:NO];
            [zegoApi setCaptureVolume:400];
            
            [zegoApi setAudioEqualizerGain:3.0f index:2];  // 125Hz 适度
            [zegoApi setAudioEqualizerGain:-6.0f index:4]; // 500Hz 大幅削减混浊
            [zegoApi setAudioEqualizerGain:10.0f index:6]; // 2kHz 齿音强化
            [zegoApi setAudioEqualizerGain:12.0f index:7]; // 4kHz 极高清晰度
            break;
        }
        case AudioMode_OldFight: {
            // 【旧清晰搏击】：浑厚爆发型，加重低频共鸣与重音打击感
            [zegoApi enableAGC:NO];
            [zegoApi enableNoiseSuppress:NO];
            [zegoApi setCaptureVolume:350];
            
            [zegoApi setAudioEqualizerGain:9.0f index:2];  // 125Hz 饱满重拳
            [zegoApi setAudioEqualizerGain:6.0f index:3];  // 250Hz 胸腔共鸣
            [zegoApi setAudioEqualizerGain:-2.0f index:4]; // 500Hz
            [zegoApi setAudioEqualizerGain:6.0f index:6];  // 2kHz
            [zegoApi setAudioEqualizerGain:6.0f index:7];  // 4kHz
            break;
        }
        case AudioMode_SuperFight: {
            // 【超级战斗效果】：最大极限音量轰炸压制
            [zegoApi enableAGC:NO];
            [zegoApi enableNoiseSuppress:NO];
            [zegoApi setCaptureVolume:600]; // 极限音量
            
            [zegoApi setAudioEqualizerGain:10.0f index:2]; // 低频拉满
            [zegoApi setAudioEqualizerGain:4.0f index:5];  // 1kHz 能量集中
            [zegoApi setAudioEqualizerGain:9.0f index:6];  // 2kHz 穿透
            [zegoApi setAudioEqualizerGain:10.0f index:7]; // 4kHz 穿透
            break;
        }
        case AudioMode_Normal:
        default: {
            // 恢复默认
            [zegoApi enableAGC:YES];
            [zegoApi enableNoiseSuppress:YES];
            [zegoApi setCaptureVolume:100];
            for (int i = 0; i < 10; i++) {
                [zegoApi setAudioEqualizerGain:0.0f index:i];
            }
            break;
        }
    }
}

// ---------------------- Hook Zego 引擎 ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id instance = %orig;
    g_currentZegoApi = instance;
    return instance;
}

- (bool)setCaptureVolume:(int)volume {
    g_currentZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) {
        int v = (kCurrentMode == AudioMode_SuperFight) ? 600 : 400;
        return %orig(v);
    }
    return %orig(volume);
}

- (bool)enableAGC:(bool)enable {
    g_currentZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)enableNoiseSuppress:(bool)enable {
    g_currentZegoApi = self;
    if (kCurrentMode != AudioMode_Normal) return %orig(NO);
    return %orig(enable);
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyAudioDSPMatrix(self);
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyAudioDSPMatrix(self);
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyAudioDSPMatrix(self);
    return res;
}

%end

// ---------------------- 完整多功能浮窗 UI ----------------------
@interface BattleFullMenuView : UIView
@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swDoubleVoice;
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

@implementation BattleFullMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;
        
        // 拖动手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // 1. 左侧功能 Tab 侧边栏（宽度 75）
        UIView *leftTab = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 75, frame.size.height)];
        leftTab.backgroundColor = [UIColor colorWithRed:0.75 green:0.88 blue:1.0 alpha:0.95];
        [self addSubview:leftTab];

        NSArray *tabs = @[@"功能", @"调试", @"音乐", @"设置"];
        for (int i = 0; i < tabs.count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(5, 15 + i * 48, 65, 38);
            [btn setTitle:tabs[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:1.0] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.7];
            btn.layer.cornerRadius = 8;
            [leftTab addSubview:btn];
        }

        // 2. 右侧功能操作面板
        UIView *rightPanel = [[UIView alloc] initWithFrame:CGRectMake(75, 0, frame.size.width - 75, frame.size.height)];
        rightPanel.backgroundColor = [UIColor colorWithRed:0.15 green:0.18 blue:0.25 alpha:0.88];
        [self addSubview:rightPanel];

        // 添加选择进程条
        UILabel *procLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, rightPanel.frame.size.width - 30, 26)];
        procLabel.text = @"选择进程: 声控物语 (活跃)";
        procLabel.textColor = [UIColor whiteColor];
        procLabel.font = [UIFont systemFontOfSize:12];
        procLabel.textAlignment = NSTextAlignmentCenter;
        procLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
        procLabel.layer.cornerRadius = 13;
        procLabel.clipsToBounds = YES;
        [rightPanel addSubview:procLabel];

        // 3. 构建 5 个功能行
        NSArray *titles = @[@"强制开麦", @"双音效果", @"新清晰搏击效果", @"旧清晰搏击效果", @"超级战斗效果"];
        for (int i = 0; i < titles.count; i++) {
            CGFloat y = 46 + i * 38;
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, rightPanel.frame.size.width - 20, 34)];
            row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
            row.layer.cornerRadius = 8;
            [rightPanel addSubview:row];

            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, 120, 24)];
            titleLbl.text = titles[i];
            titleLbl.textColor = [UIColor whiteColor];
            titleLbl.font = [UIFont boldSystemFontOfSize:12.5];
            [row addSubview:titleLbl];

            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 56, 2, 45, 26)];
            sw.transform = CGAffineTransformMakeScale(0.75, 0.75);
            sw.tag = 100 + i;
            [sw addTarget:self action:@selector(onSwitchToggle:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:sw];

            if (i == 0) self.swForceMic = sw;
            if (i == 1) self.swDoubleVoice = sw;
            if (i == 2) { self.swNewFight = sw; [sw setOn:YES]; }
            if (i == 3) self.swOldFight = sw;
            if (i == 4) self.swSuperFight = sw;
        }
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

- (void)onSwitchToggle:(UISwitch *)sender {
    if (sender == self.swForceMic) {
        kForceOpenMic = sender.isOn;
    } else if (sender == self.swDoubleVoice) {
        kDoubleVoice = sender.isOn;
    } else if (sender == self.swNewFight) {
        if (sender.isOn) {
            kCurrentMode = AudioMode_NewFight;
            [self.swOldFight setOn:NO animated:YES];
            [self.swSuperFight setOn:NO animated:YES];
        } else {
            kCurrentMode = AudioMode_Normal;
        }
    } else if (sender == self.swOldFight) {
        if (sender.isOn) {
            kCurrentMode = AudioMode_OldFight;
            [self.swNewFight setOn:NO animated:YES];
            [self.swSuperFight setOn:NO animated:YES];
        } else {
            kCurrentMode = AudioMode_Normal;
        }
    } else if (sender == self.swSuperFight) {
        if (sender.isOn) {
            kCurrentMode = AudioMode_SuperFight;
            [self.swNewFight setOn:NO animated:YES];
            [self.swOldFight setOn:NO animated:YES];
        } else {
            kCurrentMode = AudioMode_Normal;
        }
    }
    ApplyAudioDSPMatrix(g_currentZegoApi);
}

@end

// ---------------------- 手势防抖与单例调度器 ----------------------
static BattleFullMenuView *g_menuView = nil;
static NSTimeInterval g_lastTapTime = 0; // 防抖时间戳

@interface GlobalGestureManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)setupWithWindow:(UIWindow *)window;
@end

@implementation GlobalGestureManager

+ (instancetype)shared {
    static GlobalGestureManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GlobalGestureManager alloc] init];
    });
    return instance;
}

- (void)setupWithWindow:(UIWindow *)window {
    if (!window) return;
    for (UIGestureRecognizer *g in window.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]] && ((UITapGestureRecognizer *)g).numberOfTouchesRequired == 2) {
            return; // 避免重复添加
        }
    }
    UITapGestureRecognizer *twoFingerDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTriggerTap:)];
    twoFingerDoubleTap.numberOfTouchesRequired = 2; // 双指
    twoFingerDoubleTap.numberOfTapsRequired = 2;    // 双击
    twoFingerDoubleTap.cancelsTouchesInView = NO;
    twoFingerDoubleTap.delegate = self;
    [window addGestureRecognizer:twoFingerDoubleTap];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleTriggerTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;

    // 【防抖保护】：0.5 秒内多次触发直接丢弃，彻底解决多 Window 秒显秒退 Bug
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastTapTime < 0.5) return;
    g_lastTapTime = now;

    UIWindow *targetWindow = [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;

    if (!g_menuView) {
        g_menuView = [[BattleFullMenuView alloc] initWithFrame:CGRectMake(20, 100, 275, 245)];
        [targetWindow addSubview:g_menuView];
        return;
    }

    if (g_menuView.hidden || g_menuView.alpha < 0.1f) {
        if (g_menuView.superview != targetWindow) {
            [targetWindow addSubview:g_menuView];
        }
        [targetWindow bringSubviewToFront:g_menuView];
        g_menuView.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            g_menuView.alpha = 1.0f;
        }];
    } else {
        [UIView animateWithDuration:0.25 animations:^{
            g_menuView.alpha = 0.0f;
        } completion:^(BOOL finished) {
            g_menuView.hidden = YES;
        }];
    }
}

@end

// ---------------------- 注入启动入口 ----------------------
%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    [[GlobalGestureManager shared] setupWithWindow:self];
}

%end
