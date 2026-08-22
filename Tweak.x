#import <UIKit/UIKit.h>
#import <substrate.h>

// 全局控制参数
static BOOL kBattleEffectEnabled = YES;
static int kForcedGain = 400; // 麦克风增益倍数
static __weak id g_currentZegoApi = nil; // 动态跟踪活跃的 Zego API 对象

// 声明外部未公开方法的接口，避免 clang 报 undeclared selector 错误
@interface NSObject (ZegoLiveRoomApiDeclarations)
- (bool)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
@end

// 核心调音逻辑：暴力增益 + 关闭 3A + 搏击人声 EQ 增强
static void ApplyBattleAudioSettings(id zegoApi) {
    if (!zegoApi) return;
    
    if (kBattleEffectEnabled) {
        // 1. 关闭 3A 防止大喊时音量被自动拉低或当成啸叫被切断
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) {
            [zegoApi enableAGC:NO];
        }
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) {
            [zegoApi enableNoiseSuppress:NO];
        }
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
            [zegoApi setCaptureVolume:kForcedGain];
        }
        
        // 2. 注入 10 段 EQ 搏击参数（低频爆发 + 中高频极致清晰穿透）
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            [zegoApi setAudioEqualizerGain:8.0f index:2];  // 125Hz 强化胸腔共鸣打击感
            [zegoApi setAudioEqualizerGain:-3.0f index:4]; // 500Hz 削减浑浊感
            [zegoApi setAudioEqualizerGain:7.0f index:6];  // 2kHz 强化人声齿音
            [zegoApi setAudioEqualizerGain:9.0f index:7];  // 4kHz 提高咬字清晰度
        }
    } else {
        // 恢复默认配置
        if ([zegoApi respondsToSelector:@selector(enableAGC:)]) {
            [zegoApi enableAGC:YES];
        }
        if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) {
            [zegoApi enableNoiseSuppress:YES];
        }
        if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
            [zegoApi setCaptureVolume:100];
        }
        if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
            for (int i = 0; i < 10; i++) {
                [zegoApi setAudioEqualizerGain:0.0f index:i];
            }
        }
    }
}

// ---------------------- Hook Zego 核心类 ----------------------
%hook ZegoLiveRoomApi

- (id)init {
    id instance = %orig;
    g_currentZegoApi = instance;
    return instance;
}

- (bool)setCaptureVolume:(int)volume {
    g_currentZegoApi = self;
    if (kBattleEffectEnabled) {
        return %orig(kForcedGain);
    }
    return %orig(volume);
}

- (bool)enableAGC:(bool)enable {
    g_currentZegoApi = self;
    if (kBattleEffectEnabled) {
        return %orig(NO);
    }
    return %orig(enable);
}

- (bool)enableNoiseSuppress:(bool)enable {
    g_currentZegoApi = self;
    if (kBattleEffectEnabled) {
        return %orig(NO);
    }
    return %orig(enable);
}

- (bool)startPublishing:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyBattleAudioSettings(self);
    return res;
}

- (bool)startPublishing2:(NSString *)streamID title:(NSString *)title flag:(int)flag extraInfo:(NSString *)extraInfo params:(NSString *)params channelIndex:(int)channelIndex {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyBattleAudioSettings(self);
    return res;
}

- (bool)startPublishWithParams:(id)params {
    g_currentZegoApi = self;
    bool res = %orig;
    ApplyBattleAudioSettings(self);
    return res;
}

%end

// ---------------------- 浮窗 UI ----------------------
@interface FightAssistantOverlayView : UIView
@property (nonatomic, strong) UISwitch *battleSwitch;
@end

@implementation FightAssistantOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.88];
        self.layer.cornerRadius = 14;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        self.layer.borderWidth = 1.0;
        self.clipsToBounds = YES;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.4;
        self.layer.shadowRadius = 8;
        
        // 拖动手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        
        // 标题标签
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 15, 120, 24)];
        title.text = @"搏击战斗音效";
        title.font = [UIFont boldSystemFontOfSize:14];
        title.textColor = [UIColor whiteColor];
        [self addSubview:title];
        
        // 功能开关
        self.battleSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(140, 12, 51, 31)];
        [self.battleSwitch setOn:kBattleEffectEnabled];
        [self.battleSwitch setOnTintColor:[UIColor colorWithRed:0.22 green:0.55 blue:0.95 alpha:1.0]];
        [self.battleSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.battleSwitch];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

- (void)switchChanged:(UISwitch *)sender {
    kBattleEffectEnabled = sender.isOn;
    if (g_currentZegoApi) {
        ApplyBattleAudioSettings(g_currentZegoApi);
    }
}

@end

// ---------------------- 全局双指双击手势管理器 ----------------------
static FightAssistantOverlayView *g_menuView = nil;

@interface GestureDispatcher : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToWindow:(UIWindow *)window;
@end

@implementation GestureDispatcher

+ (instancetype)shared {
    static GestureDispatcher *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GestureDispatcher alloc] init];
    });
    return instance;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    UITapGestureRecognizer *twoFingerDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTriggerTap:)];
    twoFingerDoubleTap.numberOfTouchesRequired = 2; // 双指
    twoFingerDoubleTap.numberOfTapsRequired = 2;    // 双击
    twoFingerDoubleTap.cancelsTouchesInView = NO;   // 不截断下层原生点击
    twoFingerDoubleTap.delegate = self;
    [window addGestureRecognizer:twoFingerDoubleTap];
}

// 关键代理：保证手势与 App 自带的滑动、点击共存
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleTriggerTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    
    UIWindow *targetWindow = gesture.view.window ?: (UIWindow *)gesture.view;
    
    if (!g_menuView) {
        g_menuView = [[FightAssistantOverlayView alloc] initWithFrame:CGRectMake(30, 100, 205, 55)];
        [targetWindow addSubview:g_menuView];
        return;
    }
    
    // 切换浮窗显示/隐藏动画
    if (g_menuView.hidden || g_menuView.alpha == 0.0f) {
        g_menuView.hidden = NO;
        if (g_menuView.superview != targetWindow) {
            [targetWindow addSubview:g_menuView];
        }
        [targetWindow bringSubviewToFront:g_menuView];
        [UIView animateWithDuration:0.2 animations:^{
            g_menuView.alpha = 1.0f;
        }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
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
    [[GestureDispatcher shared] attachToWindow:self];
}

%end
