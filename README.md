# FightVoicePro v2.8.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.8.0 核心重构

- **CoreAudio 底层 Hook** - 使用 `MSHookFunction` 拦截系统底层 `AudioUnitRender` C 函数，在硬件渲染层直接修改 PCM 内存，将麦克风录音数据与雪花嗡鸣强制混合并过载放大后推向远端。所有 iOS 音频框架（ZEGO / WebRTC / AVFoundation）最终都必须调用 `AudioUnitRender`，因此无论 App/SDK 如何配置，对方 100% 必定收到混音
- **Pull 代理双保险** - 保留 `ZegoAudioAuxProvider` 标准 Pull 模式代理作为 SDK 层补充，与底层 CoreAudio Hook 形成双重保障
- **彻底清除 GCD 定时器** - 移除 `g_auxPushTimer` 和 `StartAuxDataInjector()`，消除死锁隐患与推流时序问题
- **增益乘法器** - CoreAudio Hook 内根据战斗模式动态应用增益乘法器（1.0x / 1.6x / 2.4x），直接在 PCM 数据写入时放大
- **硬削顶防溢出** - 混音后 float 值钳位至 [-32768, 32767]，防止 int16 溢出爆裂
- **constructor 即时安装** - 动态库加载瞬间执行 `InitEmbeddedPCMData()` + `MSHookFunction(AudioUnitRender, ...)`

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

| 方案 | v2.3~v2.7 (Push) | v2.8.0 (CoreAudio Hook + Pull) |
|------|-------------------|---------------|
| 数据流方向 | 主动推送 → SDK | 底层拦截 AudioUnitRender |
| 拦截层级 | SDK 代理层 | 硬件 CoreAudio 层 |
| 生效条件 | App 开启 ZegoAudioObserver | 无条件生效 |
| 丢帧风险 | 可能丢帧/卡顿 | 零丢帧 |
| 死锁隐患 | 存在 | 已消除 |
| API | `setAudioAuxData:` | `MSHookFunction(AudioUnitRender)` |
| 增益方式 | `setCaptureVolume:` | PCM 数据内乘法器 + 硬削顶 |
| SDK 依赖 | 强依赖 Zego SDK | 绕过所有 SDK 限制 |

## 功能特性

- **CoreAudio 底层 Hook** - `MSHookFunction` 拦截 `AudioUnitRender`，硬件级混音
- **Pull 代理双保险** - `ZegoAudioAuxProvider` 标准 Pull 代理作为 SDK 层补充
- **constructor 即时初始化** - 动态库加载即生成 PCM 数据 + 安装 Hook
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

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia / AudioToolbox / CoreAudio
