# FightVoicePro - 声控物语搏击音效插件

专用于声控物语的麦克风采集放大与搏击清晰音效插件（Tweak）。

## 功能特性

- **400% 麦克风采集增益** - 暴力提升麦克风音量
- **关闭 AGC 自动增益** - 防止大喊时音量被自动拉低
- **关闭噪声抑制** - 避免人声被当成噪音切断
- **10段 EQ 搏击调音** - 低频爆发 + 中高频清晰穿透
- **悬浮控制面板** - 双指双击调出，可拖拽
- **动态切换** - 开关实时生效，无需重新进房间

## 使用方法

1. 安装 `.deb` 或注入 `.dylib` 到声控物语 App
2. 启动 App 后，**双指双击**屏幕调出悬浮面板
3. 点击开关开启/关闭搏击音效
4. 拖拽浮窗可调整位置

## 构建

使用 Theos 构建：

```bash
make clean
make package FINALPACKAGE=1
```

输出文件位于 `packages/` 目录。

## 项目结构

```
├── Tweak.x                      # 核心 Hook 代码
├── Makefile                     # Theos 编译配置
├── control                      # deb 包控制文件
└── .github/workflows/build.yml  # GitHub Actions 自动构建
```
