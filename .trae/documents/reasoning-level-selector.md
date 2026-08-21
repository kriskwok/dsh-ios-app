# DeepSeek 推理强度选择器

## 交互方案

### 触发条件
- 仅当选中的模型 provider 为 DeepSeek 时，才在模型选择浮层底部显示「推理强度」区域
- 切换到非 DeepSeek 模型时，该区域自动隐藏

### 浮层布局
```
┌───────────────────────────────────┐
│  ✓ DeepSeek                        │  ← provider 分组（置顶）
│    DeepSeek-V4                ✓   │  ← 模型行
│    DeepSeek-R1                    │
│  Anthropic                        │
│    Claude 4 Sonnet                │
│                                   │
│  ─────────────────────────────    │  ← 分隔线
│  推理强度                          │  ← section header（仅 DeepSeek 选中时）
│    Off                            │
│    Low                            │
│    High                      ✓    │  ← 选中项蓝色对勾
│    Max                            │
└───────────────────────────────────┘
```

### 选项
- **Off** — 关闭推理
- **Low** — 低
- **High** — 高（默认）
- **Max** — 最高

选中项右侧显示蓝色 checkmark + semibold 文字，与现有模型选择行的选中样式一致。

### 底部按钮
模型选择按钮文字不变，仍显示模型名。推理强度信息不在按钮上额外展示，避免按钮过宽。

### 交互流程
1. 用户打开模型选择浮层
2. 选中 DeepSeek 模型后，浮层底部出现「推理强度」区域
3. 用户点击某个级别 → 调用 DSH API 设置推理强度
4. 选中后保持浮层打开（用户可能还想换模型），不自动关闭
5. 切换到非 DeepSeek 模型时，推理强度区域消失

### API 调用方式
- 推理强度作为 `session.selectModel` 的额外 payload 字段一起传
- 字段名推测为 `reasoningLevel`（值为 `"off"` / `"low"` / `"high"` / `"max"`），实际对接时按后端字段名调整
- `session.models` 响应中应包含当前推理强度（解析时读取）

### 选项语言
- 使用英文：Off / Low / High / Max

## 涉及文件

| 文件 | 改动 |
|------|------|
| `Models/AgentModel.swift` | 新增 `ReasoningLevel` 枚举；`AgentModelSelection` 增加 `reasoningLevel` 字段；`AgentModelCatalog` 增加 `currentReasoningLevel` 字段 |
| `Services/DSHAgentGateway.swift` | `fetchModels` 解析推理强度；`selectModel` payload 增加字段或新增 `setReasoningLevel` 方法 |
| `Models/AgentModels.swift` | `AgentGateway` 协议增加 `setReasoningLevel` 方法（可选） |
| `ViewModels/ChatSessionViewModel.swift` | 新增 `reasoningLevel` 状态和 `selectReasoningLevel` 方法 |
| `Views/ModelSelectorSheet.swift` | 浮层底部增加推理强度 section |
| `Views/ChatSessionView.swift` | 无需改动（浮层逻辑不变） |

## 验证
- 选中 DeepSeek 模型后浮层底部出现推理强度选项
- 切换到非 DeepSeek 模型后推理强度区域消失
- 选择推理强度后蓝色对勾正确移动
- 从后台恢复后推理强度状态保持
