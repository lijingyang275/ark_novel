# Changelog

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
