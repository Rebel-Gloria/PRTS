# PRTS 代码、仓库与提交规范

本文件适用于本仓库的开发者和自动化工具。修改前阅读相关模块文档，遵循现有结构；用户在当前任务中明确提出的要求优先于本文件。

## 代码规范

- 按职责组织代码，沿用所在文件的命名、缩进和错误处理方式。Swift 使用四空格缩进，类型使用 `UpperCamelCase`，函数、属性和变量使用 `lowerCamelCase`。
- 一次改动围绕一个明确目的，避免夹带无关重构、批量格式化、依赖升级和生成文件变化。
- 优先使用现有组件。抽象应解决实际重复或边界问题，不提前添加未使用的接口、配置和兼容层。
- 注释说明约束、原因和取舍，不重复代码字面含义。行为变化时同步更新相关注释、测试和文档。
- 保持 iOS 17 兼容性；使用更高版本 API 时提供可用性判断和必要的回退实现。
- 异步任务必须处理取消和生命周期变化，防止过期结果更新当前界面、继续播报或恢复已经停止的功能。
- 界面文字与权限说明使用现有本地化目录，维护中英文内容。用户可见文案遵循 [文案规范](docs/features/copy-guidelines.md)，交互改动兼顾 VoiceOver、动态字体和替代操作方式。

## 工程边界

- `PRTS/` 保存 App 代码；`Vendor/SpatialCore/` 保存独立的空间算法；`Vendor/PRTSCore/` 保存后端契约与相关实现；`Vendor/LocalVLM/` 保存本地视觉模型的集成代码。
- 几何与路线判断放在 `SpatialCore`，新增或修改算法时先补充确定性测试。UI 和渲染层只消费结果，不自行判断可通行区域。
- 仅 `ProbeEngine` 持有 `ARSession`。其他功能复用当前帧；需要切换相机时，协调现有会话的停止与恢复。
- 渲染读取快照，语音和震动读取分析结果。隐藏画面或叠加层只改变显示，不隐式停止采集与分析。
- `Experiments/` 保存独立实验、回放和评测。实验结果需要经过验证才能进入产品实现，不将实验目录直接当作 App 编译范围。
- 开发采集功能受 `PRTS_DEV_CAPTURE` 编译条件约束。默认诊断不记录图像、音视频、密钥或模型请求正文。
- 详细职责与数据流见 [代码结构](docs/architecture/code-structure.md) 和 [运行时数据流](docs/architecture/runtime-data-flow.md)。

## 仓库与分支规范

- `main` 保存工程主体、测试、研发实验和工程文档。
- PPT、比赛讲稿、宣传视频及专用素材维护在 `marketing` 分支，使用 `Marketing/` 和 `docs/pitch/` 等对应目录。不得将宣传专用提交合并回 `main`。
- App 使用的图标、品牌原稿和资源仍属于工程主体，可留在 `main`；按实际用途判断归属，不按文件扩展名批量删除。
- `docs/` 保存工程说明，`scripts/` 保存开发与验证工具。新增内容优先放入现有职责目录，避免在根目录堆积临时脚本和报告。
- 密钥、访问令牌、私有凭据、构建缓存、下载的模型权重和生成的发布产物不得提交。新增生成流程时同步维护忽略规则，并记录可复现的准备方法。
- 保留第三方许可证和来源记录。更新 `Vendor/` 时说明来源、版本及必要的本地修改。
- 修改前检查工作区，保留已有的用户改动；提交前核对暂存区，确保只包含本次工作。
- 整理历史时保留可恢复的备份，核对受影响的分支及文件差异。需要覆盖已发布历史时，按任务授权范围操作，并使用带明确远端预期值的 `--force-with-lease`。

## 提交身份

- 本用户的提交使用 `Oldcucumber <65931553+Oldcucumber@users.noreply.github.com>`，借用设备时先核对仓库级 `user.name` 和 `user.email`。
- GitHub 登录账号与 Git 提交身份分别检查，不能以认证成功代替作者信息检查。
- 不把其他设备的用户名写入本用户的作者或提交者字段；不得擅自改写其他真实贡献者的署名。
- 不添加 Claude、Codex、GPT 等自动化工具的作者、共同作者或生成声明；不添加相应的 `Co-Authored-By` 等署名尾注。
- 实际功能涉及的模型或服务名称可以作为技术事实出现在说明中，但不能作为作者署名。

## 提交文本格式

所有新建或按任务要求整理的提交统一使用英文标题和英文正文，结构如下：

```text
Short imperative title

Concise factual sentences describing the changes.
```

### 标题

- 用简洁、具体的英文说明本次工作的主要目的，最多一句话。
- 使用动词原形开头，例如 `Add`、`Remove`、`Fix`、`Improve`、`Update`、`Rename` 或 `Refactor`。
- 首字母大写，末尾不加句号；尽量控制在 72 个字符以内。
- 不加 `feat:`、`fix:`、`chore:` 等分类前缀，不写 `Title:` 或“标题：”标签。
- 避免 `Update files`、`Misc changes` 等无法说明实际工作的标题。

### 正文

- 与标题之间空一行，以一个简洁的英文段落说明实际增加、移除、修复、改进、重命名或更新的内容。
- 每句话使用具体动作和对象，例如 `Add ...`、`Remove ...`、`Fix ...`、`Improve ...`。按本次工作的重点排列，不机械套用全部类别。
- 没有发生的改动不写；没有修复就不写修复，没有优化就不写优化，不使用空分类或 `None` 占位。
- 只描述该提交包含的改动。增加测试可以写 `Add tests for ...`；声称测试通过、性能提升或问题已修复时必须有相应验证依据。
- 不堆砌文件清单、对话记录、操作流水账和宣传性评价。仅在帮助理解改动时写出具体文件、接口、参数或限制。
- 正文不写 `Body:` 或“内容：”标签，不附加工具署名。

### 已确认的示例

```text
Improve photo question prompts and settings

Add dedicated cloud and local question prompts with a three-sentence response limit. Add an optional thinking toggle for cloud questions. Remove the previous question prefix. Rename “Service and API key” to “Intelligence settings”. Add tests for thinking controls and response limits, and update related documentation.
```

## 验证与交付

- 根据改动选择有针对性的检查。算法改动运行对应 Swift 包测试，必要时使用相同输入进行前后回放；交互和生命周期改动运行相关 App 测试，并说明需要真机确认的部分。
- Python 工具改动运行相关测试。完整脚本测试命令为 `python3 -m unittest discover -s scripts -p 'test_*.py'`。
- 在具备 Xcode 和所需模型依赖的 macOS 环境中，可运行 `bash scripts/validate_spatial.sh`，执行包测试、Python 测试及 App 编译。准备步骤见 [脚本说明](docs/guides/scripts.md)。
- 文档改动检查内容、链接和差异即可，不为纯文档改动编写与实现无关的测试。
- 提交前运行 `git diff --check`，检查暂存内容与提交文本是否一致。改写历史时额外验证作者、提交者、提交说明和文件树差异。
- 交付时说明改动结果、实际执行的验证及尚未验证的部分。缺少运行环境或设备时明确说明，不把未执行的检查报告为通过。
