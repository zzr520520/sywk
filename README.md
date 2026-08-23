# FightVoicePro v2.4.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.4.0 核心修复

- **setAudioCaptureShiftOnMix:YES 混音修正** - 根本原因：仅调用 `enableAux:YES` 不够，SDK 会丢弃未开启采集移相的 Aux 数据；新增 `setAudioCaptureShiftOnMix:YES` 确保 Aux 数据直接混入上行推流通道
- **Aux 三步联动** - `enableAux:YES` → `setAudioCaptureShiftOnMix:YES` → `setAudioAuxData:` 完整链路
- **本地试听测试** - 设置页新增「开始试听」/「停止试听」按钮，使用 AVAudioPlayer 循环播放当前推流音频，开麦前即可验证音效
- **双触发推流** - `init` + `startPublishing` 双入口调用 `StartAuxDataInjector`，dispatch_once 保证只执行一次
- **EQ 增强** - 4kHz 段增益提升至 15dB，高频啸叫更突出
- **噪音电平提升** - 各档位白噪声/嗡鸣电平均提升 2-4dB

## v2.3.0 核心修复

- **pthread 线程安全 PCM 管理** - 互斥锁保护 PCM 缓冲区，彻底规避切歌时的 Use-After-Free 竞争崩溃
- **Double-buffering 原子置换** - 锁外 malloc+memcpy 完成新缓冲区准备，锁内仅做指针原子置换，锁外释放旧缓冲区
- **推流时机修正** - Aux 灌流移至 `startPublishing` / `startPublishing2`，确保 SDK 完全初始化后再注入数据
- **前置函数声明** - 消除隐式声明编译错误
- **合并 UIWindow Hook** - 修复 Logos 语法中重复 `%hook UIWindow` 硬伤
- **内置默认噪音** - 启动即加载 `tv_snow.mp3`

## 功能特性

- **ZegoAudioAux 三步联动推流** - `enableAux:` + `setAudioCaptureShiftOnMix:` + `setAudioAuxData:` 完整混音链路
- **本地试听测试** - AVAudioPlayer 循环播放，开麦前验证音效
- **线程安全 PCM 池** - pthread_mutex + Double-buffering
- **电视雪花音效** - 全频段随机白噪声 + 50Hz 场频嗡鸣 + 15625Hz 行频啸叫 + 20Hz 跳帧撕扯
- **多重强制开麦** - ZegoLiveRoomApi / SKAudioZegoManager / SKMicrophonePermissionManager 三层拦截
- **强制永久关闭 3A** - AGC / ANS / Noise Gate / AEC 全部禁用
- **全频段 EQ 直通** - 20Hz~20kHz 十段 EQ 增强配置，4kHz 高频啸叫 +15dB
- **MP3 → PCM 解码推流** - AVAssetReader 解码至内存池，通过 Aux 通道混入
- **三档爆音模式** - 新清晰搏击(500) / 旧清晰搏击(1000) / 超级战斗(1500)
- **0.8s 保活定时器** - 高优先级队列刷新 DSP 参数
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 获取 keyWindow

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. 启动 App 后，**双指双击**屏幕调出悬浮面板
3. 点击开关开启/关闭搏击音效
4. **音乐 Tab**：点击「上麦发」解码 MP3 至 PCM 并注入推流；点击「默认噪音」恢复内置雪花
5. **调试 Tab**：独立调节各档位音量、人声权重
6. **设置 Tab**：点击「开始试听」本地循环播放当前音频验证效果；查看版本与 DSP 参数信息

## 音效档位

| 模式 | 增益 | 白噪声 | 50Hz嗡鸣 | 特征 |
|------|------|--------|----------|------|
| 新清晰搏击 | 500 | -16dB | -14dB | 高清齿音 + 轻微雪花底噪 |
| 旧清晰搏击 | 1000 | -13dB | -11dB | 中度过载 + 强力雪花嗡鸣 |
| 超级战斗 | 1500 | -10dB | -9dB | 极限无信号爆裂轰炸 |

## Aux 三步联动架构

| 步骤 | API | 说明 |
|------|-----|------|
| 1. 开启辅助混音 | `enableAux:YES` | 打开 ZegoAudioAux 通道 |
| 2. 采集移相混入 | `setAudioCaptureShiftOnMix:YES` | 确保 Aux 数据不被 SDK 丢弃，混入上行推流 |
| 3. 持续灌入 PCM | `setAudioAuxData:dataLen:sampleRate:channelCount:` | 20ms 定时注入 882 samples |

## 线程安全架构

| 组件 | 机制 | 说明 |
|------|------|------|
| PCM 缓冲区 | pthread_mutex | 互斥锁保护 g_musicPcmBuffer 读写 |
| 新缓冲区分配 | 锁外 malloc + memcpy | 耗时操作不阻塞音频推流线程 |
| 指针置换 | 锁内原子赋值 | 极短临界区，音频线程等待趋近零 |
| 旧缓冲区释放 | 锁外 free | 避免 free 耗时阻塞音频线程 |
| 停止播放 | 锁内置 NULL | 读者线程检测 NULL 自动回退至雪花合成 |

## DSP 算法参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 白噪声 | 全频段随机 | 老式电视雪花物理实质 |
| 场频嗡鸣 | 50 Hz | 交流工频场电嗡鸣 |
| 行频啸叫 | 15625 Hz | 显像管行扫描频率 |
| 场扫描切音 | 20 Hz | 画面跳帧失步撕扯 |
| Aux 推流间隔 | 20 ms | 882 samples/frame |
| 采样率 | 44100 Hz | PCM 解码目标采样率 |
| 位深 | 16-bit | 线性 PCM |
| 声道 | 单声道 | Mono |
| 保活间隔 | 0.8 s | DSP 参数刷新间隔 |

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
