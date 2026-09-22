<#
.SYNOPSIS
    自动安装 uv，初始化 uv 项目，并使用 uv 安装 PyTorch (CUDA)、torchvision、tensorboard 等。
.DESCRIPTION
    1. 检查 uv 命令是否可用，未安装则通过官方脚本安装（无需 Python）。
    2. 自动检测主机 CUDA 版本（通过 nvidia-smi），映射到对应的 PyTorch CUDA 版本。
    3. 使用 uv init 在指定目录下初始化项目（自动创建 .venv）。
    4. 激活虚拟环境。
    5. 在虚拟环境中安装 PyTorch 生态包及其他常用库。
.PARAMETER CudaVersion
    指定 CUDA 版本，可选。如果不指定，则自动检测主机 nvidia-smi 的 CUDA 版本并映射。
    可选值如 cu118、cu121、cu124、cu130 等。
.PARAMETER ProjectPath
    项目目录路径，默认为当前目录。uv init 将在此目录下初始化项目并创建 .venv。
.PARAMETER PythonVersion
    指定 Python 版本，可选，如 "3.11"、"3.12"。未指定时使用系统默认 Python。
.PARAMETER Force
    如果项目目录已存在，强制删除并重新创建。
.PARAMETER ExtraPackages
    需要额外安装的 Python 包名（逗号分隔），例如 "numpy,pandas,matplotlib"。
.PARAMETER InstallCudaToolkit
    是否安装 NVIDIA CUDA Toolkit（包含 nvcc 编译器）。未安装时 PyTorch 只带 CUDA runtime。
.EXAMPLE
    .\init_pytorch_project.ps1
    在当前目录初始化项目，自动检测 CUDA 版本并安装对应 PyTorch。
.EXAMPLE
    .\init_pytorch_project.ps1 -ProjectPath "D:\my_project" -PythonVersion "3.12" -ExtraPackages "scipy,scikit-learn"
    在 D:\my_project 初始化项目，自动检测 CUDA 版本，使用 Python 3.12，额外安装 scipy 和 scikit-learn。
.EXAMPLE
    .\init_pytorch_project.ps1 -CudaVersion cu124 -Force
    强制重建项目目录，指定 CUDA 12.4。
.EXAMPLE
    .\init_pytorch_project.ps1 -InstallCudaToolkit
    在当前目录初始化项目，自动检测 CUDA，同时安装 CUDA Toolkit（含 nvcc 编译器）。
.EXAMPLE
    .\init_pytorch_project.ps1 -ProjectPath "D:\cuda_dev" -CudaVersion cu124 -InstallCudaToolkit
    在 D:\cuda_dev 初始化项目，指定 CUDA 12.4，并安装 CUDA Toolkit。
.NOTES
    首次运行可能需要执行策略设置：
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

param(
    [string]$CudaVersion = "",

    [string]$ProjectPath = ".",

    [string]$PythonVersion = "",

    [switch]$Force,

    [string]$ExtraPackages = "",

    [switch]$InstallCudaToolkit
)

$ErrorActionPreference = "Stop"

# CUDA 版本映射表：nvidia-smi 报告的 CUDA 版本 → PyTorch wheel 后缀
# https://download.pytorch.org/whl/torch_stable.html
$cudaVersionMap = @{
    "13.0" = "cu130"
    "12.8" = "cu128"
    "12.6" = "cu126"
    "12.4" = "cu124"
    "12.1" = "cu121"
    "11.8" = "cu118"
    "11.7" = "cu117"
}

# 函数：检测主机的 CUDA 版本
function Get-HostCudaVersion {
    try {
        $nvidiaSmi = & nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $nvidiaSmi) {
            return $null
        }
        # nvidia-smi 输出驱动版本，格式如 "535.129.03"
        $driverVersion = $nvidiaSmi.Trim().Split()[0]
        Write-Host "检测到 NVIDIA 驱动版本: $driverVersion" -ForegroundColor Green

        # 尝试从 nvidia-smi 详细输出中获取 CUDA Version
        $nvidiaDetails = & nvidia-smi 2>&1
        $cudaLine = $nvidiaDetails | Select-String -Pattern "CUDA Version"
        if ($cudaLine) {
            # 匹配 "CUDA Version: 12.2"
            if ($cudaLine -match 'CUDA Version:\s*(\d+\.\d+)') {
                $detectedVersion = $matches[1]
                Write-Host "检测到主机 CUDA 版本: $detectedVersion" -ForegroundColor Green
                return $detectedVersion
            }
        }
        return $null
    }
    catch {
        Write-Host "未检测到 nvidia-smi 或无法获取 CUDA 信息（可能无 NVIDIA 显卡）" -ForegroundColor Yellow
        return $null
    }
}

# 函数：将主机 CUDA 版本映射为 PyTorch CUDA 版本
function Resolve-PyTorchCudaVersion {
    param([string]$hostCudaVersion)

    if (-not $hostCudaVersion) {
        return $null
    }

    # 直接匹配
    if ($cudaVersionMap.ContainsKey($hostCudaVersion)) {
        return $cudaVersionMap[$hostCudaVersion]
    }

    # 模糊匹配：向下兼容到最近的 PyTorch 支持版本
    $majorMinor = $hostCudaVersion.Split('.')[0..1] -join '.'
    if ($cudaVersionMap.ContainsKey($majorMinor)) {
        return $cudaVersionMap[$majorMinor]
    }

    # 尝试逐级向下查找最近的版本
    $cudaKeys = $cudaVersionMap.Keys | ForEach-Object { [version]$_ } | Sort-Object -Descending
    foreach ($key in $cudaKeys) {
        $keyStr = $key.ToString()
        if ([version]$hostCudaVersion -ge [version]$keyStr) {
            Write-Host "主机 CUDA $hostCudaVersion 无对应 PyTorch 包，降级使用 PyTorch CUDA $keyStr" -ForegroundColor Yellow
            return $cudaVersionMap[$keyStr]
        }
    }

    return $null
}

# === 主流程 ===

# 1. 检查并安装 uv
Write-Host "===== 检查 uv 状态 =====" -ForegroundColor Cyan
$uvCmd = Get-Command uv -ErrorAction SilentlyContinue

if (-not $uvCmd) {
    Write-Host "未检测到 uv，将通过官方脚本安装（无需 Python）..." -ForegroundColor Yellow
    try {
        $installScript = Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1"
        Invoke-Expression $installScript
    }
    catch {
        Write-Error "安装 uv 失败: $_"
        Write-Host "请尝试手动安装：https://docs.astral.sh/uv/getting-started/installation/" -ForegroundColor Red
        exit 1
    }

    # 刷新环境变量，使 uv 立即可用
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uvCmd) {
        Write-Error "安装后仍找不到 uv，请关闭并重新打开终端后再次运行本脚本。"
        exit 1
    }
    Write-Host "uv 安装成功！" -ForegroundColor Green
}
else {
    Write-Host "uv 已存在: $($uvCmd.Source)" -ForegroundColor Green
}

uv --version

$IsCpuMode = $false

# 2. 自动检测 CUDA 版本
Write-Host "`n===== 检测 CUDA 版本 =====" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($CudaVersion)) {
    $hostCuda = Get-HostCudaVersion
    if ($hostCuda) {
        $detectedPyTorchCuda = Resolve-PyTorchCudaVersion -hostCudaVersion $hostCuda
        if ($detectedPyTorchCuda) {
            $CudaVersion = $detectedPyTorchCuda
            Write-Host "将使用 PyTorch CUDA 版本: $CudaVersion" -ForegroundColor Green
        }
        else {
            Write-Host "无法映射主机 CUDA $hostCuda 到 PyTorch 包，降级使用 CPU 版本" -ForegroundColor Yellow
            $IsCpuMode = $true
        }
    }
    else {
        Write-Host "未检测到 NVIDIA 显卡或 CUDA 信息，将安装 CPU 版本 PyTorch" -ForegroundColor Yellow
        $IsCpuMode = $true
    }
}
else {
    Write-Host "使用指定的 CUDA 版本: $CudaVersion" -ForegroundColor Green
}

# 3. 初始化项目
Write-Host "`n===== 初始化项目 ($ProjectPath) =====" -ForegroundColor Cyan

if (Test-Path $ProjectPath) {
    if ((Get-ChildItem $ProjectPath).Count -gt 0) {
        if ($Force) {
            Write-Host "检测到项目目录已存在且非空，由于 -Force 参数，将删除并重建..." -ForegroundColor Yellow
            Remove-Item -Recurse -Force $ProjectPath
        }
        else {
            Write-Host "检测到项目目录已存在且非空，将在其中初始化（如需重建请加 -Force 参数）。" -ForegroundColor Yellow
            Write-Host "如果项目不干净，建议先手动删除 '$ProjectPath' 后重试。"
        }
    }
    else {
        Write-Host "项目目录已存在（为空），将在其中初始化..." -ForegroundColor Yellow
    }
}
else {
    Write-Host "将创建新项目目录: $ProjectPath"
}

# 构建 uv init 命令
$initArgs = @()
if ($PythonVersion) {
    $initArgs += "--python", $PythonVersion
    Write-Host "指定 Python 版本: $PythonVersion"
}

try {
    uv init $ProjectPath @initArgs
    Write-Host "项目已初始化: $ProjectPath" -ForegroundColor Green
}
catch {
    Write-Error "项目初始化失败: $_"
    exit 1
}

# 4. 激活虚拟环境
Write-Host "`n===== 激活虚拟环境 =====" -ForegroundColor Cyan
$activateScript = Join-Path $ProjectPath ".venv\Scripts\Activate.ps1"
if (-not (Test-Path $activateScript)) {
    Write-Error "激活脚本未找到: $activateScript，请确认项目初始化成功。"
    exit 1
}

. $activateScript
Write-Host "当前 Python 解释器: $(Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"

# 5. 安装PyTorch生态核心包
Write-Host "`n===== 安装 PyTorch 核心包 =====" -ForegroundColor Cyan
$torchPackages = @("torch", "torchvision")

if ($IsCpuMode) {
    Write-Host "模式: CPU 版本" -ForegroundColor Yellow
    Write-Host "将安装: $($torchPackages -join ', ')"
    $pytorchIndexUrl = "https://download.pytorch.org/whl/cpu"
}
else {
    Write-Host "模式: CUDA 版本 $CudaVersion" -ForegroundColor Green
    Write-Host "将安装: $($torchPackages -join ', ')"
    $pytorchIndexUrl = "https://download.pytorch.org/whl/$CudaVersion"
}

try {
    uv pip install $torchPackages --index-url $pytorchIndexUrl
} catch {
    Write-Error "PyTorch 核心包安装失败: $_"
    exit 1
}

# 6. 安装TensorBoard及其他包
$otherPackages = @("tensorboard")
if ($ExtraPackages) {
    $extraList = $ExtraPackages -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $otherPackages += $extraList
}

Write-Host "`n===== 安装 TensorBoard 及其他额外包 =====" -ForegroundColor Cyan
Write-Host "将安装: $($otherPackages -join ', ')"
try {
    uv pip install $otherPackages
} catch {
    Write-Error "额外包安装失败: $_"
    exit 1
}

# 函数：检查 winget 是否可用，不可用则尝试安装
function Ensure-Winget {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        return $true
    }

    Write-Host "未找到 winget，尝试通过 PowerShell 安装..." -ForegroundColor Yellow

    try {
        # 尝试通过 Add-AppxPackage 安装 Desktop App Installer
        # 这是 Windows 10/11 自带的组件，通常不需要额外安装
        # 如果已安装但不在 PATH 中，可以尝试此方式
        $appInstallerPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.appxbundle"
        if (Test-Path $appInstallerPath) {
            Add-AppxPackage -Path $appInstallerPath -DisableDevelopmentMode -Register "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.xml" 2>&1 | Out-Null
            $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($wingetCmd) {
                Write-Host "winget 已恢复可用" -ForegroundColor Green
                return $true
            }
        }

        Write-Host "winget 不可用且自动安装失败。" -ForegroundColor Red
        Write-Host "请手动安装 winget:" -ForegroundColor Yellow
        Write-Host "  方式1: 下载 Microsoft App Installer: https://aka.ms/getwinget" -ForegroundColor Yellow
        Write-Host "  方式2: 从 Microsoft Store 搜索 'App Installer'" -ForegroundColor Yellow
        Write-Host "  方式3: Windows 10/11 通常已自带 winget，请确认是否在 PATH 中" -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "winget 自动安装失败: $_" -ForegroundColor Red
        Write-Host "请手动安装: https://aka.ms/getwinget" -ForegroundColor Yellow
        return $false
    }
}

# 函数：通过直接下载安装 CUDA Toolkit
# 适用于 winget 不可用或需要指定版本的情况
function Install-CudaToolkitDirect {
    param([string]$CudaVersion = "12.4")

    # NVIDIA 官方下载页面需要浏览器交互，这里提供手动下载链接
    $downloadUrl = "https://developer.nvidia.com/cuda-${CudaVersion}-toolkit-downloads"
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  请手动下载并安装 CUDA Toolkit                          ║" -ForegroundColor Yellow
    Write-Host "║                                                          ║" -ForegroundColor Yellow
    Write-Host "║  下载地址: https://developer.nvidia.com/cuda-downloads   ║" -ForegroundColor Yellow
    Write-Host "║  推荐版本: CUDA $CudaVersion                            ║" -ForegroundColor Yellow
    Write-Host "║  选择: Windows > Host > exe(local) > 对应架构            ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "安装完成后按回车键继续..." -ForegroundColor Cyan
    Read-Host

    # 安装后验证
    $cudaBinPath = Find-CudaToolkitPath
    if ($cudaBinPath) {
        return $cudaBinPath
    }
    return $null
}

# 函数：查找 CUDA Toolkit 安装路径
function Find-CudaToolkitPath {
    $cudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
    if (-not (Test-Path $cudaRoot)) {
        return $null
    }

    # 查找最新的 CUDA 版本目录（如 v12.4）
    $versions = Get-ChildItem -Path $cudaRoot -Directory | Sort-Object Name -Descending
    foreach ($ver in $versions) {
        $binPath = Join-Path $ver.FullName "bin\nvcc.exe"
        if (Test-Path $binPath) {
            return Join-Path $ver.FullName "bin"
        }
        # 也可能是 nvcc.exe 直接在 bin 下
        $binDir = Join-Path $ver.FullName "bin"
        if (Test-Path (Join-Path $binDir "nvcc.exe")) {
            return $binDir
        }
    }
    return $null
}

# 函数：将路径写入环境变量
function Add-ToPath {
    param(
        [string]$PathToAdd,
        [string]$Scope = "Machine"  # Machine 或 User
    )

    if (-not $PathToAdd -or -not (Test-Path $PathToAdd)) {
        return $false
    }

    # 当前会话生效
    if (-not ($env:Path -like "*$PathToAdd*")) {
        $env:Path = "$env:Path;$PathToAdd"
        Write-Host "已将 CUDA 路径加入当前会话 PATH: $PathToAdd" -ForegroundColor Green
    }

    # 永久写入系统环境变量
    try {
        $currentMachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if (-not ($currentMachinePath -like "*$PathToAdd*")) {
            [Environment]::SetEnvironmentVariable("Path", "$currentMachinePath;$PathToAdd", "Machine")
            Write-Host "已将 CUDA 路径写入系统环境变量（Machine）" -ForegroundColor Green
        }

        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if (-not ($currentUserPath -like "*$PathToAdd*")) {
            [Environment]::SetEnvironmentVariable("Path", "$currentUserPath;$PathToAdd", "User")
            Write-Host "已将 CUDA 路径写入用户环境变量（User）" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "写入系统环境变量失败，请手动添加：$PathToAdd"
    }
}

# 7. 安装 CUDA Toolkit（可选）
if ($InstallCudaToolkit) {
    Write-Host "`n===== 安装 NVIDIA CUDA Toolkit =====" -ForegroundColor Cyan
    Write-Host "CUDA Toolkit 包含 nvcc 编译器，用于自己编写 CUDA 代码" -ForegroundColor Yellow

    $cudaBinPath = $null

    # 方式1：尝试 winget 安装
    if (Ensure-Winget) {
        try {
            Write-Host "通过 winget 安装 Nvidia.CUDA..." -ForegroundColor Yellow
            winget install -e --id Nvidia.CUDA --accept-package-agreements --accept-source-agreements 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "CUDA Toolkit 安装完成！" -ForegroundColor Green
                $cudaBinPath = Find-CudaToolkitPath
            }
            elseif ($exitCode -eq 17) {
                # exit code 17 = already installed
                Write-Host "CUDA Toolkit 已安装。" -ForegroundColor Green
                $cudaBinPath = Find-CudaToolkitPath
            }
            else {
                Write-Host "winget 安装退出码: $exitCode，尝试手动下载方式..." -ForegroundColor Yellow
                $cudaBinPath = Install-CudaToolkitDirect
            }
        }
        catch {
            Write-Host "winget 安装失败: $_，尝试手动下载方式..." -ForegroundColor Yellow
            $cudaBinPath = Install-CudaToolkitDirect
        }
    }
    else {
        # winget 不可用，使用直接下载方式
        $cudaBinPath = Install-CudaToolkitDirect
    }

    # 写入环境变量
    if ($cudaBinPath) {
        Write-Host "检测到 CUDA Toolkit 路径: $cudaBinPath" -ForegroundColor Green
        Add-ToPath -PathToAdd $cudaBinPath -Scope "Machine"
        Write-Host "验证 nvcc:" -ForegroundColor Cyan
        & nvcc --version 2>&1 | Select-Object -First 3
    }
    else {
        Write-Host "未找到 CUDA Toolkit 路径，请手动添加到 PATH。" -ForegroundColor Yellow
        Write-Host "常见路径：C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\vXX.X\bin" -ForegroundColor Yellow
    }
}

Write-Host "`n✅ 所有包安装完成！" -ForegroundColor Green
$resolvedPath = Resolve-Path $ProjectPath
Write-Host "项目位置: $resolvedPath"
Write-Host "虚拟环境位置: $resolvedPath\.venv"
Write-Host "后续使用时，请先激活环境: .\$ProjectPath\.venv\Scripts\Activate.ps1"
