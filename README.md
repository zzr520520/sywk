# FightVoicePro v7.3.0 - 声控物语搏击音效插件

修复被踢下麦后"全哑"问题，实现被踢后仍能正常收听房间所有人声音 + 台下直接开麦推流。

## v7.3.0 核心突破 — 防被踢全哑 + 拉流保活

### 一、被踢下麦全哑问题根因

根据逆向报告 5.2.2、7.3、9.1.1 节分析：

| 根因 | 详情 |
|------|------|
| 下麦级联静音 | 被踢时 App 调用 muteAllRemote:YES + removeStreamListAll |
| 服务端鉴权 | 服务端标记 UID 非麦位状态，其他人 stopPlayStream 你的流 |
| 拉流引擎注销 | 被踢后甚至注销拉流引擎，导致你完全听不到任何声音 |

### 二、防全哑修复方案

| 修复点 | 实现 |
|--------|------|
| 拦截 muteAllRemote: | 强制传参 NO，被踢后远端声音不静音 |
| 拦截 enableSpeaker: | 强制传参 YES，扬声器始终开启 |
| stopPublishing 后恢复 | 调用 muteAllRemote:NO + checkAllStreams 重新拉起拉流 |
| 保活线程锁定 | 0.8s 持续调用 enableSpeaker:YES |
| 台下开麦联动 | TriggerOffSeatSpeak 同时执行 muteAllRemote:NO + enableSpeaker:YES + checkAllStreams |

### 三、防全哑拦截链路

```
被踢下麦触发
  ├─ muteAllRemote:YES  → 拦截为 muteAllRemote:NO (远端不静音)
  ├─ enableSpeaker:NO   → 拦截为 enableSpeaker:YES (扬声器不关)
  ├─ stopPublishing     → 台下开麦时拦截 / 否则执行后恢复拉流
  ├─ stopPublish        → 台下开麦时拦截
  └─ checkAllStreams    → 重新绑定 allStreamList 拉流列表

保活线程 (0.8s)
  └─ enableSpeaker:YES  → 持续锁定扬声器开启
```

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

- **防被踢全哑** - 拦截 muteAllRemote + enableSpeaker 强制锁定
- **拉流保活恢复** - stopPublishing 后自动 checkAllStreams 重新拉流
- **ZegoAudioRoomApi 正确类名** - 逆向报告确认的真实引擎类
- **业务层双管台下开麦** - SKAudioZegoManager + ZegoAudioRoomApi 协同推流
- **stopPublish/stopPublishing 双拦截** - 台下开麦时防止 App 终止推流
- **封顶纯净增益** - 400/600/1000 消除方波失真
- **纯净人声** - 彻底移除所有背景音效
- **高通切除** - 31Hz~500Hz 削减，释放动态空间
- **0.8s 保活线程** - enableSpeaker 持续锁定 + DSP 参数刷新
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
