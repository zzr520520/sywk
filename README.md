# FightVoicePro v7.5.0 - 声控物语搏击音效插件

终极防掐断方案：彻底拦截角色降级 + 推流心跳保护 + 拉流列表防清空 + 周期性拉流恢复，实现被踢/下麦后持续推流与收听。

## v7.5.0 核心升级 — 终极防掐断闭环

### 一、v7.5.0 新增改进（在 v7.4.0 基础上）

| 改进点 | v7.4.0 | v7.5.0 |
|--------|--------|--------|
| `changeRoleToChat:` | `%orig(1)` 仍调原始方法 | **完全 `return`**，不触发任何降级副作用 |
| `saveStreamListAll:` | 未拦截 | **新增 Hook**，保存后立即恢复播放 |
| `onStreamUpdated:` | 恢复拉流 | **增加 `muteMic:NO`**，流变动后重新开麦 |
| 保活线程 | 仅 `enableSpeaker` | **增加周期 `checkAllStreams`**，防止流列表被清空 |

### 二、完整防掐断拦截链路

```
被踢/下麦触发
  ├─ changeRoleToChat:    → 完全return拦截（不调%orig，零副作用）
  ├─ setStartPushTimer:   → timer==nil时拦截（保住推流心跳）
  ├─ removeStreamListAll  → 拒绝清空拉流列表
  ├─ saveStreamListAll:  → 保存后立即恢复播放（新增）
  ├─ muteAllRemote:      → 强制NO
  ├─ enableSpeaker:      → 强制YES
  ├─ stopPublishing      → 台下开麦时拦截
  ├─ stopPublish         → 台下开麦时拦截
  └─ onStreamUpdated:    → 恢复拉流+重新开麦+checkAllStreams

保活线程 (0.8s)
  ├─ enableSpeaker:YES   → 持续锁定扬声器
  ├─ ApplyCrystalDSP     → 刷新增益+EQ参数
  └─ checkAllStreams      → 周期性拉流恢复（新增）
```

### 三、防掐断拦截对照表

| 拦截目标 | 方法 | 拦截策略 | 报告章节 |
|----------|------|----------|----------|
| 角色降级 | `changeRoleToChat:` | 完全return，不调%orig | 4.2.2 |
| 推流心跳销毁 | `setStartPushTimer:` | timer==nil时拦截 | 4.2.2 |
| 拉流列表清空 | `removeStreamListAll` | 强制开麦/台下开麦时拒绝 | 4.2.2 |
| 拉流列表保存 | `saveStreamListAll:` | 保存后立即恢复播放 | 4.2.2 |
| 远端流变动 | `onStreamUpdated:stream:` | 恢复拉流+重新开麦 | 4.2.2 |
| 远端静音 | `muteAllRemote:` | 强制NO | 3.2.1 |
| 扬声器关闭 | `enableSpeaker:` | 强制YES | 3.2.1 |
| 底层停推 | `stopPublish` | 台下开麦时拦截 | 3.2.1 |
| 业务层停推 | `stopPublishing` | 台下开麦时拦截 | 8.2 |

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

- **终极防掐断** - changeRoleToChat 完全return + startPushTimer保护 + removeStreamListAll拦截
- **拉流双重保护** - removeStreamListAll拒绝清空 + saveStreamListAll保存后恢复
- **周期拉流恢复** - 0.8s保活线程增加checkAllStreams
- **流变动重新开麦** - onStreamUpdated触发muteMic:NO
- **ZegoAudioRoomApi 正确类名** - 逆向报告确认的真实引擎类
- **业务层双管台下开麦** - SKAudioZegoManager + ZegoAudioRoomApi 协同推流
- **stopPublish/stopPublishing 双拦截** - 台下开麦时防止 App 终止推流
- **封顶纯净增益** - 400/600/1000 消除方波失真
- **纯净人声** - 彻底移除所有背景音效
- **高通切除** - 31Hz~500Hz 削减，释放动态空间
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
