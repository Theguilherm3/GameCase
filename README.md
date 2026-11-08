# GameCase

> 导入 IPA 与数据包，打开就玩

GameCase 是一个专为 iOS 移植游戏设计的侧载游戏容器。它基于开源项目 LiveContainer 定制，砍掉通用 App 容器的旁支功能，只保留一件事：把移植游戏装进一个游戏库里——导入、封面、设置、启动、切换，全在库内完成。

游戏在容器进程内全屏直跑，串行单开；玩完一款，从游戏内快捷栏回到游戏库再开下一款，上一个游戏的进程随之关闭，不留后台。免越狱，侧载即用。

## 它做对了什么

**像游戏机一样选游戏**
游戏库效仿 NX2Apple 壳界面：横屏是封面色调背景加卡片轮播，竖屏是封面大图、最近游玩与游玩时长、底部开始胶囊。打开 GameCase 不是面对一列文件，而是站在自己的游戏架前。

**游戏和数据包，分开导入**
移植游戏的 IPA 与 romfs 数据包（romfs.img）各走各的通道：数据包导入时校验大小后写入对应游戏的容器，游戏更新只换 IPA，几个 G 的数据包不用重下。

**设置项，游戏自己说了算**
每款游戏的设置直接来自它自带的启动器档案（dm/launcher.json）：帧率、画面模式、超分、皮肤——游戏有什么，这里就有什么，不多一项不少一项。库内修改与游戏内修改双向同步，下次启动生效。设置页是 NX 式整页：大封面头加分段控件。

**封面，不用你操心**
优先用 IPA 自带横版图；有官方主视觉的，按游戏 ID 从任天堂商店自动抓取 1920×1080 封面；也可以换成你自己的图，或随时恢复默认。

**容器夹，就是游戏名**
每款游戏的数据容器文件夹以游戏名命名（`Data/Application/<游戏名>/`）。在「文件」App 里手动放数据包、管存档时，一眼就知道哪个夹是哪款游戏。

**快捷栏一键回库，只开一款所以稳**
游戏内顶部吸附一条半藏的玻璃舌，可沿上边拖动、落点记忆；点开是完整快捷栏，一键返回游戏库（带淡出过场）。串行单开不做多任务，全部性能留给正在运行的游戏——对移植游戏来说，这才是正经事。

**手柄与证书**
手柄页实时列出已连接手柄与电量状态（按 NX2Apple 的 Controllers 页移植）；容器设置里导入与签名同团队的开发者证书后，可免 JIT 运行。

## 截图

![横屏游戏库](docs/media/library-landscape.jpg)

横屏游戏库：封面牌组，中间为当前选中的游戏。

![竖屏游戏库主页](docs/media/library-portrait.jpg)

竖屏游戏库主页：大封面、「你的游戏」网格、「最近游玩」与底部的开始按钮。

![游戏设置页](docs/media/game-settings.jpg)

游戏设置页（以撒）：显示分组，含主机模式、超分、游戏语言与帧数计数器。

## 三步开玩

1. 侧载安装 GameCase，并在容器设置里导入证书；
2. 导入游戏 IPA 与对应数据包（romfs.img）；
3. 点封面，开玩。

## 装机须知

- **签名证书类型**：GameCase 必须用**开发者证书（Development）**签名安装。市面商家普遍售卖的是分发证书（Distribution）或企业证书，这类证书签出来打开会提示「未使用开发者证书签名」、点游戏闪退，改设置没用。**购买证书前请先向商家确认证书类型是开发者证书，再下单。**
- **全新 App 身份**：GameCase（`com.tiaoge.gamecase`）在系统眼里是一个全新 App，与旧 LiveContainer 并存、互不影响。首次使用需重新导入证书、游戏 IPA 与数据包各一次；确认一切正常后，可删除旧容器。
- **签名标识必须与证书对齐**：签名工具里改用的标识要与证书的 App ID 一致，否则会出现文件选择器点不动/无回调、数据包选不了、证书导入失败等问题。本仓库 Release 提供未签名 IPA，请用自己的开发者证书签名安装，并作为新项目导入签名工具，不要复用被第三方签名服务改过标识的旧项目。
- **数据包手动放置**：也可以不用 App 内导入，直接在「文件」App 里把 `romfs.img` 放进 `GameCase → Data → Application → <游戏名> → Documents` 文件夹内（注意是游戏容器夹里面的 Documents，不是放在容器夹根目录）。
- **免 JIT 模式**：在容器设置中导入与签名容器本体同一团队的证书，团队不一致会被挡下。

## 致谢与开源来源

GameCase 站在以下开源工作之上，特此致谢：

- **[LiveContainer](https://github.com/LiveContainer/LiveContainer)** —— 本项目的底座（在容器内免安装运行 iOS 应用的启动器）。原作者 **Duy Tran（[khanhduytran0](https://github.com/khanhduytran0)）**，主要维护者 **[hugeBlack](https://github.com/hugeBlack)**，以及 LiveContainer 组织与众多贡献者。本项目完整继承其代码与 git 历史，并沿用同一许可证 **GNU AGPL v3.0**（见仓库根目录 `LICENSE`）。上游原 README 全文保留于 [docs/livecontainer-readme.md](docs/livecontainer-readme.md)。
- **[nxnative](https://github.com/seedds/nxnative)**（作者 **[seedds](https://github.com/seedds)**）—— 客体游戏移植的工具链与生态来源：GameCase 中运行的移植游戏 IPA 由 nxnative 产出（NSO 重写、Horizon HLE、NVN→Metal）。
- **[NX2Apple](https://github.com/LNPANDY/NX2Apple)**（作者 **[LNPANDY](https://github.com/LNPANDY)**）—— 设计参考来源：游戏库界面的效仿对象、其壳的手柄设置页（Controllers）被移植进 GameCase，其一壳多游戏的思路亦为本项目的参照。

## 声明

- GameCase 本身**不包含任何游戏内容**。游戏 IPA 与数据包（romfs.img）需由用户自备，并请确保来源合法。
- 相关游戏的版权归各原厂所有，本项目与上述原作者、团队及游戏厂商均无隶属关系。
- 本项目按 GNU AGPL v3.0 发布；若你分发修改版，请同样以 AGPL-3.0 开源并保留上述归属。

## 链接

- 本项目：[Tiaoge-tou/GameCase](https://github.com/Tiaoge-tou/GameCase)
- 下载（nightly）：[Releases](https://github.com/Tiaoge-tou/GameCase/releases)
- 上游底座：[LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer)
- 上游原 README（归档）：[docs/livecontainer-readme.md](docs/livecontainer-readme.md)
- 许可证：[LICENSE](LICENSE)
