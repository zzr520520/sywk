# FightVoicePro v2.9.0 - 声控物语搏击音效插件

专用于声控物语的 CoreAudio 底层双Hook 与老式电视无信号雪花音效插件（Tweak）。

## v2.9.0 终极修复 — 三轨合一强制混入

- **致命死穴定位** - 修复"本地测试响、一进房间对方全聋"的终极底层 Bug：
  1. **AudioUnitRender Bus 陷阱** - Bus 0 是输出（扬声器），Bus 1 才是输入（麦克风录音）。之前 Hook 未精准区分，混音写进了播放流而非录音流
  2. **ZEGO AudioConverter 旁路** - 现代 ZEGO SDK 采集麦克风后走 `AudioConverterFillComplexBuffer` 做格式转换，AudioUnitRender 里写入的数据会被格式转换器直接冲掉
- **双层 Hook 三轨合一** - `AudioUnitRender`（硬件录音渲染层）+ `AudioConverterFillComplexBuffer`（系统格式转换层）双 Hook 同时注入，确保 Opus/AAC 编码前 PCM 必带雪花嗡鸣
- **MixNoiseIntoAudioBuffer 统一混音算法** - 抽取为 `static inline` 函数，双层 Hook 复用同一套增益/削顶逻辑，代码更精简
- **全 Bus 拦截** - 不区分 Bus 0 / Bus 1，对所有 AudioBufferList 输出缓冲统一注入，彻底覆盖播放/录音两条路径
- **移除 Zego SDK 层依赖** - 去掉 `ZegoAudioAuxProvider` Pull 代理、`ApplyPreciseRadioFightDSP`、`StartKeepAliveService`、`g_activeZegoApi`、`g_keepAliveTimer` 等 SDK 相关代码，完全依赖 CoreAudio 底层 Hook，架构更精简
- **强制关死 3A** - Hook `enableAGC:` / `enableNoiseSuppress:` / `enableAEC:`，战斗模式下全部返回 NO，防止雪花音被当做噪音消除

## v2.8.0 核心重构

- **CoreAudio 底层 Hook** - 使用 `MSHookFunction` 拦截系统底层 `AudioUnitRender` C 函数，硬件级 PCM 混音
- **Pull 代理双保险** - `ZegoAudioAuxProvider` 标准 Pull 模式代理作为 SDK 层补充

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

| 方案 | v2.3~v2.7 (Push) | v2.8.0 (单层Hook) | v2.9.0 (双层Hook) |
|------|-------------------|-------------------|-------------------|
| 拦截层级 | SDK 代理层 | 硬件 CoreAudio 层 | 硬件层 + 格式转换层 |
| Hook 点 | `setAudioAuxData:` | `AudioUnitRender` | `AudioUnitRender` + `AudioConverterFillComplexBuffer` |
| 生效条件 | App 开启 ZegoAudioObserver | 部分生效(可能被旁路) | 100% 必生效 |
| SDK 旁路风险 | 低 | 高(AudioConverter 冲掉) | 已消除 |
| 丢帧风险 | 可能丢帧/卡顿 | 零丢帧 | 零丢帧 |
| SDK 依赖 | 强依赖 Zego SDK | 绕过 SDK | 彻底绕过所有 SDK |
| 架构复杂度 | 高(GCD定时器+代理) | 中 | 精简(纯C函数Hook) |

## 功能特性

- **双层 CoreAudio Hook** - `AudioUnitRender` + `AudioConverterFillComplexBuffer`，三轨合一强制混音
- **MixNoiseIntoAudioBuffer** - 统一 inline 混音算法，硬削顶防溢出
- **constructor 即时初始化** - 动态库加载即生成 PCM 数据 + 安装双 Hook
- **强制扬声器外放** - overrideOutputAudioPort + Playback 模式
- **内置 PCM 硬编码** - 纯内存合成雪花+嗡鸣
- **WAV 内存封装试听** - 44 字节标准 WAV 头 + AVAudioPlayer
- **线程安全动态导入** - pthread_mutex + Double-buffering
- **电视雪花音效** - 白噪声 -14dB + 50Hz 嗡鸣 -12dB + 15625Hz 行频 + 18Hz 撕拉
- **多重强制开麦** - 三层拦截（SKAudioZegoManager + SKMicrophonePermissionManager + ZegoLiveRoomApi）
- **强制永久关闭 3A** - AGC / ANS / AEC 全部禁用
- **三档爆音模式** - 500 / 1000 / 1500
- **悬浮控制面板** - 双指双击调出
- **iOS 13+ 兼容**

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **设置 Tab**：点击「开始试听」外放扬声器立即播放
4. **功能 Tab**：开启/关闭搏击音效（CoreAudio 双层 Hook 自动生效）
5. **音乐 Tab**：导入 MP3 / 上麦发 / 默认噪音
6. **调试 Tab**：调节各档位音量

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia / AudioToolbox / CoreAudio
