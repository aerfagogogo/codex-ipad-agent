# README 公开截图清单

## 目标

这里只保留能代表当前 UI 的 README 正式截图。历史模拟器图、旧 TestFlight 图和旧版 DeviceHub 图已于 2026-07-27 删除，避免 README、设计讨论或后续发布继续误用过期界面。

## 当前资产

| 设备 | 文件名 | 尺寸 | 展示内容 |
| --- | --- | --- | --- |
| iPhone 17 Pro | `iphone-devicehub-2026-07-27-conversation.png` | 625×1305 | 竖屏紧凑会话、折叠工作流与 Composer。 |
| iPad mini（A17 Pro） | `ipad-mini-devicehub-2026-07-27-queue.png` | 1380×1980 | 竖屏运行态、待发送队列、权限模式与 Composer。 |
| iPad Pro 12.9 英寸（第 5 代） | `ipad-pro-devicehub-2026-07-27-workbench.png` | 2570×1950 | 横屏工作台、项目与最近会话、会话正文和宽屏 Composer。 |
| iPad Pro 13 英寸（M5）模拟器 | `ipad-pro-simulator-2026-07-28-workspace.png` | 2064×2752 | 项目卡片、运行状态、快捷启动、最近会话与全局导航。 |
| iPad Pro 13 英寸（M5）模拟器 | `ipad-pro-simulator-2026-07-28-settings.png` | 2064×2752 | 叠加在当前工作台上的额度、连接与偏好设置。 |
| Mimi Remote Mac Debug | `mac-menu-bar-debug-2026-07-28.png` | 680×1220 | 340pt 菜单栏控制面、双 Runtime 状态、额度环与运维动作。 |

## 采集方式

- 三张实体设备图安装同一次 Xcode 27 beta 4 Debug 构建，构建输入为采集时的同一当前工作树。
- 实体设备 App 通过 `--debug-skip-pairing`、`--debug-seed-ui` / `--debug-seed-queue-ui` 启动，并用 `-app.language en` 固定英文界面。图片来自 Xcode Device Hub，只裁掉 DeviceHub 侧栏、工具栏和桌面背景，保留完整设备边框。
- 两张 iPad 细节图来自一台已有的 iOS 26.5 iPad Pro 13 英寸（M5）模拟器。采集前确认没有其他模拟器运行，没有创建、擦除或删除设备；当前 Debug 构建使用 `--debug-skip-pairing --debug-seed-ui -app.language en` 启动，采集结束后已关闭模拟器。
- Mac 图由当前源码构建 Debug App，以 `--debug-seed-ui` 启动并复用现有 Preview 数据；只裁出 MenuBarExtra 窗口。截图进程在采集后已退出，已安装的正式 App 和正在运行的服务没有被重启或替换。
- 所有图片都来自实际运行的 SwiftUI 界面，没有重绘或修改 App 内容。系统状态栏跟随设备区域设置，因此日期等系统文案可能不是英文。

## 隐私与更新规则

- Debug 种子数据只使用 `/Users/demo`、占位凭证、公开 README 检查文案和 `mimi-demo.local` 演示 Endpoint。
- 六张图均已目视检查，不包含真实 Token、Tailnet 地址、个人仓库或个人文件目录。
- UI、显示名称、主要导航、Composer、设置层级或 Mac 菜单栏发生明显变化后，应重拍对应图片并直接替换当前资产，不再累积旧版正式截图。
- 被删除的历史 PNG 都是 Git 已跟踪文件，如需审计可从 Git 历史恢复。
