# FightVoicePro v7.6.0 - 声控物语搏击音效插件

100% 杜绝"下麦全哑、开麦无声"：阻断房间退出 + 单路拉流防停 + 麦位模型伪装 + 推流心跳保护 + 拉流列表防清空。

## v7.6.0 核心升级 — 阻断房间退出与单路拉流

### 一、v7.6.0 新增（在 v7.5.0 基础上）

| 新增拦截点 | 方法 | 策略 | 解决问题 |
|------------|------|------|----------|
| 引擎退出房间 | `ZegoAudioRoomApi logoutRoom` | 返回 NO 阻止退出 | 被踢时断开所有流连接 |
| 管理器退出房间 | `SKAudioZegoManager leaveRoomWithCompletionBlock:` | 拦截+执行 block 回调 | 管理器层断开房间 |
| 单路拉流停止 | `ZegoAudioRoomApi stopPlayStream:` | 直接 return | 个别流被停播导致听不到对方 |
| 麦位模型伪装 | `SWRoomMicroModel isDownMicCommand` | 返回 NO | 从数据源无视下麦信令 |
| 麦位模型伪装 | `SWRoomMicroModel isOnMicroOperate` | 返回 YES | 业务层认为仍在上麦 |
| 麦位模型伪装 | `SWRoomMicroModel isCurrentUser` | 返回 YES | 当前用户仍被标记有效 |

### 二、完整防掐断拦截链路（v7.6.0 全景）

```
被踢/下麦触发
  │
  ├─ 数据源层
  │   ├─ SWRoomMicroModel.isDownMicCommand → 返回 NO（非下麦指令）
  │   ├─ SWRoomMicroModel.isOnMicroOperate → 返回 YES（仍在上麦）
  │   └─ SWRoomMicroModel.isCurrentUser    → 返回 YES（用户有效）
  │
  ├─ 房间退出层
  │   ├─ ZegoAudioRoomApi.logoutRoom        → 返回 NO（阻止引擎退出）
  │   └─ SKAudioZegoManager.leaveRoomWithCompletionBlock: → 拦截+回调block
  │
  ├─ 推流保护层
  │   ├─ changeRoleToChat:                  → 完全 return（不调 %orig）
  │   ├─ setStartPushTimer: nil             → 拦截（保住心跳）
  │   ├─ stopPublishing                     → 台下开麦时拦截
  │   └─ stopPublish                        → 台下开麦时拦截
  │
  ├─ 拉流保护层
  │   ├─ stopPlayStream:                    → 直接 return（单路不停播）
  │   ├─ removeStreamListAll                → 拒绝清空
  │   ├─ saveStreamListAll:                 → 保存后恢复播放
  │   ├─ muteAllRemote:                     → 强制 NO
  │   ├─ enableSpeaker:                     → 强制 YES
  │   └─ onStreamUpdated:stream:            → 恢复拉流+重新开麦+checkAllStreams
  │
  └─ 保活线程 (0.8s)
      ├─ enableSpeaker:YES                  → 持续锁定扬声器
      ├─ ApplyCrystalDSP                    → 刷新增益+EQ参数
      └─ checkAllStreams                    → 周期性拉流恢复
```

### 三、防掐断拦截对照表（全部 14 项）

| # | 拦截目标 | 方法 | 拦截策略 | 报告章节 | 版本 |
|---|----------|------|----------|----------|------|
| 1 | 麦位下麦指令 | `isDownMicCommand` | 返回 NO | 4.2.2 | v7.6.0 |
| 2 | 麦位上麦状态 | `isOnMicroOperate` | 返回 YES | 4.2.2 | v7.6.0 |
| 3 | 当前用户有效 | `isCurrentUser` | 返回 YES | 4.2.2 | v7.6.0 |
| 4 | 引擎退出房间 | `logoutRoom` | 返回 NO | 3.2.1 | v7.6.0 |
| 5 | 管理器退出房间 | `leaveRoomWithCompletionBlock:` | 拦截+回调 | 8.2 | v7.6.0 |
| 6 | 单路拉流停止 | `stopPlayStream:` | 直接 return | 3.2.1 | v7.6.0 |
| 7 | 角色降级 | `changeRoleToChat:` | 完全 return | 4.2.2 | v7.5.0 |
| 8 | 推流心跳销毁 | `setStartPushTimer:` | nil 时拦截 | 4.2.2 | v7.4.0 |
| 9 | 拉流列表清空 | `removeStreamListAll` | 拒绝清空 | 4.2.2 | v7.4.0 |
| 10 | 拉流列表保存 | `saveStreamListAll:` | 保存后恢复 | 4.2.2 | v7.5.0 |
| 11 | 远端流变动 | `onStreamUpdated:stream:` | 恢复+开麦 | 4.2.2 | v7.4.0 |
| 12 | 远端静音 | `muteAllRemote:` | 强制 NO | 3.2.1 | v7.3.0 |
| 13 | 底层停推 | `stopPublish` | 台下开麦拦截 | 3.2.1 | v7.3.0 |
| 14 | 业务层停推 | `stopPublishing` | 台下开麦拦截 | 8.2 | v7.3.0 |

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

- **阻断房间退出** - logoutRoom + leaveRoomWithCompletionBlock 双拦截
- **单路拉流防停** - stopPlayStream 直接丢弃，保持全量拉流
- **麦位模型伪装** - SWRoomMicroModel 三属性从数据源无视下麦信令
- **终极防掐断** - changeRoleToChat 完全 return + startPushTimer 保护
- **拉流双重保护** - removeStreamListAll 拒绝清空 + saveStreamListAll 恢复
- **周期拉流恢复** - 0.8s 保活线程 checkAllStreams
- **流变动重新开麦** - onStreamUpdated 触发 muteMic:NO
- **ZegoAudioRoomApi 正确类名** - 逆向报告确认的真实引擎类
- **业务层双管台下开麦** - SKAudioZegoManager + ZegoAudioRoomApi 协同推流
- **封顶纯净增益** - 400/600/1000 消除方波失真
- **iOS 13+ 兼容** - UIWindowScene 适配 + 手势去重

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：强制开麦 / 台下直接开麦 / 新清晰 / 旧清晰 / 超级清晰
4. **调试 Tab**：调节各档位音量（100~2000）和人声权重

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics
