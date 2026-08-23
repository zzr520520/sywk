# FightVoicePro v4.0.0 - 声控物语搏击音效插件

专用于声控物语的 Zego 原生上行推流注入搏击音效插件（Tweak）。

## v4.0.0 架构回归 — Zego 原生上行推流

### 回溯分析：为什么第二、三版能生效

第二、三版直接作用于 **ZegoLiveRoomApi 的上行推流管线**，通过：
1. `setCaptureVolume:` 设置 500/1000/1500 极限增益
2. 10 段 EQ 全频段过载增益（最高 +24dB）
3. 彻底关闭 3A（AEC/AGC/ANS），防止声音被系统压制

这种做法直接指挥 ZEGO 引擎对采集到的所有音频进行硬件放大和全频段爆音编码，再打包发给房间所有人。

### 为什么 v2.8~v3.0 的底层 C Hook 失败

v2.8~v3.0 改去 Hook `AudioUnitRender`、`AudioUnitSetProperty` 和 `AudioConverterFillComplexBuffer`，这些底层操作只影响了本地播放管道或者没有握手成功，导致上层 SDK 的推流增益完全失效——**对方全聋，只有自己能听到**。

### v4.0.0 终极方案

彻底剔除所有不可靠的底层 C Hook，**全面回归第二版/第三版最稳定的 Zego 原生推流注入链路**：

| 版本 | 方案 | 效果 |
|------|------|------|
| v2.3~v2.7 | setAudioAuxData + PCM 混音 | 部分生效 |
| v2.8~v2.9 | AudioUnitRender + AudioConverter Hook | 被SDK旁路，对方听不到 |
| v3.0 | AudioUnitSetProperty 回调包装 | 底层操作不可靠 |
| **v4.0.0** | **Zego 原生推流 API** | **对方 100% 必收到** |

### 核心技术实现

1. **直接对接 ZEGO 上行推流核心**：不再走任何有风险的底层 C Hook，而是直接控制 `ZegoLiveRoomApi` 的推流通道参数，推流编码器将直接把经过增益与 EQ 塑形的音频流发送到服务端

2. **0.8 秒高频保活线程**：无论 App 内部在上麦后如何重置麦克风参数，定时器会在毫秒级重新压入 500/1000/1500 增益 + 关闭 3A + 10 段过载 EQ，保证全房间收到的声音始终处于过载状态

3. **三档搏击模式**：
   - 新清晰搏击：500 音量 + 清晰咬字 EQ 曲线
   - 旧清晰搏击：1000 音量 + 电台撕拉 EQ 曲线
   - 超级战斗：1500 音量 + 全频段 +24dB 极限过载轰炸

4. **ZegoMediaPlayer 音乐推流**：使用 `setAudioStreamType:2` 混入上行推流 + 本地监听，标准 SDK 接口确保音乐也能被全房间听到

5. **彻底关闭 3A**：AGC / ANS / AEC + TransientNoiseSuppress 全部禁用，防止系统压制声音

## 功能特性

- **Zego 原生上行推流** - setCaptureVolume + 10 段 EQ 极限过载
- **0.8s 保活守护线程** - dispatch_source 高频刷新 DSP 参数
- **三档爆音模式** - 500 / 1000 / 1500 增益
- **ZegoMediaPlayer 音乐推流** - setAudioStreamType:2 混入推流
- **多重强制开麦** - 三层拦截（SKAudioZegoManager + SKMicrophonePermissionManager + ZegoLiveRoomApi）
- **强制永久关闭 3A** - AGC / ANS / AEC / TransientNoiseSuppress 全部禁用
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 适配
- **手势冲突防护** - shouldReceiveTouch 去重

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：开启/关闭搏击音效模式（新清晰/旧清晰/超级战斗）
4. **调试 Tab**：调节各档位音量（100~3000）和人声权重
5. **音乐 Tab**：导入 MP3/WAV/M4A → 点击「上麦发」推流
6. **设置 Tab**：查看音频推流状态监控

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics
