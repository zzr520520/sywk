#import <UIKit/UIKit.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>

typedef enum : NSUInteger {
    FightMode_Normal = 0,
    FightMode_New,      // 新清晰 (400 增益 + 齿音穿透)
    FightMode_Old,      // 旧清晰 (600 增益 + 饱满洪亮)
    FightMode_Super     // 超级清晰 (1000 封顶增益 + 极致清晰洪亮)
} FightAudioMode;

static BOOL kForceOpenMic = YES;      // 强制开麦
static BOOL kOffSeatSpeak = NO;       // 台下常驻开麦 / 防踢防哑
static BOOL kDebugCaptureHTTP = NO;   // 抓包调试模式：捕获房间相关 HTTP 请求并弹窗显示
static FightAudioMode kCurrentFightMode = FightMode_New;

static float kNewFightGain = 400.0f;
static float kOldFightGain = 600.0f;
static float kSuperFightGain = 1000.0f;
static float kVoiceGainRatio = 1.0f;

static __weak id g_activeZegoEngine = nil;
static __weak id g_activeZegoManager = nil;
static dispatch_source_t g_keepAliveTimer = nil;

// ---------------------- 前置函数声明 ----------------------
static void ApplyCrystalLoudVoiceDSP(id zegoApi);
static void StartKeepAliveService(void);
static UIWindow *GetKeyWindow(void);
static void EnsureAllStreamsPlaying(id mgr);

// ---------------------- 接口声明 (严格对齐逆向分析报告) ----------------------
@interface ZegoAudioRoomApi : NSObject
- (BOOL)startPublish;
- (BOOL)startPublishWithStreamID:(NSString *)streamID;
- (void)stopPublish;
- (BOOL)startPlayStream:(NSString *)streamID;
- (void)stopPlayStream:(NSString *)streamID;
- (BOOL)enableMic:(BOOL)enable;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)setCaptureVolume:(int)volume;
- (bool)enableAGC:(bool)enable;
- (bool)enableNoiseSuppress:(bool)enable;
- (bool)enableAEC:(bool)enable;
- (bool)setAudioEqualizerGain:(float)gain index:(int)index;
- (BOOL)logoutRoom;
@end

@interface SKAudioZegoManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) ZegoAudioRoomApi *zegoEngine;
@property (nonatomic, strong) NSArray *allStreamList;
@property (nonatomic, strong) NSArray *streamList;
@property (nonatomic, strong) NSTimer *startPushTimer;
@property (nonatomic, copy) NSString *roomId;
@property (nonatomic, copy) NSString *userId;
- (void)setupENgine;
- (void)startPublishing;
- (void)stopPublishing;
- (void)muteMic:(BOOL)mute;
- (void)muteAllRemote:(BOOL)mute;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)checkAllStreams;
- (void)changeRoleToChat:(NSInteger)role;
- (BOOL)leaveRoomWithCompletionBlock:(void (^)(void))block;
- (void)removeStreamListAll;
- (void)onStreamUpdated:(NSUInteger)type stream:(NSArray *)streams;
- (void)onPublishStateUpdate:(int)stateCode streamID:(NSString *)streamID streamInfo:(id)info;
- (void)onKickOut:(int)code roomID:(NSString *)roomID;
@end

@interface SKAudioManager : NSObject
@property (nonatomic, strong) SKAudioZegoManager *manager;
- (void)muteMic:(BOOL)mute;
- (BOOL)enableSpeaker:(BOOL)enable;
- (void)changeRoleToChat:(NSInteger)role;
- (BOOL)leaveRoomWithCompletionBlock:(void (^)(void))block;
@end

@interface SWRoomMicroModel : NSObject
@property (nonatomic, assign) NSInteger microphoneIndex;
@property (nonatomic, copy) NSString *userId;
- (BOOL)isDownMicCommand;
- (BOOL)isOnMicroOperate;
- (BOOL)isUpableMicro;
- (BOOL)isCurrentUser;
@end

@interface RCChatRoomClient : NSObject
- (void)quitChatRoom:(NSString *)roomId success:(void (^)(void))successBlock error:(void (^)(int status))errorBlock;
- (void)setChatRoomEntry:(NSString *)roomId key:(NSString *)key value:(NSString *)value sendNotification:(BOOL)sendNotification autoDelete:(BOOL)autoDelete notificationExtra:(NSString *)extra success:(void (^)(void))successBlock error:(void (^)(int status))errorBlock;
@end

@interface SWSharePhotosView : UIView
- (void)clickEmptySeatWithModel:(id)model headerView:(id)headerView;
@end

// ---------------------- 兼容 iOS 13+ 获取 keyWindow ----------------------
static UIWindow *GetKeyWindow() {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
}

// ---------------------- 融云长连接信令捕获弹窗 ----------------------
static void ShowCapturedLog(NSString *title, NSString *content) {
    NSLog(@"[SKWY_RONG_CAPTURED] %@: %@", title, content);
    [UIPasteboard generalPasteboard].string = content;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:content
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"已复制" style:UIAlertActionStyleDefault handler:nil]];

        UIWindow *keyWin = GetKeyWindow();
        if (!keyWin) return;
        UIViewController *rootVC = keyWin.rootViewController;
        while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

// ---------------------- 纯净清晰洪亮调音矩阵 ----------------------
static void ApplyCrystalLoudVoiceDSP(id zegoApi) {
    if (!zegoApi) return;

    if ([zegoApi respondsToSelector:@selector(enableSpeaker:)]) {
        [zegoApi enableSpeaker:YES];
    }

    if ((kForceOpenMic || kOffSeatSpeak) && [zegoApi respondsToSelector:@selector(enableMic:)]) {
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

    // 关停 3A 压制
    if ([zegoApi respondsToSelector:@selector(enableAGC:)]) [zegoApi enableAGC:NO];
    if ([zegoApi respondsToSelector:@selector(enableNoiseSuppress:)]) [zegoApi enableNoiseSuppress:NO];
    if ([zegoApi respondsToSelector:@selector(enableAEC:)]) [zegoApi enableAEC:NO];

    float baseGain = kNewFightGain;
    if (kCurrentFightMode == FightMode_Old) baseGain = kOldFightGain;
    if (kCurrentFightMode == FightMode_Super) baseGain = kSuperFightGain;
    int finalVolume = (int)(baseGain * kVoiceGainRatio);

    if ([zegoApi respondsToSelector:@selector(setCaptureVolume:)]) {
        [zegoApi setCaptureVolume:finalVolume];
    }

    if ([zegoApi respondsToSelector:@selector(setAudioEqualizerGain:index:)]) {
        if (kCurrentFightMode == FightMode_New) {
            [zegoApi setAudioEqualizerGain:-12.0f index:0];
            [zegoApi setAudioEqualizerGain:-8.0f  index:1];
            [zegoApi setAudioEqualizerGain:0.0f   index:2];
            [zegoApi setAudioEqualizerGain:-8.0f  index:3];
            [zegoApi setAudioEqualizerGain:-10.0f index:4];
            [zegoApi setAudioEqualizerGain:16.0f  index:5];
            [zegoApi setAudioEqualizerGain:22.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:16.0f  index:8];
            [zegoApi setAudioEqualizerGain:10.0f  index:9];
        } else if (kCurrentFightMode == FightMode_Old) {
            [zegoApi setAudioEqualizerGain:-8.0f  index:0];
            [zegoApi setAudioEqualizerGain:-4.0f  index:1];
            [zegoApi setAudioEqualizerGain:4.0f   index:2];
            [zegoApi setAudioEqualizerGain:-4.0f  index:3];
            [zegoApi setAudioEqualizerGain:-6.0f  index:4];
            [zegoApi setAudioEqualizerGain:18.0f  index:5];
            [zegoApi setAudioEqualizerGain:24.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:18.0f  index:8];
            [zegoApi setAudioEqualizerGain:12.0f  index:9];
        } else if (kCurrentFightMode == FightMode_Super) {
            [zegoApi setAudioEqualizerGain:0.0f   index:0];
            [zegoApi setAudioEqualizerGain:4.0f   index:1];
            [zegoApi setAudioEqualizerGain:8.0f   index:2];
            [zegoApi setAudioEqualizerGain:-2.0f  index:3];
            [zegoApi setAudioEqualizerGain:-4.0f  index:4];
            [zegoApi setAudioEqualizerGain:24.0f  index:5];
            [zegoApi setAudioEqualizerGain:24.0f  index:6];
            [zegoApi setAudioEqualizerGain:24.0f  index:7];
            [zegoApi setAudioEqualizerGain:24.0f  index:8];
            [zegoApi setAudioEqualizerGain:20.0f  index:9];
        }
    }
}

// ---------------------- 核心：多流全量拉流保护（适配任意流对象格式） ----------------------
static void EnsureAllStreamsPlaying(id mgrId) {
    if (!mgrId) return;
    SKAudioZegoManager *mgr = (SKAudioZegoManager *)mgrId;
    if (!mgr.zegoEngine) return;
    NSArray *streams = mgr.allStreamList;
    if (![streams isKindOfClass:[NSArray class]]) return;

    for (id item in streams) {
        NSString *streamID = nil;
        if ([item isKindOfClass:[NSString class]]) {
            streamID = (NSString *)item;
        } else if ([item respondsToSelector:@selector(streamID)]) {
            streamID = [item performSelector:@selector(streamID)];
        } else if ([item respondsToSelector:@selector(valueForKey:)]) {
            @try { streamID = [item valueForKey:@"streamID"]; } @catch (NSException *e) {}
        }
        if (streamID && [streamID isKindOfClass:[NSString class]] && streamID.length > 0) {
            [mgr.zegoEngine startPlayStream:streamID];
        }
    }
}

// ---------------------- 1. HTTP 拦截 + 抓包调试（阻断下麦/被踢/退出房间所有请求） ----------------------
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *urlStr = request.URL.absoluteString;

    // 抓包调试：捕获所有 /room/ 相关请求并弹窗显示
    if (kDebugCaptureHTTP && [urlStr containsString:@"/room/"]) {
        NSString *bodyStr = @"";
        if (request.HTTPBody) {
            bodyStr = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        }
        NSDictionary *headers = request.allHTTPHeaderFields;
        NSString *logInfo = [NSString stringWithFormat:@"URL: %@\n\nMethod: %@\n\nHeaders: %@\n\nBody: %@", urlStr, request.HTTPMethod, headers, bodyStr];

        NSLog(@"[SKWY_HOOK_HTTP] %@", logInfo);

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"捕获到房间请求" message:logInfo preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [UIPasteboard generalPasteboard].string = logInfo;
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

            UIWindow *keyWin = GetKeyWindow();
            UIViewController *rootVC = keyWin.rootViewController;
            while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
            [rootVC presentViewController:alert animated:YES completion:nil];
        });
    }

    // 拦截下麦/被踢/退出房间请求
    if (kForceOpenMic || kOffSeatSpeak) {
        NSArray *blockPaths = @[
            @"/room/microphone/down",
            @"/room/microphone/kick",
            @"/room/out",
            @"/room/user/kick",
            @"/room/microphone/voice/ban"
        ];
        for (NSString *path in blockPaths) {
            if ([urlStr containsString:path]) {
                if (completionHandler) {
                    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
                    NSData *fakeData = [@"{\"code\":200,\"msg\":\"success\",\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
                    completionHandler(fakeData, fakeResp, nil);
                }
                return nil;
            }
        }
    }
    return %orig(request, completionHandler);
}

%end

// ---------------------- 2. 拦截融云聊天室退出 + 麦位 KV 长连接信令捕获 ----------------------
%hook RCChatRoomClient

- (void)quitChatRoom:(NSString *)roomId success:(void (^)(void))successBlock error:(void (^)(int status))errorBlock {
    if (kOffSeatSpeak || kForceOpenMic) {
        if (successBlock) successBlock();
        return;
    }
    %orig(roomId, successBlock, errorBlock);
}

// v7.9.0: 捕获融云麦位 KV 状态修改（上麦/下麦/锁麦核心长连接接口）
- (void)setChatRoomEntry:(NSString *)roomId
                     key:(NSString *)key
                   value:(NSString *)value
        sendNotification:(BOOL)sendNotification
              autoDelete:(BOOL)autoDelete
       notificationExtra:(NSString *)extra
                 success:(void (^)(void))successBlock
                   error:(void (^)(int status))errorBlock {

    NSString *log = [NSString stringWithFormat:@"【融云上麦/改麦KV】\nroomId: %@\nKey: %@\nValue: %@\nExtra: %@\nsendNotification: %d\nautoDelete: %d", roomId, key, value, extra, sendNotification, autoDelete];

    if (kDebugCaptureHTTP) {
        ShowCapturedLog(@"捕获到融云上麦长连接", log);
    }

    %orig(roomId, key, value, sendNotification, autoDelete, extra, successBlock, errorBlock);
}

%end

// ---------------------- 2b. 拦截麦位视图点击事件（上麦 UI 入口） ----------------------
%hook SWSharePhotosView

- (void)clickEmptySeatWithModel:(id)model headerView:(id)headerView {
    if (kDebugCaptureHTTP) {
        NSString *modelDesc = [NSString stringWithFormat:@"%@", model];
        NSString *log = [NSString stringWithFormat:@"【麦位点击触发】\nModel: %@\nHeaderView: %@", modelDesc, headerView];
        ShowCapturedLog(@"捕获到点击空麦位", log);
    }
    %orig(model, headerView);
}

%end

// ---------------------- 3. 麦位本地模型状态伪装（报告 4.3 节） ----------------------
%hook SWRoomMicroModel

- (BOOL)isDownMicCommand {
    if (kOffSeatSpeak || kForceOpenMic) return NO;
    return %orig;
}

- (BOOL)isOnMicroOperate {
    if (kOffSeatSpeak || kForceOpenMic) return YES;
    return %orig;
}

- (BOOL)isCurrentUser {
    if (kOffSeatSpeak) return YES;
    return %orig;
}

%end

// ---------------------- 4. 即构业务音频管理器 Hook（报告 4.2 节） ----------------------
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
    }
}

// 拦截房间退出，防止资源被主动释放
- (BOOL)leaveRoomWithCompletionBlock:(void (^)(void))block {
    if (kOffSeatSpeak || kForceOpenMic) {
        if (block) block();
        return NO;
    }
    return %orig(block);
}

// 彻底拦截角色降级为观众
- (void)changeRoleToChat:(NSInteger)role {
    if (kOffSeatSpeak || kForceOpenMic) return;
    %orig(role);
}

// 彻底禁止静音房间其他人的声音
- (void)muteAllRemote:(BOOL)mute {
    %orig(NO);
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic || kOffSeatSpeak) {
        %orig(NO);
    } else {
        %orig(mute);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

// 拦截下麦停推指令
- (void)stopPublishing {
    if (kOffSeatSpeak || kForceOpenMic) {
        [self muteAllRemote:NO];
        [self enableSpeaker:YES];
        EnsureAllStreamsPlaying(self);
        return;
    }
    %orig;
    [self muteAllRemote:NO];
    EnsureAllStreamsPlaying(self);
}

- (void)startPublishing {
    %orig;
    g_activeZegoManager = self;
    if (self.zegoEngine) {
        g_activeZegoEngine = self.zegoEngine;
    }
    [self muteAllRemote:NO];
    [self enableSpeaker:YES];
    EnsureAllStreamsPlaying(self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
    });
}

// 拦截推流状态错误（非0错误码时自动重新推流）
- (void)onPublishStateUpdate:(int)stateCode streamID:(NSString *)streamID streamInfo:(id)info {
    if (kOffSeatSpeak || kForceOpenMic) {
        if (stateCode != 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startPublishing];
            });
            return;
        }
    }
    %orig;
}

// 拦截被踢/断线回调
- (void)onKickOut:(int)code roomID:(NSString *)roomID {
    if (kOffSeatSpeak || kForceOpenMic) {
        [self muteAllRemote:NO];
        [self enableSpeaker:YES];
        EnsureAllStreamsPlaying(self);
        return;
    }
    %orig;
}

- (void)onStreamUpdated:(NSUInteger)type stream:(NSArray *)streams {
    %orig(type, streams);
    [self muteAllRemote:NO];
    [self enableSpeaker:YES];
    EnsureAllStreamsPlaying(self);
}

- (void)removeStreamListAll {
    if (kOffSeatSpeak || kForceOpenMic) return;
    %orig;
}

- (void)setStartPushTimer:(NSTimer *)timer {
    if ((kOffSeatSpeak || kForceOpenMic) && timer == nil) return;
    %orig(timer);
}

%end

%hook SKAudioManager

- (BOOL)leaveRoomWithCompletionBlock:(void (^)(void))block {
    if (kOffSeatSpeak || kForceOpenMic) {
        if (block) block();
        return NO;
    }
    return %orig(block);
}

- (void)muteMic:(BOOL)mute {
    if (kForceOpenMic || kOffSeatSpeak) {
        %orig(NO);
    } else {
        %orig(mute);
    }
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (void)changeRoleToChat:(NSInteger)role {
    if (kOffSeatSpeak || kForceOpenMic) return;
    %orig(role);
}

%end

// ---------------------- 5. 即构底核 API 拦截（报告 3.2 节） ----------------------
%hook ZegoAudioRoomApi

- (id)initWithAppID:(unsigned int)appID appSignature:(NSData *)appSignature {
    id inst = %orig;
    g_activeZegoEngine = inst;
    return inst;
}

- (BOOL)logoutRoom {
    if (kOffSeatSpeak || kForceOpenMic) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableSpeaker:(BOOL)enable {
    return %orig(YES);
}

- (BOOL)enableMic:(BOOL)enable {
    g_activeZegoEngine = self;
    if (kForceOpenMic || kOffSeatSpeak) return %orig(YES);
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

- (void)stopPublish {
    if (kOffSeatSpeak || kForceOpenMic) return;
    %orig;
}

- (void)stopPlayStream:(NSString *)streamID {
    if (kOffSeatSpeak || kForceOpenMic) {
        return;
    }
    %orig(streamID);
}

%end

// ---------------------- 保活守护线程 ----------------------
static void StartKeepAliveService() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.8 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_activeZegoEngine) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([g_activeZegoEngine respondsToSelector:@selector(enableSpeaker:)]) {
                        [g_activeZegoEngine enableSpeaker:YES];
                    }
                    if (kCurrentFightMode != FightMode_Normal || kOffSeatSpeak || kForceOpenMic) {
                        ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
                    }
                });
            }
            if (g_activeZegoManager && (kForceOpenMic || kOffSeatSpeak)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SKAudioZegoManager *mgr = (SKAudioZegoManager *)g_activeZegoManager;
                    [mgr muteAllRemote:NO];
                    [mgr enableSpeaker:YES];
                    EnsureAllStreamsPlaying(mgr);
                });
            }
        });
        dispatch_resume(g_keepAliveTimer);
    });
}

// ---------------------- 主面板 HUD ----------------------
@interface BattleMasterHUD : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *funcPageView;
@property (nonatomic, strong) UIScrollView *debugPageView;

@property (nonatomic, strong) UISwitch *swForceMic;
@property (nonatomic, strong) UISwitch *swOffSeatSpeak;
@property (nonatomic, strong) UISwitch *swDebugCapture;
@property (nonatomic, strong) UISwitch *swNewFight;
@property (nonatomic, strong) UISwitch *swOldFight;
@property (nonatomic, strong) UISwitch *swSuperFight;
@end

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
        self.debugPageView.contentSize = CGSizeMake(rw, 280);
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
    proc.text = @"选择进程: 声控物语 (活跃)";
    proc.textColor = [UIColor whiteColor];
    proc.font = [UIFont systemFontOfSize:11];
    proc.textAlignment = NSTextAlignmentCenter;
    proc.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    proc.layer.cornerRadius = 10;
    proc.clipsToBounds = YES;
    [self.funcPageView addSubview:proc];

    NSArray *titles = @[@"强制开麦", @"台下常驻开麦", @"抓包调试", @"新清晰效果", @"旧清晰效果", @"超级清晰效果"];
    for (int i = 0; i < titles.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(8, 30 + i * 32, self.funcPageView.frame.size.width - 16, 28)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        row.layer.cornerRadius = 5;
        [self.funcPageView addSubview:row];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 2, 120, 24)];
        lbl.text = titles[i];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:11.5];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.frame.size.width - 48, 0, 40, 24)];
        sw.transform = CGAffineTransformMakeScale(0.68, 0.68);
        [sw addTarget:self action:@selector(onFuncSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        if (i == 0) { self.swForceMic = sw; [sw setOn:kForceOpenMic]; }
        if (i == 1) { self.swOffSeatSpeak = sw; [sw setOn:kOffSeatSpeak]; }
        if (i == 2) { self.swDebugCapture = sw; [sw setOn:kDebugCaptureHTTP]; }
        if (i == 3) { self.swNewFight = sw; [sw setOn:YES]; }
        if (i == 4) self.swOldFight = sw;
        if (i == 5) self.swSuperFight = sw;
    }
}

- (void)setupDebugPage {
    NSArray *items = @[@"新清晰音量 (默认400)", @"旧清晰音量 (默认600)", @"超级清晰音量 (默认1000)", @"人声音量权重"];
    for (int i = 0; i < items.count; i++) {
        CGFloat y = 8 + i * 58;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, self.debugPageView.frame.size.width - 24, 16)];
        lbl.text = items[i];
        lbl.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        lbl.font = [UIFont boldSystemFontOfSize:11];
        [self.debugPageView addSubview:lbl];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 18, self.debugPageView.frame.size.width - 24, 20)];
        slider.tag = 500 + i;
        if (i == 0) { slider.minimumValue = 100; slider.maximumValue = 800;  slider.value = kNewFightGain; }
        if (i == 1) { slider.minimumValue = 300; slider.maximumValue = 1200; slider.value = kOldFightGain; }
        if (i == 2) { slider.minimumValue = 500; slider.maximumValue = 2000; slider.value = kSuperFightGain; }
        if (i == 3) { slider.minimumValue = 0.5f; slider.maximumValue = 2.0f;  slider.value = kVoiceGainRatio; }
        [slider addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.debugPageView addSubview:slider];
    }
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
    ApplyCrystalLoudVoiceDSP(g_activeZegoEngine);
}

- (void)onFuncSwitch:(UISwitch *)s {
    if (s == self.swForceMic) kForceOpenMic = s.isOn;
    if (s == self.swDebugCapture) {
        kDebugCaptureHTTP = s.isOn;
        if (s.isOn) {
            // 开启抓包时提示用户操作 App
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *hint = [UIAlertController alertControllerWithTitle:@"抓包调试已开启" message:@"现在操作房间相关功能（上麦/下麦/踢人等），请求参数将自动弹窗显示并可复制。" preferredStyle:UIAlertControllerStyleAlert];
                [hint addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
                UIWindow *keyWin = GetKeyWindow();
                UIViewController *rootVC = keyWin.rootViewController;
                while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
                [rootVC presentViewController:hint animated:YES completion:nil];
            });
        }
    }
    if (s == self.swOffSeatSpeak) {
        kOffSeatSpeak = s.isOn;
        if (g_activeZegoManager) {
            SKAudioZegoManager *mgr = (SKAudioZegoManager *)g_activeZegoManager;
            [mgr muteAllRemote:NO];
            [mgr enableSpeaker:YES];
            if (kOffSeatSpeak) {
                [mgr muteMic:NO];
                [mgr startPublishing];
            }
            EnsureAllStreamsPlaying(mgr);
        }
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

// ---------------------- 手势与窗口装载 ----------------------
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
    if (!targetWindow) return;

    if (!g_hudInstance) {
        g_hudInstance = [[BattleMasterHUD alloc] initWithFrame:CGRectMake(25, 120, 285, 230)];
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
