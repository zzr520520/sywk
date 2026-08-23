# FightVoicePro v3.0.0 - 声控物语搏击音效插件

专用于声控物语的 AudioUnitSetProperty 输入回调包装 Hook 与老式电视无信号雪花音效插件（Tweak）。

## v3.0.0 终极架构重构 — 输入回调包装 Hook

### 致命死穴定位

v2.9.0 的 `AudioUnitRender` / `AudioConverterFillComplexBuffer` 双层 Hook 仍然无法让对方听到声音，根本原因：

1. **底层采集通道拦截脱节** - 在 iOS 14+ 及现代 WebRTC/Zego SDK 中，麦克风采集不再是简单的单次 `AudioUnitRender` 提取，而是通过 `AudioUnitSetProperty` 注册了 **kAudioOutputUnitProperty_SetInputCallback (InputProc 回调)**。SDK 直接在系统硬件输入中断回调中把 PCM 数据抓走并送入内部队列，Hook `AudioUnitRender` 根本拦截不到输入流
2. **AudioConverter 也会被旁路** - 现代 SDK 在回调中直接拿走 PCM，不一定经过 `AudioConverterFillComplexBuffer`

### 终极修复：输入回调包装（Wrapper Callback）

- **Hook `AudioUnitSetProperty`** - 在 constructor 中用 `MSHookFunction` 拦截系统底层 `AudioUnitSetProperty` C 函数
- **拦截注册瞬间** - 当 SDK 调用 `AudioUnitSetProperty` 注册 `kAudioOutputUnitProperty_SetInputCallback` 时，保存 SDK 原始回调 `inputProc` 和 `inputProcRefCon`
- **替换为包装回调** - 用 `MyMicrophoneInputCallback` 替换 SDK 的原始回调，SDK 完全无感知
- **硬件中断级混音** - 系统每次硬件中断都会调用我们的包装回调：
  1. 先调用 SDK 原始回调，让 SDK 从硬件麦克风抓取真实人声
  2. 再调用 `MixNoiseIntoAudioBuffer` 强行注入雪花嗡鸣/MP3
  3. SDK 编码上传的数据已被篡改，对方 100% 必定收到

### 与历史版本架构对比

| 版本 | Hook 点 | 拦截层级 | 效果 |
|------|---------|----------|------|
| v2.3~v2.7 | `setAudioAuxData:` | SDK 代理层 | 对方听不到 |
| v2.8.0 | `AudioUnitRender` | 硬件渲染层 | 被SDK输入回调旁路 |
| v2.9.0 | `AudioUnitRender` + `AudioConverterFillComplexBuffer` | 双层 | 仍被SDK输入回调旁路 |
| **v3.0.0** | **`AudioUnitSetProperty`** | **回调注册层** | **100% 必生效** |

## 功能特性

- **输入回调包装 Hook** - `AudioUnitSetProperty` + `MyMicrophoneInputCallback`，在硬件中断回调中直接篡改 PCM
- **MixNoiseIntoAudioBuffer** - 统一 inline 混音算法，硬削顶防溢出
- **constructor 即时初始化** - 动态库加载即生成 PCM 数据 + 安装 Hook
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
4. **功能 Tab**：开启/关闭搏击音效（输入回调包装 Hook 自动生效）
5. **音乐 Tab**：导入 MP3 / 上麦发 / 默认噪音
6. **调试 Tab**：调节各档位音量

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia / AudioToolbox / CoreAudio
