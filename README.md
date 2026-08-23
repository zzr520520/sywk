# FightVoicePro v7.1.0 - 声控物语搏击音效插件

专用于声控物语的纯净大音量清晰推流 + 业务层台下开麦插件（Tweak）。

## v7.1.0 双重突破 — 纯净清晰 + 业务层台下开麦

### 一、彻底移除背景音效，纯净人声极致清晰

**问题根源**：之前把低频与超低频（31Hz~250Hz）也一同拉满，中低频能量过载引起频谱掩蔽效应（Masking Effect），把中高频咬字与齿音彻底糊住。

**v7.1.0 方案**：

| 改进 | 详情 |
|------|------|
| 移除背景音效 | 彻底移除所有雪花杂音、50Hz嗡鸣、PCM音频注入 |
| 高通切除低频 | 31Hz -12dB / 62Hz -8dB / 250Hz -6dB / 500Hz -10dB |
| 黄金穿透频段 | 1kHz +16dB / 2kHz +22dB / 4kHz +24dB 齿音极致清晰 |
| 释放动态空间 | 低频削减腾出全部动态余量给中高频咬字 |

### 二、业务层台下直接开麦

**问题根源**：App 的上麦推流由 SKAudioZegoManager 与 SKVoiceRoomManager 协同调度，直接调 Zego 的 startPublishing 无法走通业务流程。

**v7.1.0 方案**：直接触发业务层原生上麦接口：

| 业务接口 | 作用 |
|----------|------|
| SKAudioZegoManager.sharedManager | 获取音频管理器单例 |
| enableMic:YES | 强制开启麦克风 |
| startPublish | 触发业务层推流 |
| SKVoiceRoomManager.shareInstance | 获取房间管理器单例 |
| takeSeat:1 | 虚拟绑定1号麦位 |
| reqUserMicroSeat:1 | 请求发言席位 |
| joinMic | 加入麦克风队列 |

### 三、三档清晰模式 EQ 曲线

| 频段 | 新清晰 | 旧清晰 | 超级清晰 |
|------|--------|--------|----------|
| 31Hz | -12dB | -8dB | 0dB |
| 62Hz | -8dB | -4dB | +4dB |
| 125Hz | 0dB | +4dB | +8dB |
| 250Hz | -6dB | -4dB | 0dB |
| 500Hz | -10dB | -6dB | -2dB |
| 1kHz | +16dB | +18dB | +24dB |
| 2kHz | +22dB | +24dB | +24dB |
| 4kHz | +24dB | +24dB | +24dB |
| 8kHz | +16dB | +18dB | +24dB |
| 16kHz | +10dB | +12dB | +20dB |

### 四、增益控制

| 模式 | 增益 |
|------|------|
| 新清晰 | 800 |
| 旧清晰 | 1500 |
| 超级清晰 | 2500 |

## 功能特性

- **纯净人声** - 彻底移除所有背景音效与杂音
- **高通切除** - 31Hz~500Hz 低频浑浊区削减，释放动态空间
- **极限穿透** - 1kHz~4kHz 拉满 +24dB，咬字极致清晰透亮
- **业务层台下开麦** - SKAudioZegoManager + SKVoiceRoomManager 双管齐下
- **强制开麦** - 麦位防静音/防控麦
- **Zego 原生推流** - setCaptureVolume + 10 段 EQ 极限过载
- **0.8s 保活线程** - dispatch_source 高频刷新 DSP 参数
- **三档清晰模式** - 800 / 1500 / 2500 增益
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 适配 + 手势去重

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. **双指双击**屏幕调出悬浮面板
3. **功能 Tab**：
   - 强制开麦：麦位防静音/防控麦
   - 台下直接开麦：观众席通过业务层接口直接推流
   - 新清晰/旧清晰/超级清晰：三档纯净音效
4. **调试 Tab**：调节各档位音量（100~4000）和人声权重

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics
