# PyTorch 项目初始化工具

一个 PowerShell 脚本，自动安装 `uv`、检测主机 CUDA 版本、初始化项目并配置 PyTorch 开发环境。

## 功能概述

1. **自动检测并安装 `uv`** — 未安装时通过官方脚本自动安装，无需手动配置
2. **自动检测主机 CUDA 版本** — 通过 `nvidia-smi` 识别主机支持的 CUDA 版本，并自动映射到对应的 PyTorch CUDA 版本
3. **初始化 uv 项目** — 使用 `uv init` 创建项目结构，自动生成 `pyproject.toml` 和 `.venv` 虚拟环境
4. **指定 Python 版本** — 可选指定 Python 版本（如 3.11、3.12）
5. **安装 PyTorch 生态包** — 根据检测到的 CUDA 版本安装 `torch`、`torchvision`，同时安装 `tensorboard` 及其他自定义包

## 使用前提

- Windows 系统
- PowerShell（建议以管理员身份运行）
- 需安装 NVIDIA 显卡驱动（用于 `nvidia-smi` 检测 CUDA 版本）
- 首次运行可能需要设置执行策略：
  ```powershell
  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
  ```

## 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `CudaVersion` | string | `""`（自动检测） | PyTorch CUDA 版本。**不指定时自动从 `nvidia-smi` 检测**，可选 `cu118`、`cu121`、`cu124`、`cu130` 等 |
| `ProjectPath` | string | `"."` | 项目目录路径，脚本将在此目录初始化项目 |
| `PythonVersion` | string | `""` | Python 版本号（如 `"3.11"`、`"3.12"`），为空时使用系统默认 |
| `Force` | switch | - | 如果项目目录已存在且非空，强制删除并重新创建 |
| `ExtraPackages` | string | `""` | 额外安装的 Python 包，逗号分隔（如 `"numpy,pandas,matplotlib"`） |
| `InstallCudaToolkit` | switch | - | 是否安装 NVIDIA CUDA Toolkit（含 `nvcc` 编译器），用于自己编写 CUDA 代码 |

## CUDA 版本自动检测

脚本运行时会自动调用 `nvidia-smi` 获取主机 CUDA 版本，并按下表映射到对应的 PyTorch CUDA 包版本：

| 主机 CUDA 版本 | PyTorch CUDA 版本 |
|----------------|-------------------|
| 13.0 | cu130 |
| 12.8 | cu128 |
| 12.6 | cu126 |
| 12.4 | cu124 |
| 12.1 | cu121 |
| 11.8 | cu118 |
| 11.7 | cu117 |

- 如果 `nvidia-smi` 报告的版本**未在映射表中**，脚本会自动向下兼容到最近的 PyTorch 支持版本
- 如果**未检测到 NVIDIA 显卡**或 `nvidia-smi` 不可用，将安装 **CPU 版本的 PyTorch**（使用 `https://download.pytorch.org/whl/cpu`）

## 使用示例

### 基础用法（自动检测 CUDA）

在当前目录初始化项目，自动检测 CUDA 版本并安装对应 PyTorch：

```powershell
.\init_pytorch_project.ps1
```

有 NVIDIA 显卡时输出示例：
```
===== 检测 CUDA 版本 =====
检测到 NVIDIA 驱动版本: 535.129.03
检测到主机 CUDA 版本: 12.2
将使用 PyTorch CUDA 版本: cu121
```

无 NVIDIA 显卡时输出示例：
```
===== 检测 CUDA 版本 =====
未检测到 NVIDIA 显卡或 CUDA 信息，将安装 CPU 版本 PyTorch
```

### 指定项目路径和 Python 版本

在 `D:\ml_project` 中初始化，使用 Python 3.12，自动检测 CUDA：

```powershell
.\init_pytorch_project.ps1 -ProjectPath "D:\ml_project" -PythonVersion "3.12"
```

### 手动指定 CUDA 版本

覆盖自动检测结果，强制使用 CUDA 12.4：

```powershell
.\init_pytorch_project.ps1 -CudaVersion cu124
```

### 完整参数示例

指定所有参数，包括额外安装 `scipy`、`scikit-learn`：

```powershell
.\init_pytorch_project.ps1 -ProjectPath "D:\ml_project" -PythonVersion "3.12" -CudaVersion cu124 -ExtraPackages "scipy,scikit-learn"
```

### 强制重建已有项目

如果项目目录已存在且需要重新初始化：

```powershell
.\init_pytorch_project.ps1 -ProjectPath "D:\ml_project" -Force
```

### 安装 CUDA Toolkit（含 nvcc 编译器）

如果你自己写 CUDA 代码（需要 `nvcc` 编译 `.cu` 文件），使用 `-InstallCudaToolkit`：

```powershell
.\init_pytorch_project.ps1 -InstallCudaToolkit
```

脚本会按优先级尝试以下方式安装：

1. **自动检测 winget** — 如果不可用，尝试通过 PowerShell 自动恢复
2. **winget 安装** — `winget install -e --id Nvidia.CUDA`（官方包 ID）
3. **手动下载** — 如果以上都失败，提供 NVIDIA 官方下载链接，引导手动安装

安装完成后自动：
- 将 `nvcc` 所在目录写入系统 `PATH`（Machine + User）
- 验证 `nvcc --version`

### 完整示例：开发环境

指定项目路径、CUDA 版本并安装 CUDA Toolkit：

```powershell
.\init_pytorch_project.ps1 -ProjectPath "D:\cuda_project" -CudaVersion cu124 -InstallCudaToolkit -ExtraPackages "scipy,numpy"
```

## 运行后项目结构

```
<ProjectPath>/
├── pyproject.toml      # uv 项目配置
├── .venv/              # Python 虚拟环境
│   └── Scripts/
│       └── Activate.ps1
└── ...                 # 其他 uv init 生成的项目文件
```

## 已安装的包

| 包名 | 说明 |
|------|------|
| `torch` | PyTorch 核心库 |
| `torchvision` | PyTorch 视觉工具包 |
| `tensorboard` | 可视化训练工具 |
| *(可选)* | 通过 `-ExtraPackages` 指定 |

**额外工具：**
- `nvcc` — CUDA 编译器（启用 `-InstallCudaToolkit` 时安装）

## 安装后的使用

**激活虚拟环境：**

```powershell
.\<ProjectPath>\.venv\Scripts\Activate.ps1
```

**验证 nvcc 是否可用：**

```powershell
nvcc --version
```

**编译 CUDA 代码：**

```powershell
nvcc -o my_cuda_app my_cuda_code.cu
```

**安装更多依赖：**

```powershell
uv add <package-name>
```

**运行 Python：**

```powershell
python
```

## 常见问题

### uv 未安装

脚本会自动通过 `https://astral.sh/uv/install.ps1` 安装 uv。如果自动安装失败，可手动前往 [uv 官方安装文档](https://docs.astral.sh/uv/getting-started/installation/) 安装。

### 执行策略报错

如果提示无法运行脚本，先执行：

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 未检测到 CUDA / nvidia-smi 报错

- 确认已安装 NVIDIA 显卡驱动
- 检查 `nvidia-smi` 是否能在终端正常运行
- 如果无 NVIDIA 显卡，脚本将自动安装 **CPU 版本 PyTorch**（无需指定 CUDA 版本）

### 自动映射的版本不理想

如果主机 CUDA 版本过高或过低，自动映射结果可能不是最优。手动指定版本即可覆盖：

```powershell
.\init_pytorch_project.ps1 -CudaVersion cu124
```

### CUDA Toolkit 安装失败

- **winget 不可用**：Windows 10/11 自带 winget。确认是否在 PATH 中，或手动安装：[https://aka.ms/getwinget](https://aka.ms/getwinget)
- **winget 安装失败**：脚本会自动降级到手动下载模式，提供 NVIDIA 官方链接
- **手动下载**：[https://developer.nvidia.com/cuda-downloads](https://developer.nvidia.com/cuda-downloads) — 选择 Windows > Host > exe(local) > 对应架构
- 包 ID 为 `Nvidia.CUDA`（不是 `NVIDIACUDA`）

### winget 不可用

- Windows 10 1809+ 和 Windows 11 自带 winget
- 确认是否在 PATH 中：运行 `winget --version`
- 如果找不到，手动安装：[https://aka.ms/getwinget](https://aka.ms/getwinget)
- 脚本会在安装 CUDA Toolkit 时自动检测并尝试恢复 winget

### 环境变量未生效

脚本会在安装完成后自动将 CUDA `bin` 目录写入系统环境变量（Machine + User）。如果仍提示 `nvcc 不是命令`，可以：

- 重启 PowerShell 终端
- 或手动将以下路径添加到系统 PATH：`C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\vXX.X\bin`

## 许可证

MIT
