# Changelog

## [1.9.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.8.1...ark_novel-v1.9.0) (2026-11-26)


### Features

* 优化全书搜索后台响应速度与长篇插图 EPUB 流式导出 ([f392377](https://github.com/chenshi221/ark_novel/commit/f3923777a8d389b607e72b1b427349ea3cf9edd2))
* 优化冷启动速度、阅读器翻页与排版引擎及滚动朗读流畅度 ([4e392cd](https://github.com/chenshi221/ark_novel/commit/4e392cd62f6ebdcca51e564e94e4312f3f535ab0))
* 优化多层缓存、网页压缩存储、WebDAV 增量同步与网络请求取消 ([ded4ece](https://github.com/chenshi221/ark_novel/commit/ded4ece374ef6509364857996cbe0b9757235c4e))
* 原生重写安卓桌面小组件并压缩内置主题与繁简词表，显著缩小安装包体积 ([c4bbeb0](https://github.com/chenshi221/ark_novel/commit/c4bbeb064393b7797568d4b4c934c9816c840b6c))


### Bug Fixes

* 优化书架与统计页渲染流畅度、降低图片显存峰值并修复多处动画内存泄漏 ([f684115](https://github.com/chenshi221/ark_novel/commit/f6841152261e8cfd5f962a9258ef99af5068da29))

## [1.8.1](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.8.0...ark_novel-v1.8.1) (2026-11-25)


### Features

* 统一页面过渡与按压回弹动效并支持减弱动态效果 ([81f46a2](https://github.com/chenshi221/ark_novel/commit/81f46a230862cd2cd0a979590f936ba143581ca8))


### Bug Fixes

* 修复书架书脊视图两侧点击不切换与封面书名接缝闪烁 ([a726709](https://github.com/chenshi221/ark_novel/commit/a7267095abc46979cb439a795a5aeddae3ddf5c6))
* 小幅优化图片缓存与阅读页内存占用 ([1ba0ba7](https://github.com/chenshi221/ark_novel/commit/1ba0ba7c3359a726c2a7c6d0b1def7c7785f3cd8))

## [1.8.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.7.0...ark_novel-v1.8.0) (2026-11-24)


### Features

* Mac 宽屏改为带文字的侧栏，资料库和账号直接放在侧栏里 ([f9ed3b3](https://github.com/chenshi221/ark_novel/commit/f9ed3b304a98408d8d064d900146a08df98128f4))
* 新增书脊书架模式并优化立体书架交互、分类计数与单行顶栏 ([7b5d5c4](https://github.com/chenshi221/ark_novel/commit/7b5d5c42fae9733b5c5265aa646323027c3ef377))
* 立体书架与分卷页新增方向性滚筒字幕、桌面 3D 视差倾转与悬停抬升 ([f35223e](https://github.com/chenshi221/ark_novel/commit/f35223e9be88873adb7d4870d7039d6794d70732))
* 重新调整全部配色，卡片与分隔线层次更清晰 ([6797c6c](https://github.com/chenshi221/ark_novel/commit/6797c6c09bb95c6998a4c91606ee5bd252648071))
* 重构宽屏侧边栏并支持打开设置保留侧栏与双栏布局 ([de06ab0](https://github.com/chenshi221/ark_novel/commit/de06ab0e7e24aca8ed4ed381dd1b6416c69e4f80))


### Bug Fixes

* 修复网络拦截点击验证时默认进入登录页的问题 ([cdba087](https://github.com/chenshi221/ark_novel/commit/cdba0875294d5165694fcf11647a50aa9a8854a3))
* 修复苹果端网络栈 -1000 异常回落、重定向 HTTPS 升级与切节点自动刷新 ([5b77aea](https://github.com/chenshi221/ark_novel/commit/5b77aeae5a43809174b65e6a597c5e228795c933))

## [1.7.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.6.0...ark_novel-v1.7.0) (2026-11-24)


### Features

* 优化冷启动缓存隔离、图片与超分调度并开启 Android R8 瘦身 ([3f8d64e](https://github.com/chenshi221/ark_novel/commit/3f8d64ec84e4307ad533594bc01dd068841ad49b))
* 新增启动自愈与脱敏诊断日志、同步诊断面板及桌面端原生菜单 ([923d2bf](https://github.com/chenshi221/ark_novel/commit/923d2bf3ac7d344026386709eb52ade5384bf3c4))
* 阅读器新增字间距与段间距、自由划线摘录（支持导出 Markdown）与跳转撤销条 ([107cb46](https://github.com/chenshi221/ark_novel/commit/107cb46e77c3801085cea7769d2bb86c44237eb1))


### Bug Fixes

* 移除本地书籍导入功能（保留在线书导出）并修复规则、人物与搜索稳定性问题 ([21d1d63](https://github.com/chenshi221/ark_novel/commit/21d1d63d5d038b3f1bc2e82674eecd7f27aae9f9))

## [1.6.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.5.0...ark_novel-v1.6.0) (2026-11-23)


### Features

* 优化书架封面缩略图缓存、卷册懒加载与全站渲染性能 ([e729305](https://github.com/chenshi221/ark_novel/commit/e729305037474dc5661c221f3a94ad5aa428868c))
* 支持本地 EPUB / TXT 书籍导入阅读与已缓存书籍导出 ([ab04254](https://github.com/chenshi221/ark_novel/commit/ab0425478723d30970865d1770e811904851eb20))
* 新增 Bangumi 信息卡、人物/设定词典与书内全文搜索 ([7e2f740](https://github.com/chenshi221/ark_novel/commit/7e2f740767c8dd3642dbfb41f2ec1700a97be652))
* 新增阅读器自动阅读、背景纹理与自定义页眉页脚，支持阅读目标与年度阅读报告 ([3a3effe](https://github.com/chenshi221/ark_novel/commit/3a3effe4f73d5fae8227554d49ae66ac27d09dbe))


### Bug Fixes

* 修复唤起阅读器菜单时底部栏滑出方向错位 ([c9c8d7d](https://github.com/chenshi221/ark_novel/commit/c9c8d7d6d6ff81bc2843c97efda40a193abd2923))

## [1.5.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.4.0...ark_novel-v1.5.0) (2026-11-22)


### Features

* 优化三端编译速度、Android Debug ABI 过滤与 CI 缓存策略 ([bd3568e](https://github.com/chenshi221/ark_novel/commit/bd3568eeb7aa0f2018b95cefa743f8fb16a69238))
* 优化网络请求复用、Cloudflare 跨域名验证与登录态同步体验 ([3e70317](https://github.com/chenshi221/ark_novel/commit/3e703170bb41f4619fa0eecc43166781865bc59a))


### Bug Fixes

* 优化主题对比度与按钮尺寸，解耦路由常量并支持偏好细粒度监听 ([bff3826](https://github.com/chenshi221/ark_novel/commit/bff3826b435e178a5fa485057cb52dd291e2116d))
* 优化书架、3D 书架、卷册、详情页与公共组件的性能与交互体验 ([309ab89](https://github.com/chenshi221/ark_novel/commit/309ab89e45b0a5d436e5787a590e0b195f35049d))
* 优化发现、更新、设置、同步、统计等全站页面 UI/UX 与性能 ([e73e485](https://github.com/chenshi221/ark_novel/commit/e73e4853baecec7cddd6971e13cf3aa8f2b10670))
* 清理模块循环导入并修复阅读器插图按钮热区与验证路由衔接 ([9b8fe18](https://github.com/chenshi221/ark_novel/commit/9b8fe18a211d7d50f06d955ad69a7b107cedc4ec))


### Performance Improvements

* 优化简繁转换、分卷/图片缓存、离线下载与 WebDAV 同步架构 ([d09ed7b](https://github.com/chenshi221/ark_novel/commit/d09ed7b0362ebd8a475780d09ad2b313358e740f))
* 优化网络层连接复用、Cloudflare 单飞协调与请求治理 ([e743903](https://github.com/chenshi221/ark_novel/commit/e743903e28bf0c3618ed177417a47b7e2744e4b2))
* 优化阅读器翻页与正文繁体性能、拆离 TTS 与弹窗并提升阅读交互 ([331af84](https://github.com/chenshi221/ark_novel/commit/331af84bc3186de3e25f4951a7cd8dbc125d68f4))

## [1.4.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.3.1...ark_novel-v1.4.0) (2026-11-21)


### Features

* 优化各页面新手指引、游客登录提示与设置搜索定位 ([fae97e3](https://github.com/chenshi221/ark_novel/commit/fae97e3fea54d15fbad7069b54e2aefdbc49d67a))
* 完善桌面端窗口拖动、触控板翻页、快捷键与右键菜单体验 ([690b737](https://github.com/chenshi221/ark_novel/commit/690b737461b1f97874b456af1bdcc205a1171eb1))
* 支持阅读页插图全屏缩放查看、点击区域示意图与受限章节引导 ([bcbccce](https://github.com/chenshi221/ark_novel/commit/bcbccce62ed94e6f5ce2f0bbcdf4601019e4af69))


### Bug Fixes

* 修复同步与备份一致性、登录失效识别及阅读时长统计问题 ([1e8bce8](https://github.com/chenshi221/ark_novel/commit/1e8bce88d2dafd3818f356f4c0e61fdfd50d3eda))

## [1.3.1](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.3.0...ark_novel-v1.3.1) (2026-11-21)


### Features

* 显著缩小安卓安装包体积并优化编译速度与缓存 ([c39a05c](https://github.com/chenshi221/ark_novel/commit/c39a05ce6f9049449807af0d727bb260d361a980))

## [1.3.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.2.0...ark_novel-v1.3.0) (2026-11-17)


### Features

* 增加 Bangumi 封面临时兜底与阅读页插图加载/失败重试占位 ([7be8062](https://github.com/chenshi221/ark_novel/commit/7be80624f2006fef91486a4c2a146856d14f4cdd))
* 支持从文件和口令导入妙妙小工具扩展 ([d6d438f](https://github.com/chenshi221/ark_novel/commit/d6d438ff8ed1f5c591618640bb3cb30838a31f9a))


### Bug Fixes

* 删除章节缓存后立即更新存储空间和离线缓存列表 ([20c5e2d](https://github.com/chenshi221/ark_novel/commit/20c5e2d7ceba2fd9fa8da3398365c3753bfbe794))
* 接入备选图床域名并支持图床 Cloudflare 过盾 ([d14a09f](https://github.com/chenshi221/ark_novel/commit/d14a09fa72e7d1561fe189fa4156f10fe9464d22))

## [1.2.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.1.2...ark_novel-v1.2.0) (2026-11-14)


### Features

* 书架新增「立体」显示方式 ([0308119](https://github.com/chenshi221/ark_novel/commit/030811907ab280bd769361c83b2d6dee22e294bc))
* 安卓安装包默认支持 arm64、armeabi-v7a 和 x86_64 三种架构 ([1e1736e](https://github.com/chenshi221/ark_novel/commit/1e1736ef96da478b04427f0521115d00bee9c79b))
* 设置里的「书籍解锁」改为「妙妙小工具」，入口直接显示 ([26b6e78](https://github.com/chenshi221/ark_novel/commit/26b6e784277a001f02c5fbe5b98b1276662e88f5))


### Bug Fixes

* 修复 wenku8.cc 一直显示离线模式，重新连接失败时显示具体原因 ([99c0319](https://github.com/chenshi221/ark_novel/commit/99c0319d28a6b24a71f68e1beeb7b5c4215651d8))
* 底部导航栏比页面背景深一档，和上面的内容分开 ([07c975f](https://github.com/chenshi221/ark_novel/commit/07c975f0a058b9a683baf5ac302c71c33a8e0c98))
* 自定义分类标签（如「在追」）里打开卷册页时恢复封面飞过去的动画 ([0707da5](https://github.com/chenshi221/ark_novel/commit/0707da54758b0dc9bcaf0a83d9f8c012b0a3f54b))

## [1.1.2](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.1.1...ark_novel-v1.1.2) (2026-11-11)


### Bug Fixes

* 换号后首次同步保留新账号的书架操作，繁体界面开关恢复同步 ([8c3d048](https://github.com/chenshi221/ark_novel/commit/8c3d04863562778546e5811bb839d662e3532760))
* 换号后首次同步保留新账号的书架操作，繁体界面开关恢复同步 ([3b4d7b1](https://github.com/chenshi221/ark_novel/commit/3b4d7b14e358fe7a04d1a169f7eb0011223af9f4))

## [1.1.1](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.1.0...ark_novel-v1.1.1) (2026-11-11)


### Bug Fixes

* 修复同步、账号切换和并发写入的数据安全问题 ([bad2466](https://github.com/chenshi221/ark_novel/commit/bad24662971133bc5a86deabe9040f985792e228))
* 修复同步、账号切换和并发写入的数据安全问题 ([2c77fad](https://github.com/chenshi221/ark_novel/commit/2c77fad62e75f88c835cb8e7680247471e56a434))

## [1.1.0](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.5...ark_novel-v1.1.0) (2026-11-11)


### Features

* 繁体中文（台湾写法）：正文和界面分别切换 ([3685dfe](https://github.com/chenshi221/ark_novel/commit/3685dfe163827368ac8627dfebe38fd41b1a39cf))
* 繁体中文（台湾写法）：正文和界面分别切换 ([1560231](https://github.com/chenshi221/ark_novel/commit/1560231478789a6324d313d8f870d7e76ef68e38))

## [1.0.5](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.4...ark_novel-v1.0.5) (2026-11-10)


### Features

* 美化阅读菜单、阅读设置面板和设置页 ([6eb3f4b](https://github.com/chenshi221/ark_novel/commit/6eb3f4b541720bb173293b2573c537785c29266c))
* 美化阅读菜单、阅读设置面板和设置页 ([b77f112](https://github.com/chenshi221/ark_novel/commit/b77f11213e235cf4676b452ec204c89731568913))

## [1.0.4](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.3...ark_novel-v1.0.4) (2026-11-09)


### Bug Fixes

* 修复确认登录途中走网页兜底时卡在启动页 ([776882f](https://github.com/chenshi221/ark_novel/commit/776882f19d5135aec72564134813abfad07ed3e7))
* 登录、cookie 与生物识别锁的安全修复，并修复启动页卡住的回归 ([63b2116](https://github.com/chenshi221/ark_novel/commit/63b2116c846cb1d0288be9a0b378d6af84988adc))

## [1.0.3](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.2...ark_novel-v1.0.3) (2026-11-09)


### Bug Fixes

* 书架、启动流程和 Android 原生的修复 ([bb46c0e](https://github.com/chenshi221/ark_novel/commit/bb46c0e3fd0885ebf646e57917427b947d25f2c2))
* 书架搜索、滑动标签时不再每帧重算各标签的书数 ([982c5d8](https://github.com/chenshi221/ark_novel/commit/982c5d8de928950e85a2fccbf8f3a33eac62e29a))
* 书签列表拖动时不再每帧重新排版整章 ([20b5a25](https://github.com/chenshi221/ark_novel/commit/20b5a2509cef51c1f079473ae4b18a3b138b318e))
* 亮度通道兼容整数参数，阅读器拦音量键时抬起也一起拦掉 ([bda5d90](https://github.com/chenshi221/ark_novel/commit/bda5d9045f2a5caa4c6080916dac6b2b04198a69))
* 全本 TXT 导入时不写回下载期间删掉的缓存，解码放到后台 ([7d2dd0e](https://github.com/chenshi221/ark_novel/commit/7d2dd0ee9986d18d434f600649c4a4ece2355f3f))
* 删除缓存后旧的下载任务不再把进度加回来 ([f849747](https://github.com/chenshi221/ark_novel/commit/f8497472c7f32de9352dd76ea5e04846d22f384e))
* 同步与备份的数据安全修复 ([0bdd6fa](https://github.com/chenshi221/ark_novel/commit/0bdd6fa219da5d7df322b5592c3dec8664575b81))
* 同步合并只收可信的数据，删掉的历史和过期设备不再复活 ([aa47606](https://github.com/chenshi221/ark_novel/commit/aa4760663e4235ba7482836e969c294db6293c5d))
* 同步页在密码读出来之前不能测试或同步 ([17f91d1](https://github.com/chenshi221/ark_novel/commit/17f91d1c6e7481c764301d7f76be0d2bcca5917b))
* 启动和恢复在线时不再同时跑两遍书架同步和检查更新 ([a041dc2](https://github.com/chenshi221/ark_novel/commit/a041dc20bb6d4424e363f2c817e0199b69a800bf))
* 启动时本地数据库打不开就显示原因，不再停在启动图 ([47dd812](https://github.com/chenshi221/ark_novel/commit/47dd8125bb2bd4aec1a9d08c885f3c4b16a60112))
* 存坏的缓存章节当作没缓存，不会一直读失败 ([8a35af4](https://github.com/chenshi221/ark_novel/commit/8a35af4746eff5345908a44e099a4e2b25254fa7))
* 封面超分不再每次重建 Activity 都多一个线程，用完的 Bitmap 及时释放 ([2640c1a](https://github.com/chenshi221/ark_novel/commit/2640c1ad73a764d9e33634d35c36ab4cbc47ce78))
* 恢复备份不再带走同步设备 ID，恢复来的统计记到原设备名下 ([c444d67](https://github.com/chenshi221/ark_novel/commit/c444d671f04259a8aa545f2b100bb5d1f5c9c440))
* 拖动字号、行距、页边距滑块时松手才重新排版 ([dfbd7d8](https://github.com/chenshi221/ark_novel/commit/dfbd7d875cb1049e866736088a2d4ec3d6a7a7b8))
* 改字号、转屏后阅读位置不再往前漂 ([3688ec6](https://github.com/chenshi221/ark_novel/commit/3688ec6497b373b419e99f89157ffe5d3b16103a))
* 朗读遇到纯插图章、引擎出错和暂停时不再卡住，熄屏朗读也保存进度 ([ae61984](https://github.com/chenshi221/ark_novel/commit/ae619840a3f2a2b580da572c518a4e8350f52b78))
* 桌面小组件数据不对时不再让 App 崩溃，封面放到后台解码 ([a5b8557](https://github.com/chenshi221/ark_novel/commit/a5b85571118e68cdb51ad2317610bf1e20f2062f))
* 继续阅读条换书后不再累积旧封面的取色订阅 ([63c8e4b](https://github.com/chenshi221/ark_novel/commit/63c8e4b3416b867b7a410a20bf1b4c6a12825857))
* 缓存图片的文件被清理后补写，下载期间清空缓存目录也不失败 ([e585eaf](https://github.com/chenshi221/ark_novel/commit/e585eaf6433d2b43021ec9546d67a0765f07e1f0))
* 网站书架同步遇到书架重建时不再用过时的数据 ([d3d5b67](https://github.com/chenshi221/ark_novel/commit/d3d5b6725cb96c0dc0f0cb509480a3644f8fd594))
* 设置面板、目录开着时音量键不在下面翻页 ([00d24c4](https://github.com/chenshi221/ark_novel/commit/00d24c4a4e68980d90db6d3ad343ebc385475bd6))
* 设置页切换系统网络栈后页面已关闭时不再 setState，阅读页路由参数类型不对时不崩溃 ([d26f3d0](https://github.com/chenshi221/ark_novel/commit/d26f3d003e774ae27472b3a994d61990b71b295a))
* 详情页请求期间退出或书架重建后不再用失效的 ref ([d3b3304](https://github.com/chenshi221/ark_novel/commit/d3b33041abee527c85a1836cb4e18791f8163a44))
* 阅读器朗读状态、重排位置和书签面板的修复 ([fb09cc9](https://github.com/chenshi221/ark_novel/commit/fb09cc9b8ab56ac410fa02b980bf406862edc24d))
* 页面解析、离线缓存和图片缓存的修复 ([2babb0b](https://github.com/chenshi221/ark_novel/commit/2babb0b73c5a5fc6effbff22f8ee9a38c2e1511a))
* 首页推荐、热度、回复 uid 和封面地址的解析更稳妥 ([e783e36](https://github.com/chenshi221/ark_novel/commit/e783e367c830b305bd1616f71244e598ca7779fb))
* 高亮备注弹窗关闭后释放输入框控制器 ([ea99fb3](https://github.com/chenshi221/ark_novel/commit/ea99fb37d68f7660c35f72a50f9fd433310ffe90))
* 鼠标竖向拖动不再触发下拉加书签 ([8d877a0](https://github.com/chenshi221/ark_novel/commit/8d877a054d1b2a082e0fd6226fa9b00b22887d4d))

## [1.0.2](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.1...ark_novel-v1.0.2) (2026-11-03)


### Features

* 同步移出的书在本机读过时提示加回书架 ([edbe6c5](https://github.com/chenshi221/ark_novel/commit/edbe6c51ff2a4cdae09ae49876c59b713a19faa1))
* 同步移出的书在本机读过时提示加回书架 ([ea3d8dc](https://github.com/chenshi221/ark_novel/commit/ea3d8dca268af80aae829e3a99668d6bfc6493ab))

## [1.0.1](https://github.com/chenshi221/ark_novel/compare/ark_novel-v1.0.0...ark_novel-v1.0.1) (2026-11-03)


### Features

* 双页时页眉页脚一屏只显示一份：左页章节名和时间电量，右页页码进度 ([ad09453](https://github.com/chenshi221/ark_novel/commit/ad09453788de2ffb79293b44501d875ddb64a6f3))


### Bug Fixes

* 全本缓存默认关闭并逐章检查设置与 Wi-Fi，统计删除按日期同步 ([8b58ca5](https://github.com/chenshi221/ark_novel/commit/8b58ca53af200d7e64ec3f73b035027f41f5fcc5))
* 阅读器 code review 修复，双页页眉页脚一屏一份 ([09a6b3c](https://github.com/chenshi221/ark_novel/commit/09a6b3c65a177ec285d22566b6156b1a3becfe41))
