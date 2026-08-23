# FightVoicePro v2.7.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.7.0 核心修复

- **constructor 构造函数注入即初始化** - `__attribute__((constructor))` 确保 `InitEmbeddedPCMData()` 在动态库加载的瞬间执行，点开 App 第一秒内存里就有雪花嗡鸣数据，不再依赖进入房间推流才生成
- **强制扬声器外放路由** - 试听时调用 `overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker`，无论插没插耳机，外放扬声器和耳机都会响；解决 VoiceChat 模式下音频路由定向到电话听筒导致外放静音的问题
- **Playback 模式替代 PlayAndRecord** - 试听时切换为 `AVAudioSessionCategoryPlayback` + `MixWithOthers`，避免与 App 原有音频会话冲突
- **三重 PCM 就绪保险** - constructor 构造函数 + SettingManagerView 初始化 + startTestAudio 调用前，三处均调用 `InitEmbeddedPCMData()` 确保数据非零

## v2.6.0 核心修复

- **彻底修复试听闪退** - WAV 内存封装 + AVAudioPlayer 高层容错

## v2.5.0 核心修复

- **内置 PCM 硬编码合成** - 纯内存合成，沙盒零限制

## v2.4.0 核心修复

- **setAudioCaptureShiftOnMix:YES 混音修正** - Aux 三步联动

## v2.3.0 核心修复

- **pthread 线程安全 PCM 管理** - Double-buffering

## 功能特性

- **constructor 即时初始化** - 动态库加载即生成 PCM 数据
- **强制扬声器外放** - overrideOutputAudioPort + Playback 模式
- **内置 PCM 硬编码** - 纯内存合成雪花+嗡鸣
- **WAV 内存封装试听** - 44 字节标准 WAV 头 + AVAudioPlayer
- **ZegoAudioAux 三步联动推流**
- **线程安全动态导入** - pthread_mutex + Double-buffering
- **电视雪花音效** - 白噪声 -14dB + 50Hz 嗡鸣 -12dB + 15625Hz 行频 + 18Hz 撕拉
- **多重强制开麦** - 三层拦截
- **强制永久关闭 3A** - AGC / ANS / AEC 全部禁用
- **全频段 EQ 直通** - 20Hz~20kHz 十段 EQ
- **三档爆音模式** - 500 / 1000 / 1500
- **悬浮控制面板** - 双指双击调出
- **iOS 13+ 兼容**

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **设置 Tab**：点击「开始试听」外放扬声器立即大声循环播放
4. **功能 Tab**：开启/关闭搏击音效
5. **音乐 Tab**：导入 MP3 / 上麦发 / 默认噪音
6. **调试 Tab**：调节各档位音量

## PCM 初始化时序

| 时机 | 函数 | 说明 |
|------|------|------|
| 动态库加载 | `__attribute__((constructor))` | 注入即生成，确保第一秒有数据 |
| 设置页打开 | `initWithFrame:` | 双重保险，打开即确认 |
| 点击试听 | `startTestAudio` | 三重保险，播放前确认 |

## 音频路由修复

| 问题 | 原因 | 修复 |
|------|------|------|
| 试听无声音 | PCM 数组全 0 静音 | constructor 即时初始化 |
| 外放不响 | 路由定向到电话听筒 | overrideOutputAudioPort:Speaker |
| 与 App 冲突 | PlayAndRecord 模式 | 改用 Playback + MixWithOthers |

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
