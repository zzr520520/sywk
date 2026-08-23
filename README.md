# FightVoicePro v2.8.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.8.0 核心重构

- **Pull 模式代理注入** - 实现标准 `ZegoAudioAuxProvider` 单例代理，挂载至 `setAudioAuxDelegate:`；引擎每隔 20ms 向代理请求一次数据（`onAudioAuxData:dataLen:sampleRate:channelCount:`），代理直接将内存 PCM 拷贝至 SDK 提供的目标缓冲区，由 SDK 负责与麦克风通道混流并推向远端，完全不丢帧、不卡顿
- **彻底清除 GCD 定时器** - 移除 `g_auxPushTimer` 和 `StartAuxDataInjector()`，消除死锁隐患与推流时序问题
- **增益乘法器** - Pull 代理内根据战斗模式动态应用增益乘法器（1.0x / 1.6x / 2.4x），直接在 PCM 数据拷贝时放大
- **双签名兼容** - `onAudioAuxData:` 标准签名 + `channelIndex:` 扩展签名，覆盖不同 SDK 版本

## v2.7.0 核心修复

- **constructor 构造函数注入即初始化** - PCM 数据在动态库加载瞬间生成
- **强制扬声器外放路由** - `overrideOutputAudioPort:Speaker`

## v2.6.0 核心修复

- **彻底修复试听闪退** - WAV 内存封装 + AVAudioPlayer 高层容错

## v2.5.0 核心修复

- **内置 PCM 硬编码合成** - 纯内存合成，沙盒零限制

## v2.4.0 核心修复

- **setAudioCaptureShiftOnMix:YES 混音修正** - Aux 三步联动

## v2.3.0 核心修复

- **pthread 线程安全 PCM 管理** - Double-buffering

## 推流架构对比

| 方案 | v2.3~v2.7 (Push) | v2.8.0 (Pull) |
|------|-------------------|---------------|
| 数据流方向 | 主动推送 → SDK | SDK 索取 → 代理供流 |
| 时序控制 | GCD 定时器 20ms | 引擎时钟精确对齐 |
| 丢帧风险 | 可能丢帧/卡顿 | 零丢帧 |
| 死锁隐患 | 存在 | 已消除 |
| API | `setAudioAuxData:` | `setAudioAuxDelegate:` + `onAudioAuxData:` |
| 增益方式 | `setCaptureVolume:` | PCM 数据内乘法器 |

## 功能特性

- **Pull 模式代理** - `ZegoAudioAuxProvider` 标准代理注入，引擎时钟对齐
- **constructor 即时初始化** - 动态库加载即生成 PCM 数据
- **强制扬声器外放** - overrideOutputAudioPort + Playback 模式
- **内置 PCM 硬编码** - 纯内存合成雪花+嗡鸣
- **WAV 内存封装试听** - 44 字节标准 WAV 头 + AVAudioPlayer
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
3. **设置 Tab**：点击「开始试听」外放扬声器立即播放
4. **功能 Tab**：开启/关闭搏击音效（Pull 代理自动注册）
5. **音乐 Tab**：导入 MP3 / 上麦发 / 默认噪音
6. **调试 Tab**：调节各档位音量

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
