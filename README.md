# FightVoicePro v7.2.0 - 声控物语搏击音效插件

基于逆向工程报告，修复底层类名不匹配问题，实现真正可用的台下开麦与纯净洪亮推流。

## v7.2.0 核心突破 — 逆向修复 + 封顶纯净增益

### 一、台下开麦失败的根因修复

| 问题 | v7.1 错误 | v7.2 修复 |
|------|-----------|-----------|
| 引擎类名 | ZegoLiveRoomApi | **ZegoAudioRoomApi** |
| 引擎捕获 | hook init | hook **setupENgine** + zegoEngine 属性 |
| 推流方法 | startPublishing:title:flag: | **startPublish** / **startPublishWithStreamID:** |
| 业务管理器 | NSClassFromString 动态查找 | 直接 Hook **SKAudioZegoManager** |
| 静音方法 | enableMic: | **muteMic:** |
| 停止推流 | stopPublishing | **stopPublish** |

### 二、封顶纯净增益（消除方波失真）

之前 800/1500/2500 过高导致方波削波失真。v7.2 降至封顶值：

| 模式 | v7.1 增益 | v7.2 增益 |
|------|----------|----------|
| 新清晰 | 800 | **400** |
| 旧清晰 | 1500 | **600** |
| 超级清晰 | 2500 | **1000** |

### 三、纯净人声 EQ 曲线

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

### 四、业务层台下开麦流程

```
开关 ON
  ├─ SKAudioZegoManager.muteMic:NO     → 解除静音
  ├─ SKAudioZegoManager.startPublishing → 触发业务层推流
  ├─ ZegoAudioRoomApi.enableMic:YES    → 引擎开麦
  └─ ZegoAudioRoomApi.startPublish      → 引擎直接推流

开关 OFF
  ├─ SKAudioZegoManager.stopPublishing  → 停止业务推流
  └─ ZegoAudioRoomApi.stopPublish      → 停止引擎推流

stopPublish 拦截
  └─ 台下开麦开启时，拦截 App 的下麦停止指令
```

## 功能特性

- **ZegoAudioRoomApi 正确类名** - 逆向报告确认的真实引擎类
- **zegoEngine 属性捕获** - 通过 setupENgine 钩子获取底层引擎实例
- **业务层双管台下开麦** - SKAudioZegoManager + ZegoAudioRoomApi 协同推流
- **stopPublish 拦截** - 防止 App 终止台下幽灵推流
- **封顶纯净增益** - 400/600/1000 消除方波失真
- **纯净人声** - 彻底移除所有背景音效
- **高通切除** - 31Hz~500Hz 削减，释放动态空间
- **极限穿透** - 1kHz~4kHz +24dB 齿音极致清晰
- **0.8s 保活线程** - 高频刷新 DSP 参数
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
