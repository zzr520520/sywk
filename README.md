# FightVoicePro v2.5.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.5.0 核心修复

- **内置 PCM 硬编码合成** - 彻底解决 iOS 沙盒限制导致外部文件无法读取的问题；`InitEmbeddedPCMData()` 在启动时直接用 C 代码合成 1 秒（44100 samples）电视雪花+50Hz 强嗡鸣 PCM 数据到静态数组 `g_embeddedPcmBuffer`，编译进 .dylib 内部，不依赖任何外部文件
- **沙盒零限制** - 不再读取 `/Library/Application Support/...` 固定路径，开机即可播放，本地试听和推流 100% 稳定运行
- **AVAudioEngine 本地试听** - 设置页「开始试听」改用 `AVAudioEngine` + `AVAudioPlayerNode` 从内存 PCM 缓冲区直接播放，无需文件 I/O
- **双层 PCM 架构** - `g_embeddedPcmBuffer`（内置静态数组）+ `g_customPcmBuffer`（动态导入 MP3），优先播放导入音乐，无导入时自动回退至内置雪花

## v2.4.0 核心修复

- **setAudioCaptureShiftOnMix:YES 混音修正** - 确保 Aux 数据不被 SDK 丢弃，直接混入上行推流通道
- **Aux 三步联动** - `enableAux:YES` → `setAudioCaptureShiftOnMix:YES` → `setAudioAuxData:` 完整链路

## v2.3.0 核心修复

- **pthread 线程安全 PCM 管理** - Double-buffering 原子指针置换
- **推流时机修正** - `startPublishing` 后激活 Aux 注入
- **前置函数声明** - 消除隐式声明编译错误
- **合并 UIWindow Hook** - 修复 Logos 重复 hook 硬伤

## 功能特性

- **内置 PCM 硬编码** - 纯内存合成雪花+嗡鸣，沙盒零限制，开机即可播放
- **ZegoAudioAux 三步联动推流** - `enableAux:` + `setAudioCaptureShiftOnMix:` + `setAudioAuxData:`
- **AVAudioEngine 本地试听** - 从内存 PCM 直接播放，无需文件 I/O
- **线程安全动态导入** - pthread_mutex + Double-buffering 保护 MP3 解码
- **电视雪花音效** - 白噪声 -14dB + 50Hz 嗡鸣 -12dB + 15625Hz 行频 + 18Hz 撕拉切音
- **多重强制开麦** - ZegoLiveRoomApi / SKAudioZegoManager / SKMicrophonePermissionManager 三层拦截
- **强制永久关闭 3A** - AGC / ANS / Noise Gate / AEC 全部禁用
- **全频段 EQ 直通** - 20Hz~20kHz 十段 EQ，4kHz 高频啸叫 +15dB
- **三档爆音模式** - 新清晰搏击(500) / 旧清晰搏击(1000) / 超级战斗(1500)
- **0.8s 保活定时器** - 高优先级队列刷新 DSP 参数
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 获取 keyWindow

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. 启动 App 后，**双指双击**屏幕调出悬浮面板
3. 点击开关开启/关闭搏击音效
4. **音乐 Tab**：点击「上麦发」解码 MP3 至 PCM 并注入推流；点击「默认噪音」恢复内置雪花嗡鸣
5. **调试 Tab**：独立调节各档位音量、人声权重
6. **设置 Tab**：点击「开始试听」从内存直接播放当前音频验证效果；查看版本与 DSP 参数

## 内置 PCM 算法参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 缓冲区大小 | 44100 samples | 1 秒音频 (44100Hz) |
| 白噪声电平 | -14 dB | 响亮电视雪花基底 |
| 50Hz 嗡鸣 | -12 dB | 工频场电强嗡鸣 |
| 行频载波 | 15625 Hz | 显像管高频刺耳 |
| 撕拉调制 | 18 Hz | 切音撕拉频率 |
| 调制阈值 | -0.15 | 脉冲切音触发点 |
| 采样率 | 44100 Hz | PCM 目标采样率 |
| 位深 | 16-bit | 线性 PCM |
| 声道 | 单声道 | Mono |

## 双层 PCM 架构

| 层级 | 缓冲区 | 来源 | 优先级 |
|------|--------|------|--------|
| 内置层 | `g_embeddedPcmBuffer[44100]` | C 代码硬编码合成 | 低 (默认回退) |
| 动态层 | `g_customPcmBuffer` (malloc) | 用户导入 MP3 解码 | 高 (覆盖内置) |

## Aux 三步联动架构

| 步骤 | API | 说明 |
|------|-----|------|
| 1. 开启辅助混音 | `enableAux:YES` | 打开 ZegoAudioAux 通道 |
| 2. 采集移相混入 | `setAudioCaptureShiftOnMix:YES` | 确保 Aux 数据混入上行推流 |
| 3. 持续灌入 PCM | `setAudioAuxData:dataLen:sampleRate:channelCount:` | 20ms 定时注入 882 samples |

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
