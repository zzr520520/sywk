# FightVoicePro v6.0.0 - 声控物语搏击音效插件

专用于声控物语的单通道优化 + 满位强开麦 + Zego 原生推流搏击音效插件（Tweak）。

## v6.0.0 双重突破 — 单通道清晰度优化 + 满位强开麦

### 一、单通道 App 清晰度优化

语音房 App 推流走 Mono 单声道纯人声模式（VoiceChat Mode），SDK 内部动态削波器在所有频段拉满 +24dB 时会把声音压成一团浑浊的"烂泥"。

v6.0.0 的 EQ 曲线针对单通道特性做了物理调校：

| 频段 | 增益 | 作用 |
|------|------|------|
| 250Hz | -6dB ~ 0dB | 严重削减，去除发闷 |
| 500Hz | -12dB ~ -4dB | 极限削减，去除浑浊空腔 |
| 1kHz | +15dB ~ +24dB | 人声基音增强 |
| 2kHz | +22dB ~ +24dB | 极速电台穿透 |
| 4kHz | +24dB | 齿音极度清晰 |

### 二、满位强开麦（幽灵推流）

独立开关 `kGhostMicMode`，与基础强制开麦完全解耦：

- **SKVoiceRoomManager** - `isMicFull -> NO`，`canSpeakWithoutSeat -> YES`
- **SKAudioRoomMicroSetting** - `isMute -> NO`，`isUserOnMic: -> YES`
- **loginRoom 截获** - 记录 RoomID 用于构造幽灵推流 streamID
- **ProcessGhostMicPublish** - 自动调用 `startPublishing:title:flag:` 发起独立推流

### 三、增益提升

| 模式 | v5.0 增益 | v6.0 增益 |
|------|----------|----------|
| 新清晰 | 500 | 800 |
| 旧清晰 | 1000 | 1500 |
| 超级战斗 | 1500 | 2500 |

## 功能特性

- **单通道 EQ 优化** - 削减 250-500Hz 浑浊区，拉满 1-4kHz 穿透区
- **满位强开麦** - 独立幽灵推流，绕过麦位限制
- **Zego 原生上行推流** - setCaptureVolume + 10 段 EQ 极限过载
- **伴奏混音推流** - initWithPlayerType:0 + setProcessType:0 + setAudioStreamType:2
- **内置雪花+50Hz嗡鸣** - PCM 硬编码 + WAV 沙盒固化 + constructor 即时初始化
- **0.8s 保活守护线程** - dispatch_source 高频刷新 DSP 参数
- **三档爆音模式** - 800 / 1500 / 2500 增益
- **本地试听测试** - AVAudioPlayer + 强制扬声器外放
- **stopPublishing 同步停止** - 防止效果播放器残留
- **悬浮控制面板** - 双指双击调出，可拖拽，6 开关自适应滚动
- **iOS 13+ 兼容** - UIWindowScene 适配

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：
   - 强制开麦：基础麦克风锁定
   - 满位强开麦：8人满麦时绕过限制直接推流
   - 新清晰/旧清晰/超级战斗：三档搏击音效
4. **调试 Tab**：调节各档位音量（100~4000）和人声权重
5. **音乐 Tab**：导入 MP3/WAV/M4A → 点击「上麦发」推流
6. **设置 Tab**：本地试听内置雪花音效 + 查看版本信息

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
