# FlashCat HarmonyOS SDK 离线接入指南（HAR 包）

**版本:0.3.1** · 适用于尚未从 OHPM 公网仓库安装的场景(仓库审核未通过、客户纯内网环境)。

本包中的 4 个 HAR 与发布到 OHPM 的产物**由同一份源码、同一条构建命令产出**,并通过了 `ohpm prepublish` 校验。等 OHPM 审核通过后,可以零改动地切回公网依赖(见文末「切回 OHPM」)。

---

## 1. 包内容

```
flashcat-harmony-sdk-0.3.1-offline/
├── README.md              # 本文档
├── SHA256SUMS.txt         # 校验和
└── libs/
    ├── flashcat_core.har   # @flashcatcloud/core@0.3.1   (必需)
    ├── flashcat_rum.har    # @flashcatcloud/rum@0.3.1    (RUM:视图/操作/资源/错误/会话)
    ├── flashcat_trace.har  # @flashcatcloud/trace@0.3.1  (W3C traceparent 链路透传)
    └── flashcat_crash.har  # @flashcatcloud/crash@0.3.1  (崩溃/卡死上报)
```

`core` 是其余三个包的公共依赖,**必须随包一起引入**,即使你只用 RUM。

收到后先校验完整性:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## 2. 环境要求

| 项 | 要求 |
| --- | --- |
| 目标平台 | HarmonyOS NEXT |
| compatibleSdkVersion | 5.0.0(12) 及以上 |
| 开发工具 | DevEco Studio(内置 ohpm 5.0+ / hvigor 5.0+) |
| 网络 | **无需连接 OHPM 公网仓库**(按本文配置后) |

## 3. 接入步骤

### 步骤 1:放置 HAR 文件

把 `libs/` 整个目录复制到**工程根目录**下:

```
your-app/
├── build-profile.json5
├── oh-package.json5          # ← 步骤 3 改这里
├── libs/                     # ← 放这里
│   ├── flashcat_core.har
│   ├── flashcat_rum.har
│   ├── flashcat_trace.har
│   └── flashcat_crash.har
└── entry/
    └── oh-package.json5      # ← 步骤 2 改这里
```

> 建议放工程根目录而不是 `entry/libs/`,这样步骤 2、3 两处的相对路径最简单、最不容易写错。

### 步骤 2:在业务模块声明依赖

编辑 `entry/oh-package.json5`(如果你在多个模块里用 SDK,每个模块都要加):

```json5
{
  name: "entry",
  version: "1.0.0",
  dependencies: {
    "@flashcatcloud/core":  "file:../libs/flashcat_core.har",
    "@flashcatcloud/rum":   "file:../libs/flashcat_rum.har",
    "@flashcatcloud/trace": "file:../libs/flashcat_trace.har",
    "@flashcatcloud/crash": "file:../libs/flashcat_crash.har"
  }
}
```

只需要 RUM 的话,可以只留 `core` + `rum` 两行。

### 步骤 3:在工程根加 `overrides`(这一步不能省)

编辑**工程根目录**的 `oh-package.json5`,加上 `overrides` 字段:

```json5
{
  modelVersion: "5.0.0",
  name: "your-app",
  version: "1.0.0",
  dependencies: {},
  overrides: {
    "@flashcatcloud/core": "file:./libs/flashcat_core.har"
  }
}
```

> ⚠️ **为什么必须加这一行**
>
> `rum` / `trace` / `crash` 三个包的内部清单里写死了 `"@flashcatcloud/core": "0.3.1"` —— 这是一个**仓库版本号**,不是本地路径。
> 只在步骤 2 里声明 `file:` 依赖是不够的:ohpm 解析这三个包的传递依赖时,仍然会去公网 OHPM 拉取 `@flashcatcloud/core`,在内网环境下直接报 `ECONNREFUSED` 安装失败。
>
> `overrides` 的作用就是把这个传递依赖也强制指向本地 HAR,让整条依赖链完全不出网。
>
> 注意路径基准不同:根 `oh-package.json5` 里是 `./libs/...`,`entry/oh-package.json5` 里是 `../libs/...`。

### 步骤 4:安装

在工程根目录执行:

```bash
ohpm install
```

预期输出 `install completed`,且日志中**不应出现**任何 `MetaDataFetcher fetching meta info of package '@flashcatcloud/...'`。若出现,说明步骤 3 的 `overrides` 没生效。

验证解析结果。锁文件是**按模块**生成的,在声明依赖的那个模块目录下:

```bash
grep -A3 '@flashcatcloud' entry/oh-package-lock.json5
```

四个包都应显示 `"version": "0.3.1"` 与 `"registryType": "local"`。

## 4. 初始化代码

在 `AbilityStage.onCreate()` 中初始化一次(整个进程只初始化一次)。

```typescript
import { Flashcat, ConfigurationBuilder, FlashcatSite, TrackingConsent } from '@flashcatcloud/core';
import { FlashcatRum, RumConfigurationBuilder } from '@flashcatcloud/rum';
import { FlashcatTrace, TraceConfigurationBuilder } from '@flashcatcloud/trace';
import { FlashcatCrash, CrashConfigurationBuilder } from '@flashcatcloud/crash';

export default class MyAbilityStage extends AbilityStage {
  onCreate(): void {
    // 1) 初始化内核
    Flashcat.initialize(
      this.context,
      new ConfigurationBuilder('<CLIENT_TOKEN>', 'prod')
        .setService('<SERVICE_NAME>')
        .useSite(FlashcatSite.CN)
        .build(),
      TrackingConsent.GRANTED
    );

    // 2) 开启 RUM
    FlashcatRum.enable(new RumConfigurationBuilder('<APPLICATION_ID>')
      .setSessionSampleRate(100)
      .setTrackUserInteractions(true)
      .setTrackNavigation(true)
      .setTrackNetworkRequests(true)
      .setTrackErrors(true)
      .build());

    // 3) 可选:链路透传与崩溃上报
    FlashcatTrace.enable(new TraceConfigurationBuilder().setSampleRate(100).build());
    FlashcatCrash.enable(new CrashConfigurationBuilder().build());
  }
}
```

`<CLIENT_TOKEN>` 和 `<APPLICATION_ID>` 在 FlashCat 控制台的 RUM 应用管理页获取。

### 私有化部署:指向自建 intake

如果 FlashCat 是私有化部署,数据不应发往公网站点,用 `setCustomEndpoint` 覆盖:

```typescript
new ConfigurationBuilder('<CLIENT_TOKEN>', 'prod')
  .setService('<SERVICE_NAME>')
  .setCustomEndpoint('https://rum-intake.your-intranet.com')  // 覆盖 useSite 的站点
  .build()
```

## 5. 验证接入成功

开发期把 `.setVerbose(true)` 加到 `ConfigurationBuilder` 上,SDK 会打印内部日志:

```bash
hdc shell hilog | grep Flashcat
```

然后:

1. 启动 App,手动触发一个视图:`FlashcatRum.startView('home', 'Home')`;
2. 等待一个上报批次(默认批量上传,可用 `.setBatchUploadFrequencyMs(2000)` 在调试期加快);
3. 在 FlashCat 控制台 RUM 页面按 `service` 过滤,应能看到会话与视图数据。

**注意采集范围**(容易误判为「没数据」):

- 网络资源需要 `setTrackNetworkRequests(true)` **并且**走 `FlashcatTrace.interceptor()`、`FlashcatHttp.request` 包装,或手动 `startResource`/`stopResource`。裸用 `@ohos.net.http` 不会被自动采集。
- 视图自动采集(`setTrackNavigation(true)`)只覆盖 `router` 路由;使用 `Navigation` / `NavDestination` 的应用需要手动上报视图。
- 点击采集是半自动的:需要用 `FlashcatRum.trackTap(...)` 包装点击回调。

## 6. 常见问题

**Q:`ohpm install` 报 `ECONNREFUSED` / 一直在拉 `@flashcatcloud/core`**
根 `oh-package.json5` 的 `overrides` 没配或路径写错。检查步骤 3,注意根目录用 `./libs/`,模块目录用 `../libs/`。

**Q:改了 HAR 文件但没生效**
删除缓存后重装:

```bash
rm -rf oh_modules entry/oh_modules entry/oh-package-lock.json5 && ohpm install
```

**Q:上报数据里的 SDK 版本不对**
以 `entry/oh-package-lock.json5` 里解析到的版本为准。混用不同版本的 4 个 HAR 是不支持的,四个包必须同版本。

**Q:符号文件(sourcemap / so 符号)上传怎么办**
符号上传插件 `@flashcatcloud/hvigor-plugin` 发布在 **npm**,不走 OHPM,不受 OHPM 审核影响。配置在 `hvigor/hvigor-config.json5` 的 `dependencies` 里(注意不是 `ohpm install`)。若客户 npm 也不通,可另外索取该插件的离线 tarball。

## 7. 切回 OHPM 正式依赖

OHPM 审核通过后,把本地路径换成版本号即可,代码无需改动:

```json5
// entry/oh-package.json5
dependencies: {
  "@flashcatcloud/core":  "^0.3.1",
  "@flashcatcloud/rum":   "^0.3.1",
  "@flashcatcloud/trace": "^0.3.1",
  "@flashcatcloud/crash": "^0.3.1"
}

// 工程根 oh-package.json5 —— overrides 可以整段删除,
// 或同步改成版本号(多模块工程建议保留以锁定 core 版本):
overrides: {
  "@flashcatcloud/core": "^0.3.1"
}
```

然后 `rm -rf oh_modules entry/oh_modules entry/oh-package-lock.json5 && ohpm install`,并删除 `libs/` 下的 HAR 文件。

---

技术支持:如遇接入问题,请附上 `ohpm install` 完整日志与 `oh-package-lock.json5` 联系 FlashCat 技术支持。
