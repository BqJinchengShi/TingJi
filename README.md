# 听记 (TingJi)

macOS 会议录音转写 App。录制系统音频 + 麦克风（或上传音频），自动转写成**带说话人区分和时间戳**的字幕文本。

<img width="2422" height="1324" alt="image" src="https://github.com/user-attachments/assets/ea144f7b-1d81-48aa-b6c5-cc48d51b4c66" />


## 使用场景

- **线上会议**：腾讯会议 / Zoom / 飞书等。系统音频录线上人声，麦克风录你说话，转写后区分说话人。
- **线下 + 线上混合会议**：线下多人（麦克风）+ 线上多人（系统音频），分别转写后按说话人合并成一份纪要。
- **直播 / 播客**：录制直播声音转文字。
- **本地音频转写**：上传已有音频文件（mp3/wav）转写。

## 工作原理

```
录音(系统音频+麦克风) -> 分别上传 TOS -> 火山引擎 ASR 识别(说话人分离) -> 按时间合并 -> 字幕输出
```

**为什么分系统音频和麦克风两路？** 同一个人不会同时出现在麦克风和系统音频里（你说话进麦克风，别人说话进系统音频）。所以按「来源 + ASR 说话人分离」能可靠区分不同人，输出 说话人1/2/3。

---

## 配置（首次使用必读）

App 需要配置两类凭据。打开 App -> 菜单栏图标 ->「显示主窗口」-> 顶部「设置」（或快捷键 `Cmd,`）-> 填字段 -> 保存。

### 1. ASR 语音识别（火山引擎豆包大模型录音文件识别 2.0）

**为什么要配置**：转写用的是火山引擎「大模型录音文件识别 2.0」服务，要鉴权才能调用。

**如何获取**：
1. 登录 [火山引擎控制台](https://console.volcengine.com)
2. 开通「语音技术」->「豆包录音文件识别模型 2.0」
3. 获取鉴权凭据（二选一）：
   - **旧版控制台**：`DOUBAO_APP_ID` + `DOUBAO_ACCESS_TOKEN`
   - **新版控制台**：`DOUBAO_API_KEY`（语音技术 -> API Key 管理）

### 2. TOS 对象存储（音频上传）

**为什么要配置**：ASR 要求音频是**公网 URL**（不支持直接传文件）。所以要把录音上传到 TOS 桶，拿 URL 给 ASR 下载。

**如何获取**：
1. 开通「对象存储 TOS」，创建一个桶（如 `your-bucket`）
2. 获取 AK/SK：控制台右上角头像 ->「访问密钥」-> 新建 Access Key
   - 得到 `TOS_AK`（AKLT 开头）+ `TOS_SK`（⚠️ 只显示一次，立刻复制保存）
3. 记下桶的区域和 endpoint：
   - 华北2-北京：`TOS_REGION=cn-beijing`，`TOS_ENDPOINT=tos-cn-beijing.volces.com`
   - 华东2-上海：`cn-shanghai` / `tos-cn-shanghai.volces.com`
   - 华南1-广州：`cn-guangzhou` / `tos-cn-guangzhou.volces.com`

### 配置字段一览

| 字段 | 说明 | 示例 |
|---|---|---|
| `DOUBAO_APP_ID` | ASR 旧版 APP ID | `your-app-id` |
| `DOUBAO_ACCESS_TOKEN` | ASR 旧版 Access Token | |
| `DOUBAO_API_KEY` | ASR 新版 API Key（与上面二选一）| |
| `TOS_AK` | TOS Access Key | `AKLT...` |
| `TOS_SK` | TOS Secret Key | |
| `TOS_BUCKET` | TOS 桶名 | `your-bucket` |
| `TOS_REGION` | 区域 | `cn-beijing` |
| `TOS_ENDPOINT` | endpoint（不带桶名）| `tos-cn-beijing.volces.com` |
| `TRANSCRIPT_SAVE_PATH` | 转写文本额外保存目录（可选，留空不额外保存）| `~/Documents/会议转写` |

> 密钥存在 `~/Library/Application Support/DoubaoRecorder/config.json`，本地权限保护，不会上传。开源分发时该文件不提交。

---

## 使用方法

### 录音转写
1. 点「**录音**」按钮 -> 首次弹「屏幕录制」「系统音频」「麦克风」权限，去系统设置授权给听记
2. 边播会议/直播边说话（系统音频录线上/播放声，麦克风录你说话）
3. 点「**停止**」-> 自动上传 + 转写，列表出现这条录音
4. 点卡片操作：▶️ 播放/⏸ 暂停（带进度条、空格键切换）/ ⬇️ 下载音频 / 📄 查看 txt / ✏️ 改名 / 🗑 删除

### 上传音频转写
- 点「**上传音频**」-> 选本地 mp3/wav -> 自动上传 TOS + 转写
- **不耽误录音**：上传转写异步进行，同时可继续录音

### 改名
- 点 ✏️ 改标题 -> **TOS 桶文件名**和**自定义路径 txt** 同步改名（如改成「周会」则桶里文件变 `周会.mp3`，txt 变 `周会.txt`）

### 说话人替换
- 转写结果里「说话人1/2/3」可点击重命名（如改成「张三」），回车或失焦后本地 txt、自定义路径 txt 同步更新
- 「下一个未替换 ⏭」按钮自动跳到下一个未命名的说话人

### 转写文本保存
- 设置里配「转写文本保存路径」
- 每次转写完，自动把 txt 复制到该目录（按标题命名），方便归档/分享

### 输出格式（字幕）
```
说话人1 10:07:49
把这个陪练用在了这个考核的场景下。

说话人2 10:07:54
Hello World。
```
时间戳是录音开始的真实东八区时间。

### 菜单栏 & 快捷键
- 菜单栏常驻图标（录音中变红点，转写中变波形）
- 全局快捷键发起/停止录音（默认 `⌘⇧R`，可在设置里自定义）
- 空格键暂停/继续播放（输入框激活时不响应）

---

## 构建（开发者）

```bash
./build.sh
# 产物：.build/TingJi.app（GUI）+ .build/tingji-cli（CLI）+ .build/听记.dmg（安装包）
open .build/TingJi.app
```

**环境要求**：macOS 14+、Xcode 或 Command Line Tools、ffmpeg（转 mp3，`brew install ffmpeg`）。

构建方式：裸 `swiftc`（绕过 SPM 链接问题），脚本同时编译 GUI App（`.app` bundle + Info.plist + 自签名）和 CLI，并生成 DMG 安装包。

### 保留的 CLI

`tingji-cli` 命令行仍可用，供脚本/自动化：
```bash
.build/tingji-cli 30            # 录 30 秒并转写
.build/tingji-cli record 60     # 仅录音
.build/tingji-cli transcribe <dir>  # 转写已有录音目录
```

## 权限说明

| 权限 | 用途 |
|---|---|
| 屏幕录制 | ScreenCaptureKit 录系统音频需要（仅音频，不录屏）|
| 系统音频 | macOS 14.2+ 录系统音频的单独权限 |
| 麦克风 | 录麦克风 |

首次录音会弹权限，去「系统设置 -> 隐私与安全」授权给听记。

> ⚠️ **开发阶段注意**：每次重新编译 `.app`，签名会变，macOS 权限可能失效，需重新授权。用稳定证书签名（见 `build.sh` 的 `TingJiSign`）可缓解。

## 限制与注意

- 长录音无 ffmpeg 时未自动分段（装 ffmpeg 即可，mp3 单文件 5h≈144MB，远低于 ASR 512M 上限）。
- ASR 对短音频 / 纯音乐可能判静音（波动）；真实人声会议稳定。
- 说话人分离按声音特征 + 来源区分，同一来源内多人由 ASR 自动分（1/2/3）。
- TOS V4 签名为纯 Swift 实现，首次使用若 403 核对 AK/SK/region/endpoint。

## License

MIT，见 [LICENSE](LICENSE)。
