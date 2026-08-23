# FightVoicePro v2.2.0 - 声控物语搏击音效插件

专用于声控物语的 ZegoAudioAux 推流通道与老式电视无信号雪花音效插件（Tweak）。

## v2.2.0 核心重构

- **移除失效的 onCaptureAudioFrame: 拦截** - 该方法是 ZegoAudioObserver 协议代理方法，并非 ZegoLiveRoomApi 实例方法，直接 Hook 无法命中
- **ZegoAudioAux 辅助混音通道** - 通过 `enableAux:` + `setAudioAuxData:dataLen:sampleRate:channelCount:` 官方标准 API 持续注入上行混音流
- **20ms 定时灌流** - 高优先级队列每 20ms 注入 882 samples PCM 帧（44100Hz/16bit/Mono），解决推不上去问题
- **老式电视无信号雪花算法** - 高电平白噪声 + 50Hz 工频嗡鸣 + 15.625kHz 行频啸叫 + 20Hz 场扫描失步切音
- **startPublishing Hook** - 拦截推流开始事件，延迟 0.3s 自动应用 DSP 配置

## 功能特性

- **ZegoAudioAux 推流通道** - 官方标准辅助混音 API，20ms 定时持续注入 PCM
- **电视雪花音效** - 全频段随机白噪声 + 50Hz 场频嗡鸣 + 15625Hz 行频啸叫 + 20Hz 跳帧撕扯
- **多重强制开麦** - ZegoLiveRoomApi / SKAudioZegoManager / SKMicrophonePermissionManager 三层拦截
- **强制永久关闭 3A** - AGC / ANS / Noise Gate / AEC 全部禁用
- **全频段 EQ 直通** - 20Hz~20kHz 十段 EQ 增强配置，低频嗡鸣完整保留
- **MP3 → PCM 解码推流** - AVAssetReader 解码至内存池，通过 Aux 通道混入
- **三档爆音模式** - 新清晰搏击(500) / 旧清晰搏击(1000) / 超级战斗(1500)
- **0.8s 保活定时器** - 高优先级队列刷新 DSP 参数
- **悬浮控制面板** - 双指双击调出，可拖拽
- **iOS 13+ 兼容** - UIWindowScene 获取 keyWindow

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. 启动 App 后，**双指双击**屏幕调出悬浮面板
3. 点击开关开启/关闭搏击音效
4. **音乐 Tab**：点击「上麦发」解码 MP3 至 PCM 并注入推流
5. **调试 Tab**：独立调节各档位音量、人声权重
6. **设置 Tab**：查看当前 DSP 参数与版本信息

## 音效档位

| 模式 | 增益 | 白噪声 | 50Hz嗡鸣 | 特征 |
|------|------|--------|----------|------|
| 新清晰搏击 | 500 | -18dB | -15dB | 高清齿音 + 轻微雪花底噪 |
| 旧清晰搏击 | 1000 | -15dB | -13dB | 中度过载 + 强力雪花嗡鸣 |
| 超级战斗 | 1500 | -12dB | -11dB | 极限无信号爆裂轰炸 |

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

## 推流通道架构

| 组件 | API | 说明 |
|------|-----|------|
| 辅助混音开关 | `enableAux:` | 开启 ZegoAudioAux 通道 |
| PCM 数据注入 | `setAudioAuxData:dataLen:sampleRate:channelCount:` | 20ms 定时持续灌入 |
| 推流拦截 | `startPublishing:title:flag:extraInfo:` | 延迟 0.3s 自动配置 |
| 推流拦截2 | `startPublishing2:...` | 多通道推流拦截 |

## 构建

```bash
make clean
make package FINALPACKAGE=1
```

## 依赖框架

- UIKit / Foundation / AVFoundation / CoreGraphics / CoreMedia
