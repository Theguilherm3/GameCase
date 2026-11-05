# GameCase

**所有移植游戏的专用容器。**

GameCase 基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 定制：砍掉通用 App 容器的旁支功能，只保留一件事——把移植游戏装进一个游戏库里，导入、设置、启动、切换，全在库内完成。它不是通用侧载工具，是为移植游戏而生的「万游之匣」。

游戏在容器进程内全屏直跑，串行单开；玩完一款，点游戏内快捷栏回到游戏库，再开下一款，上一个游戏的进程随之关闭，不留后台。

## 功能

- **NX 式游戏库界面**：横屏封面轮播 + 竖屏封面大图主页，布局效仿 NX2Apple 壳界面；库内可直接调每款游戏的设置
- **IPA ＋ romfs 数据包双导入**：游戏本体（IPA）与数据包（romfs.img）分别导入，数据包校验大小后写入对应游戏的数据容器
- **每游戏设置页**：运行时解析客体 IPA 自带的启动器档案（dm/launcher.json），与游戏内启动器逐项镜像、双向互通，不做任何外部增补
- **按键布局编辑**：在库内直接调整每款游戏的触控按键位置与大小，格式与客体引擎一致
- **手柄页**：已连接手柄列表、电量与状态、按键测试（按 NX2Apple 的 Controllers 页移植）
- **游戏内快捷栏**：平时是吸附在屏幕边缘的半藏玻璃舌，四边任意拖动吸附、位置记忆；点击展开完整快捷栏，一键返回游戏库；回库带淡出过场（先淡出到黑、自拉起回库、库侧再淡入），不再有裸黑场接缝
- **串行单开**：同一时刻只运行一款游戏，切换即关掉上一个进程
- **免 JIT 证书模式**：在容器设置里导入开发者证书后免 JIT 运行；证书须与签名容器本体所用证书同团队

## 安装与签名须知

- 本仓库的 Release 提供未签名 IPA，请用自己的开发者证书签名安装。
- **应用标识必须与证书对齐**：签名工具里改用的标识要与证书的 App ID 一致，否则会出现文件选择器无回调、导入失败等问题。
- **作为新项目导入签名工具**，不要复用被第三方签名服务改过标识的旧项目。
- **不要使用会注入 LoadControl 的签名服务**：被注入 `LoadControl.dylib` 的包会在启动时闪退（注入方在初始化阶段 abort），本仓库发布的 IPA 内不含此文件。
- 免 JIT 模式：在容器设置中导入与签名容器本体同一团队的证书，团队不一致会被挡下。

## 使用要点

1. 在游戏库右上「＋」导入游戏 IPA；
2. 为需要数据包的游戏导入对应的 romfs.img（导入后写入该游戏数据容器的 Documents 内）；
3. 点封面或「开始」启动；游戏内点屏幕边缘的快捷栏舌展开快捷栏，点「游戏库」返回库界面，再开下一款。

## 致谢与开源来源

GameCase 站在以下开源工作之上，特此致谢：

- **[LiveContainer](https://github.com/LiveContainer/LiveContainer)** —— 本项目的底座（在容器内免安装运行 iOS 应用的启动器）。原作者 **Duy Tran（[khanhduytran0](https://github.com/khanhduytran0)）**，主要维护者 **[hugeBlack](https://github.com/hugeBlack)**，以及 LiveContainer 组织与众多贡献者。本项目完整继承其代码与 git 历史，并沿用同一许可证 **GNU AGPL v3.0**（见仓库根目录 `LICENSE`）。上游原 README 全文保留于 [docs/livecontainer-readme.md](docs/livecontainer-readme.md)。
- **[nxnative](https://github.com/seedds/nxnative)**（作者 **[seedds](https://github.com/seedds)**）—— 客体游戏移植的工具链与生态来源：GameCase 中运行的移植游戏 IPA 由 nxnative 产出（NSO 重写、Horizon HLE、NVN→Metal）。
- **[NX2Apple](https://github.com/LNPANDY/NX2Apple)**（作者 **[LNPANDY](https://github.com/LNPANDY)**）—— 设计参考来源：游戏库界面的效仿对象、其壳的手柄设置页（Controllers）被移植进 GameCase，其一壳多游戏的思路亦为本项目的参照。

## 声明

- GameCase 本身**不包含任何游戏内容**。游戏 IPA 与数据包（romfs.img）需由用户自备，并请确保来源合法。
- 相关游戏的版权归各原厂所有（如《空洞骑士：丝之歌》归 Team Cherry、《哈迪斯 II》归 Supergiant Games 等），本项目与上述原作者、团队及游戏厂商均无隶属关系。
- 本项目按 GNU AGPL v3.0 发布；若你分发修改版，请同样以 AGPL-3.0 开源并保留上述归属。

## 链接

- 上游底座：[LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer)
- 上游原 README（归档）：[docs/livecontainer-readme.md](docs/livecontainer-readme.md)
- 许可证：[LICENSE](LICENSE)
