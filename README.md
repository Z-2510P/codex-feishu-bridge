# Codex Feishu Bridge

在 Windows 上把 Codex Desktop 任务完成通知、最终回复和图片发送到飞书，并允许从飞书手机端继续指定的 Codex 对话。

## 功能

- 电脑端任意 Codex 对话结束后，全局推送标题、项目、匿名对话码和最终回复。
- 通过 `/list`、`/use CODE` 或 `#CODE 消息` 路由多个 Codex 对话。
- 从飞书发送文字或图片到 Codex，并把最终回复与明确引用的图片发回飞书。
- 飞书先发图片、再发文字时自动合并；60 秒内没有说明则自动分析图片。
- 使用 WebSocket 长连接，无需公网服务器或家庭网络端口映射。
- App Secret 使用 Windows DPAPI `CurrentUser` 加密保存。
- 飞书来源任务只返回一次最终结果，不显示“已编辑”。

## 要求

- Windows 10/11
- Codex Desktop，且本机可使用 `codex.exe`
- Node.js 22 或更高版本
- 飞书企业自建应用

## 飞书配置

为应用添加“机器人”能力，并开通以下**应用身份权限**：

| 权限名称 | 权限标识 |
| --- | --- |
| 读取用户发给机器人的单聊消息 | `im:message.p2p_msg:readonly` |
| 获取单聊、群组消息 | `im:message:readonly` |
| 以应用的身份发消息 | `im:message:send_as_bot` |
| 获取与上传图片或文件资源 | `im:resource` |
| 更新消息 | `im:message:update`（仅兼容旧版本进度消息，可选） |

在“事件与回调”中选择长连接，订阅应用身份事件 `im.message.receive_v1`，然后创建并发布应用版本。建议把应用可用范围限制为自己。

## 安装

```powershell
git clone https://github.com/Z-2510P/codex-feishu-bridge.git
cd codex-feishu-bridge
./Install.ps1
```

安装器会隐藏读取 App Secret、安装依赖、合并用户级 Codex `Stop` Hook、注册登录自启动并生成一次性配对码。它不会修改 Codex 的 `notify` 配置，也不会覆盖其他 Hook。

重启 Codex 后使用 `/hooks` 审查并信任新增命令。随后在飞书机器人单聊中发送安装器显示的 `/pair XXXXXXXX`。

## 使用

```text
/list
/use A72F19C304
/status
/help
#A72F19C304 继续完成这个任务
```

发送图片时，机器人会暂存图片 60 秒。随后发送的普通文字会成为图片说明并与图片一起交给 Codex；不发送文字则自动使用“请分析我从飞书发送的图片”。命令不会消耗暂存图片。

## 管理

```powershell
$manager = "$env:USERPROFILE\.codex\mobile-notifier\bridge\CodexFeishuBridge.ps1"
& $manager -Action Status
& $manager -Action Stop
& $manager -Action Start
& $manager -Action Pair
& $manager -Action Uninstall
```

运行数据位于 `%LOCALAPPDATA%\CodexFeishuBridge`。卸载时默认保留加密凭证、日志和队列；使用 `-RemoveData` 才会删除数据。

## 隐私边界

- 不读取或上传 OpenAI API Key。
- `/list` 只保存标题、项目目录最后一级、时间和匿名对话码。
- 不向飞书同步完整历史、工具输出或未明确引用的本机文件。
- 图片每轮最多 4 张、每张最多 10 MB，并校验 PNG、JPEG、GIF 或 WebP 文件签名。
- 出站图片仅允许来自当前工作目录或 Codex visualizations 目录。
- 只接受完成本机一次性配对的飞书用户，且拒绝群聊消息。

## 测试

```powershell
npm ci --prefix ./bridge
npm test --prefix ./bridge
./tests/Run-Tests.ps1
./bridge/tests/Run-PowerShellTests.ps1
```

## License

[MIT](LICENSE)
