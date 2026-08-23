# FightVoicePro v5.0.0 - 声控物语搏击音效插件

专用于声控物语的 Zego 原生推流 + 伴奏混音双轨注入搏击音效插件（Tweak）。

## v5.0.0 终极闭环 — 伴奏推流通道硬绑定

### 核心问题定位

v4.0.0 的 `ZegoMediaPlayer` 用 `[[cls alloc] init]` 创建播放器，但没有传入 `playerType:0`（伴奏混音类型）或关联主推流通道。SDK 内部将其当成了独立的本地播放器，声音根本没有打包进 WebRTC/Opus 的音频帧。

### v5.0.0 修复方案

1. **initWithPlayerType:0** — 显式创建伴奏混音播放器，关联主推流通道
2. **setProcessType:0** — 设置伴奏推流混音模式
3. **setAudioStreamType:2** — 混入上行推流 + 本地监听
4. **内置雪花+50Hz嗡鸣 WAV 沙盒固化** — App 启动时自动将 PCM 数据封装为标准 WAV 写入 Documents/FightEffects/
5. **constructor 即时初始化** — 动态库加载即生成 PCM + 写入 WAV 文件
6. **stopPublishing hook** — 停止推流时同步停止效果播放器

### 与历史版本对比

| 版本 | 方案 | 问题 |
|------|------|------|
| v4.0.0 | ZegoMediaPlayer [[alloc] init] | 未关联推流通道，声音不进推流帧 |
| **v5.0.0** | **initWithPlayerType:0 + setProcessType:0** | **伴奏混音硬绑定推流通道** |

### 双轨推流架构

```
┌─ 麦克风轨 ─────────────────────────────┐
│ setCaptureVolume: 500/1000/1500        │
│ 10段EQ 极限过载 (+24dB)                │
│ 彻底关闭 3A (AGC/ANS/AEC)              │
│ → ZegoLiveRoomApi 上行推流编码器       │
└──────────────────────────────────────── ┘

┌─ 伴奏效果轨 ───────────────────────────┐
│ ZegoMediaPlayer initWithPlayerType:0   │
│ setProcessType:0 (伴奏推流混音)        │
│ setAudioStreamType:2 (推流+本地)       │
│ setLoopCount:-1 (循环)                 │
│ setPublishVolume:75/100                │
│ → 内置雪花+50Hz嗡鸣 WAV 混入推流       │
└──────────────────────────────────────── ┘
```

## 功能特性

- **Zego 原生上行推流** - setCaptureVolume + 10 段 EQ 极限过载
- **伴奏混音推流** - initWithPlayerType:0 + setProcessType:0 + setAudioStreamType:2
- **内置雪花+50Hz嗡鸣** - PCM 硬编码 + WAV 沙盒固化 + constructor 即时初始化
- **0.8s 保活守护线程** - dispatch_source 高频刷新 DSP 参数
- **三档爆音模式** - 500 / 1000 / 1500 增益
- **本地试听测试** - AVAudioPlayer + 强制扬声器外放
- **多重强制开麦** - 三层拦截
- **强制永久关闭 3A** - AGC / ANS / AEC / TransientNoiseSuppress
- **stopPublishing 同步停止** - 防止效果播放器残留
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 适配
- **手势冲突防护** - shouldReceiveTouch 去重 + 手势去重

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：开启/关闭搏击音效模式（新清晰/旧清晰/超级战斗）
4. **调试 Tab**：调节各档位音量（100~3000）和人声权重
5. **音乐 Tab**：导入 MP3/WAV/M4A → 点击「上麦发」推流
6. **设置 Tab**：本地试听内置雪花音效 + 查看推流状态

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
