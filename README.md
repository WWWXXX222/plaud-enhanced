# Plaud 威力加强版 · Meeting Memory

原生 macOS 会议录音、实时字幕、转写、分析与知识库归档。**无需 Plaud 账户即可使用。**

## 安装与首次设置

适用 **Apple Silicon Mac、macOS 15 或更新版本**。0.11.0 是分享预览版。

1. 从 [Releases](https://github.com/WWWXXX222/plaud-enhanced/releases) 下载完整 App，解压后放进「应用程序」或 `~/Applications`。
2. 安装 Python 3 和 FFmpeg。已使用 Homebrew 的用户可运行 `brew install python ffmpeg`。
3. 安装并登录 [Codex CLI](https://developers.openai.com/codex/cli/) 或 [Claude Code](https://code.claude.com/docs/en/setup)。已有 CLI 登录可直接使用。
4. 打开 App，按首次设置选择分析工具、转写方式和知识库目录，再按需允许麦克风及系统音频权限。也可以先导入已有音频。

本预览包尚未完成 Apple 公证；macOS 可能阻止首次打开。仅在确认下载来自本仓库后，使用系统「隐私与安全性」提供的“仍要打开”；不要关闭系统整体安全保护。也可以按下面步骤自行构建。

无需另注册一个 App 账户。**离线转写和本机 CLI 分析不是同一件事**：字幕与离线转写不需要 API Key；Codex / Claude 的模型分析通常需要联网并使用各自账户的额度。OpenAI 云端转写是可选项，Key 仅存放在本机钥匙串。不会共享发布者的登录、Key 或知识库。

首次设置可从「设置 → 首次设置 · 账户、处理方式与知识库」重新打开。已产生归档后不在引导中迁移知识库，以免中断任务或错配已有记录。

## 会议流程

- 默认：本机双路录音 → WhisperKit 离线转写 → Codex 或 Claude 分析 → 所选知识库。
- 可选：上传到自己的 Plaud；最终转写可选本机、OpenAI 或 Plaud。
- 实时字幕默认离线，可以暂停、切换联网字幕、回看最近几分钟。
- 支持背景、截图粘贴及原图复制、文件附件和文档链接。
- “分析与归档”位于第二个标签页。打开已完成分析的会议，默认显示完整 Markdown 结果。
- 先检索知识库相关历史正文，再按层次分析判断、依据、取舍和建议。新知识库没有历史记录时明确说明。
- 中英文保留原文；身份不确定的说话人保持待确认。支持会内手动标注姓名，不做自动声纹身份识别。

默认会后自动处理。分段转写缓存、稳定会议 ID、文件锁、输出核验和指数退避共同避免并发重复处理。应用运行时恢复未完成任务；首次设置后安装本机每 30 分钟的故障恢复检查。空闲检查不调用模型。网络、权限、账户额度或外部服务故障仍可能需要用户处理，界面会保留当前状态和进度。

“复制分析并打开 Codex / Claude”用于继续讨论；不会自动往已有聊天发消息，不会自动打开网页。

## 可选 Plaud

不使用 Plaud 可以跳过本节。云端上传在 App 内连接账户。读取 Plaud 历史录音和转写还需要 Node.js 与官方 CLI：

```sh
brew install node
npm install --prefix "$HOME/Library/Application Support/MeetingMemory/vendor" @plaud-ai/cli@0.3.15
```

Plaud 网页和 CLI 依赖上游兼容性；本机录音会先保存，上传失败不会删除录音。纯本机路线不经过 Plaud。

## 数据位置与范围

- 应用资料：`~/Library/Application Support/MeetingMemory/`。
- 录音、附件与进度：上述目录中的 `data/meetings/`。
- 知识库：首次设置选择的目录；默认是上述目录中的 `Vault/`。
- OpenAI Key：macOS 钥匙串。Codex / Claude 使用各自登录。

分析读取所选知识库和会议资料。开启云端服务后，相应文本或音频会由你选择的服务处理。本仓库和分发包不包含真实会议、截图、个人知识库、账户配置、密钥或私人聊天记录。

分析是辅助判断，转写可能有误；关键否定句、人物归属和决策应结合原音频核对。两种分析工具共用流程标准，结果不保证逐字或逐项相同。

## 从源码构建

需要 Xcode 命令行工具、Swift 6、Python 3、FFmpeg，以及首次下载模型和 Swift 依赖的网络访问。

```sh
git clone https://github.com/WWWXXX222/plaud-enhanced.git
cd plaud-enhanced
python3 tools/prepare_offline_model.py
python3 build.py --ad-hoc
open build
```

离线模型约 600 MB，构建时从公开模型仓库下载并校验；模型不提交到 Git。构建后的 App 包含模型和运行脚本，不依赖源码目录。FFmpeg、Python 与分析 CLI 由用户在本机安装。

拥有稳定 Apple 签名身份的维护者可运行 `python3 build.py`。`--development-root` 仅用于本机开发，不能作为分发包。不要把含该配置的包传给同事。现有安装升级应保持签名身份一致，以减少系统重复授权。

运行回归检查：

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

## 第三方与许可

WhisperKit 源码来自 Argmax，具体提交和许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。Whisper 模型及 tokenizer 在构建时获取。本应用源码尚未指定开源许可；仓库公开可见不代表第三方商用许可。第三方组件继续遵循各自许可。
