# FightVoicePro v7.8.0 - 声控物语搏击音效插件

内置抓包调试 + 五层闭环防护：HTTP 请求捕获弹窗 + 请求拦截 + 融云退房拦截 + 推流错误自动重推 + 被踢回调拦截 + 多格式全量拉流保护。

## v7.8.0 新增 — 内置抓包调试（免抓包工具）

### 内置 HTTP 请求捕获

无需 Storm Sniffer 等抓包工具，插件直接在 App 内部捕获所有 `/room/` 相关 HTTP 请求并弹窗显示。

| 功能 | 说明 |
|------|------|
| 捕获范围 | 所有 URL 包含 `/room/` 的 HTTP 请求 |
| 显示内容 | URL + Method + Headers + Body |
| 弹窗操作 | 「复制」一键复制到剪贴板 / 「关闭」关闭弹窗 |
| 开关控制 | HUD 面板「抓包调试」开关，默认关闭 |
| 开启提示 | 开启时弹窗提示用户操作 App |
| 系统日志 | 同时输出到 NSLog（`[SKWY_HOOK_HTTP]` 前缀） |

### 使用方法

1. 双指双击屏幕调出 HUD 面板
2. 打开「抓包调试」开关
3. 在 App 中操作房间功能（上麦/下麦/踢人等）
4. 每个房间请求都会弹窗显示完整参数
5. 点击「复制」保存到剪贴板

### 相比外部抓包工具的优势

- 不受系统 VPN 代理策略限制
- 不需要证书信任设置
- 不需要杀掉 App 重启
- 直接获取 App 内部原始请求参数

## v7.7.0 五层闭环防护体系

### 一、v7.7.0 拦截体系（在 v7.6.0 基础上）

| 新增拦截点 | 方法 | 策略 | 解决问题 |
|------------|------|------|----------|
| HTTP 下麦/踢人请求 | `NSURLSession dataTaskWithRequest:` | 拦截 5 类 URL 返回假 200 | 从网络层阻断下麦/踢人/退房/禁言 |
| 融云退房信令 | `RCChatRoomClient quitChatRoom:success:error:` | 拦截+回调 success | 阻断 IM 通道退出导致音频重置 |
| 推流错误自动重推 | `onPublishStateUpdate:streamID:streamInfo:` | 非0错误码 0.5s 后自动 startPublishing | 推流异常时自动恢复 |
| 被踢回调拦截 | `onKickOut:roomID:` | 拦截+恢复拉流 | 即构踢人回调不再触发断流 |
| 多格式全量拉流 | `EnsureAllStreamsPlaying()` | 兼容 NSString/自定义对象 streamID | 适配任意流对象格式，全量 startPlayStream |
| kForceOpenMic 全面联动 | 所有拦截点 | kForceOpenMic 也触发拦截 | 强制开麦时同样防踢防哑 |

### 二、五层防护体系全景

```
被踢/下麦/退房触发
  │
  ├─ 第1层: HTTP 网络拦截
  │   ├─ /room/microphone/down   → 假200响应
  │   ├─ /room/microphone/kick   → 假200响应
  │   ├─ /room/out               → 假200响应
  │   ├─ /room/user/kick         → 假200响应
  │   └─ /room/microphone/voice/ban → 假200响应
  │
  ├─ 第2层: 融云 IM 拦截
  │   └─ RCChatRoomClient.quitChatRoom → 拦截+回调success
  │
  ├─ 第3层: 麦位模型伪装
  │   ├─ SWRoomMicroModel.isDownMicCommand  → 返回NO
  │   ├─ SWRoomMicroModel.isOnMicroOperate  → 返回YES
  │   └─ SWRoomMicroModel.isCurrentUser     → 返回YES
  │
  ├─ 第4层: 房间退出+推流保护
  │   ├─ ZegoAudioRoomApi.logoutRoom           → 返回NO
  │   ├─ SKAudioZegoManager.leaveRoomWithCompletionBlock: → 拦截+回调
  │   ├─ SKAudioManager.leaveRoomWithCompletionBlock:      → 拦截+回调
  │   ├─ changeRoleToChat:                     → 完全return
  │   ├─ setStartPushTimer: nil                → 拦截
  │   ├─ stopPublish                           → 拦截
  │   ├─ stopPublishing                        → 拦截+恢复拉流
  │   ├─ onPublishStateUpdate (非0错误码)      → 0.5s自动重推
  │   └─ onKickOut:roomID:                    → 拦截+恢复拉流
  │
  └─ 第5层: 拉流全量保护
      ├─ stopPlayStream:                       → 直接return
      ├─ removeStreamListAll                   → 拒绝清空
      ├─ muteAllRemote:                        → 强制NO
      ├─ enableSpeaker:                        → 强制YES
      ├─ onStreamUpdated:stream:               → 恢复拉流
      └─ EnsureAllStreamsPlaying()             → 多格式全量startPlayStream

保活线程 (0.8s)
  ├─ enableSpeaker:YES     → 持续锁定扬声器
  ├─ ApplyCrystalDSP       → 刷新增益+EQ参数
  └─ EnsureAllStreamsPlaying → 周期性全量拉流恢复
```

### 三、完整拦截对照表（全部 20 项）

| # | 拦截目标 | 方法 | 拦截策略 | 版本 |
|---|----------|------|----------|------|
| 1 | HTTP 下麦请求 | `dataTaskWithRequest:` | 假200响应 | v7.7.0 |
| 2 | HTTP 踢人请求 | `dataTaskWithRequest:` | 假200响应 | v7.7.0 |
| 3 | HTTP 退房请求 | `dataTaskWithRequest:` | 假200响应 | v7.7.0 |
| 4 | HTTP 禁言请求 | `dataTaskWithRequest:` | 假200响应 | v7.7.0 |
| 5 | 融云退房信令 | `quitChatRoom:success:error:` | 拦截+回调 | v7.7.0 |
| 6 | 推流错误重推 | `onPublishStateUpdate:streamID:streamInfo:` | 非0自动重推 | v7.7.0 |
| 7 | 被踢回调 | `onKickOut:roomID:` | 拦截+恢复拉流 | v7.7.0 |
| 8 | 多格式全量拉流 | `EnsureAllStreamsPlaying()` | 兼容任意流格式 | v7.7.0 |
| 9 | 麦位下麦指令 | `isDownMicCommand` | 返回NO | v7.6.0 |
| 10 | 麦位上麦状态 | `isOnMicroOperate` | 返回YES | v7.6.0 |
| 11 | 当前用户有效 | `isCurrentUser` | 返回YES | v7.6.0 |
| 12 | 引擎退出房间 | `logoutRoom` | 返回NO | v7.6.0 |
| 13 | 管理器退出房间 | `leaveRoomWithCompletionBlock:` | 拦截+回调 | v7.6.0 |
| 14 | 单路拉流停止 | `stopPlayStream:` | 直接return | v7.6.0 |
| 15 | 角色降级 | `changeRoleToChat:` | 完全return | v7.5.0 |
| 16 | 推流心跳销毁 | `setStartPushTimer:` | nil时拦截 | v7.4.0 |
| 17 | 拉流列表清空 | `removeStreamListAll` | 拒绝清空 | v7.4.0 |
| 18 | 远端流变动 | `onStreamUpdated:stream:` | 恢复拉流 | v7.4.0 |
| 19 | 底层停推 | `stopPublish` | 拦截 | v7.3.0 |
| 20 | 业务层停推 | `stopPublishing` | 拦截+恢复 | v7.3.0 |

### 四、三档清晰模式

| 模式 | 增益 | 特点 |
|------|------|------|
| 新清晰 | 400 | 齿音穿透、人声透亮 |
| 旧清晰 | 600 | 饱满洪亮 |
| 超级清晰 | 1000 | 封顶功率 + 极致清晰 |

### 五、纯净人声 EQ 曲线

| 频段 | 新清晰 | 旧清晰 | 超级清晰 |
|------|--------|--------|----------|
| 31Hz | -12dB | -8dB | 0dB |
| 62Hz | -8dB | -4dB | +4dB |
| 125Hz | 0dB | +4dB | +8dB |
| 250Hz | -8dB | -4dB | -2dB |
| 500Hz | -10dB | -6dB | -4dB |
| 1kHz | +16dB | +18dB | +24dB |
| 2kHz | +22dB | +24dB | +24dB |
| 4kHz | +24dB | +24dB | +24dB |
| 8kHz | +16dB | +18dB | +24dB |
| 16kHz | +10dB | +12dB | +20dB |

## 功能特性

- **内置抓包调试** - 捕获 /room/ 请求弹窗显示 URL/Method/Headers/Body，一键复制
- **HTTP 网络拦截** - 阻断下麦/踢人/退房/禁言 5 类 API 请求
- **融云退房拦截** - quitChatRoom 阻止 IM 通道退出
- **推流错误自动重推** - onPublishStateUpdate 非0错误码 0.5s 自动恢复
- **被踢回调拦截** - onKickOut 拦截并恢复全量拉流
- **多格式全量拉流** - EnsureAllStreamsPlaying 兼容任意流对象格式
- **kForceOpenMic 全面联动** - 强制开麦时同样触发所有防踢防哑拦截
- **阻断房间退出** - logoutRoom + leaveRoomWithCompletionBlock 双拦截
- **单路拉流防停** - stopPlayStream 直接丢弃
- **麦位模型伪装** - SWRoomMicroModel 三属性从数据源无视下麦
- **终极防掐断** - changeRoleToChat 完全 return + startPushTimer 保护
- **封顶纯净增益** - 400/600/1000 消除方波失真
- **iOS 13+ 兼容** - UIWindowScene 适配 + 手势去重

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：强制开麦 / 台下常驻开麦 / 抓包调试 / 新清晰 / 旧清晰 / 超级清晰
4. **调试 Tab**：调节各档位音量（100~2000）和人声权重

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics
