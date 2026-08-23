# FightVoicePro v2.1.0 - 声控物语搏击音效插件

专用于声控物语的 PCM 底层音频拦截与机械撕裂搏击音效插件（Tweak）。

## v2.1.0 核心更新

- **多重强制开麦** - 拦截 ZegoLiveRoomApi.enableMic: / SKAudioZegoManager.enableMic: / SKMicrophonePermissionManager，开关打开时强制返回 YES 并不响应下麦
- **50Hz 强力嗡鸣叠加** - 在 PCM 采样点直接混入 -15dB（振幅约 0.18）的 50Hz 交流电嗡鸣/胸腔共振底
- **高响度机械撕扯** - 底噪电平提升至 -12dB ~ -18dB 区间，16Hz 脉冲断续切音 + 2200Hz 载波共振
- **全频段 EQ 直通** - 禁用所有高通滤波器/低切，20Hz~20kHz 全频段直通，低频嗡鸣完整保留
- **强制永久关闭 3A** - AGC / ANS / Noise Gate / AEC 全部禁用
- **0.8s 保活定时器** - 高优先级队列每 0.8s 刷新 DSP 参数，防止 SDK 重置

## 功能特性

- **PCM 帧级音频处理** - 底层 Hook 采集回调，所有音频修改在原始 PCM 数据上完成
- **多重强制开麦** - 业务层 + 底层 + 权限层三重拦截
- **50Hz 嗡鸣注入** - 正弦波信号直接叠加到 PCM 采样点
- **响亮机械撕扯** - 16Hz 脉冲调制 + 2200Hz 载波共振 + 硬削顶失真
- **全频段 EQ 直通** - 禁用高通/低切，31Hz~16kHz EQ 增强配置
- **MP3 → PCM 解码推流** - AVAssetReader 解码至内存池，逐采样混入麦克风帧
- **三档爆音模式** - 新清晰搏击(500) / 旧清晰搏击(1000) / 超级战斗(1500)
- **独立分档精细调节** - 调试页 4 个滑动条：三档音量 + 人声权重
- **悬浮控制面板** - 双指双击调出，可拖拽
- **手势冲突修复** - 列表/调试区域滑动不触发浮窗拖动
- **iOS 13+ 兼容** - 使用 UIWindowScene 获取 keyWindow
- **动态切换** - 开关实时生效，无需重新进房间

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. 启动 App 后，**双指双击**屏幕调出悬浮面板
3. 点击开关开启/关闭搏击音效
4. 拖拽浮窗可调整位置（列表区域滑动不会误拖动）
5. **音乐 Tab**：点击「上麦发」解码 MP3 至 PCM 并注入推流，点击「删除」移除文件
6. **调试 Tab**：独立调节各档位音量、人声权重
7. **设置 Tab**：查看当前 DSP 参数与版本信息

## 音效档位

| 模式 | 默认增益 | 调节范围 | 撕扯噪声 | 50Hz嗡鸣 | 特征 |
|------|----------|----------|----------|----------|------|
| 新清晰搏击 | 500 | 100~1000 | -18dB | -15dB | 高清齿音 + 轻微撕拉底噪 |
| 旧清晰搏击 | 1000 | 500~2000 | -15dB | -13dB | 中度过载 + 电台撕拉感 |
| 超级战斗 | 1500 | 1000~3000 | -12dB | -11dB | 全频段极限爆音轰炸 |

## DSP 算法参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 脉冲调制频率 | 16 Hz | 极速电台断续切音频率 |
| 载波频率 | 2200 Hz | 机械撕扯金属共振频率 |
| 嗡鸣频率 | 50 Hz | 交流电嗡鸣/胸腔共振 |
| 采样率 | 44100 Hz | PCM 解码目标采样率 |
| 位深 | 16-bit | 线性 PCM |
| 声道 | 单声道 | Mono |
| 保活间隔 | 0.8s | DSP 参数刷新间隔 |

## 调试参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| 人声音量权重 | 1.0 | 0.5~2.0 | 叠加在基础增益上的倍率 |

## 强制开麦拦截点

| 层级 | 类名 | 方法 |
|------|------|------|
| 底层 | ZegoLiveRoomApi | enableMic: |
| 底层 | ZegoLiveRoomApi | setCaptureVolume: |
| 业务层 | SKAudioZegoManager | enableMic: / micEnabled |
| 权限层 | SKMicrophonePermissionManager | hasMicrophonePermission |

## 构建

使用 Theos 构建：

```bash
make clean
make package FINALPACKAGE=1
```

输出文件位于 `packages/` 目录。

## 项目结构

```
├── Tweak.x                      # 核心 Hook 代码（PCM 拦截 + DSP 算法 + UI）
├── Makefile                     # Theos 编译配置
├── control                      # deb 包控制文件
├── FightVoicePro.plist          # 注入过滤配置
└── .github/workflows/build.yml  # GitHub Actions 自动构建
```

## 依赖框架

- UIKit
- Foundation
- AVFoundation
- CoreGraphics
- CoreMedia
