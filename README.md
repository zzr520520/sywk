# FightVoicePro v2.6.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.6.0 核心修复

- **彻底修复试听闪退** - AVAudioEngine 在 `PlayAndRecord` 模式下 `connect:to:format:` 因格式不匹配触发 AURemoteIO C++ 异常断言导致 App 瞬间崩溃；改用 `WrapPCMToWavData()` 在内存中将 PCM 裸数据封装 44 字节标准 WAV 头，交由高层 `AVAudioPlayer` 播放，自带格式容错，100% 不崩溃
- **WAV 内存封装** - `WrapPCMToWavData()` 函数：RIFF/WAVE/fmt /data 完整 WAV 容器结构，在内存中直接装配 NSData，无需文件 I/O
- **AVAudioPlayer 安全模式** - `g_safeTestPlayer` 替代 `AVAudioEngine`/`AVAudioPlayerNode`，`numberOfLoops=-1` 循环试听，`MixWithOthers` 避免打断 App 原有音频

## v2.5.0 核心修复

- **内置 PCM 硬编码合成** - `InitEmbeddedPCMData()` 用 C 代码合成 44100 samples 雪花+嗡鸣到静态数组，不依赖外部文件
- **沙盒零限制** - 彻底解决 iOS 沙盒限制导致外部路径无法读取

## v2.4.0 核心修复

- **setAudioCaptureShiftOnMix:YES 混音修正** - Aux 三步联动

## v2.3.0 核心修复

- **pthread 线程安全 PCM 管理** - Double-buffering 原子指针置换

## 功能特性

- **内置 PCM 硬编码** - 纯内存合成雪花+嗡鸣，沙盒零限制
- **WAV 内存封装试听** - 44 字节标准 WAV 头 + PCM 裸数据，AVAudioPlayer 高层容错
- **ZegoAudioAux 三步联动推流** - `enableAux:` + `setAudioCaptureShiftOnMix:` + `setAudioAuxData:`
- **线程安全动态导入** - pthread_mutex + Double-buffering
- **电视雪花音效** - 白噪声 -14dB + 50Hz 嗡鸣 -12dB + 15625Hz 行频 + 18Hz 撕拉切音
- **多重强制开麦** - 三层拦截
- **强制永久关闭 3A** - AGC / ANS / AEC 全部禁用
- **全频段 EQ 直通** - 20Hz~20kHz 十段 EQ，4kHz +15dB
- **三档爆音模式** - 500 / 1000 / 1500
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 获取 keyWindow

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：开启/关闭搏击音效
4. **音乐 Tab**：导入 MP3 / 上麦发 / 默认噪音
5. **调试 Tab**：调节各档位音量、人声权重
6. **设置 Tab**：点击「开始试听」从内存 WAV 安全播放验证效果

## WAV 内存封装结构

| 偏移 | 字段 | 大小 | 值 |
|------|------|------|-----|
| 0 | ChunkID | 4 | "RIFF" |
| 4 | ChunkSize | 4 | 36 + dataSize |
| 8 | Format | 4 | "WAVE" |
| 12 | Subchunk1ID | 4 | "fmt " |
| 16 | Subchunk1Size | 4 | 16 |
| 20 | AudioFormat | 2 | 1 (PCM) |
| 22 | NumChannels | 2 | 1 (Mono) |
| 24 | SampleRate | 4 | 44100 |
| 28 | ByteRate | 4 | 88200 |
| 32 | BlockAlign | 2 | 2 |
| 34 | BitsPerSample | 2 | 16 |
| 36 | Subchunk2ID | 4 | "data" |
| 40 | Subchunk2Size | 4 | dataSize |
| 44 | Data | N | PCM 裸数据 |

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
