<# : ---- batch part: keep this block ASCII only ----
@echo off
setlocal
title MC Downloader
set "MCDL_SELF=%~f0"
set "MCDL_DIR=%~dp0"
set "MCDL_ARGS=%*"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$b=[IO.File]::ReadAllBytes($env:MCDL_SELF);try{$t=(New-Object Text.UTF8Encoding $false,$true).GetString($b)}catch{$t=[Text.Encoding]::Default.GetString($b)};iex ($t.TrimStart([char]0xFEFF))"
set "MCDL_RC=%ERRORLEVEL%"
if "%~1"=="" pause
if not "%~1"=="" if exist "%~1" pause
exit /b %MCDL_RC%
#>

# =====================================================================
#  Minecraft 下载器：纯净原版 / 原版 + Fabric / Forge / NeoForge / Modrinth 整合包（.mrpack）
#  （Mojang 官方源 / BMCLAPI 镜像，最高 64 线程）
#
#  - 读取 PCL2 的配置，把游戏装到 PCL2 当前选中的 MC 文件夹：
#      PCL\Setup.ini 里的 LaunchFolderSelect（"$" 代表 PCL2 所在目录）
#      没选过时按 PCL2 自己的规则找：PCL 目录 → 其下的 .minecraft → 官启目录
#      → 注册表 HKCU\Software\PCL 里的自定义文件夹 → 新建 PCL 目录\.minecraft
#  - 默认线程数 / 下载源也取自 PCL2 的设置（注册表 ToolDownloadThread / ToolDownloadSource）
#  - 已存在且 SHA1 校验通过的文件自动跳过（可重复运行来补全）；每个文件都有官方源 / 镜像互为备用
#  - 下载中断（Ctrl+C / 关闭窗口 / 注销 / 关机）会自动删掉临时文件和没装完的版本文件夹；
#    强杀进程、断电等来不及清理的情况，下次运行时自动清理。已下好的库和资源文件会保留
#
#  加载器之间的关系（本脚本按这个规则安装，保证互不冲突）：
#  - Fabric、Forge、NeoForge 是三种互不兼容的 Mod 加载器，一个版本只能装其中一种，
#    Mod 也只能在对应的加载器（和对应的 MC 版本）上运行
#  - 每装一个加载器就新建一个独立的版本文件夹（如 versions\1.20.1-Forge_47.4.10），
#    它的 JSON 通过 inheritsFrom 继承同一 MC 版本的原版（versions\1.20.1），原版本身不会被修改，
#    所以同一个原版可以同时被多个加载器版本共用
#  - 每个加载器版本 / 整合包都单独开启 PCL2 的版本隔离：Mod、配置、存档都放在各自的版本文件夹里，
#    不同版本之间的 Mod 不会混在一起
#  - Forge / NeoForge 需要运行官方安装器给游戏打补丁，这一步要用 Java（版本跟 MC 要求的一致）；
#    电脑上没有合适的 Java 时自动下载 Mojang 官方的 Java（放在 %APPDATA%\.minecraft\runtime，PCL2 也认）
#
#  用法：
#    双击运行                                   交互模式
#    把 .mrpack 文件拖到本 bat 上               导入 Modrinth 整合包
#    MC-Downloader.bat 1.20.1                   直接下载纯净原版 1.20.1（其余用 PCL2 的设置）
#    MC-Downloader.bat 1.20.1 official 32       官方源、32 线程
#    MC-Downloader.bat fabric 1.20.1            原版 + Fabric（加载器版本用推荐 / 最新稳定版）
#    MC-Downloader.bat latest bmcl              最新正式版（snapshot = 最新快照）
#
#  请把本文件放在 PCL2 的 exe 旁边，否则运行时会让你拖入 PCL2 的位置。
#  项目主页（更新、反馈）：https://github.com/Maveric0/MC-Downloader
#  编辑后请保存为 UTF-8（无 BOM）编码。
# =====================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$MaxThreads       = 64
$UserAgent        = 'MCDL-bat/1.0'
$OfficialManifest = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
$JavaRuntimeIndex = 'https://piston-meta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json'
$BmclRoot         = 'https://bmclapi2.bangbang93.com'
$RepoUrl          = 'https://github.com/Maveric0/MC-Downloader'

# 卡住检测：连接在下载中途“速度为 0”超过这个秒数，就断开并立刻换源重试
$StallSeconds     = 20    # 全程生效（设为 0 = 关闭）
$TailPercent      = 98    # 进度达到这个百分比之后……
$TailStallSeconds = 5     # ……改用更短的阈值，尽快把最后几个卡住的文件重启

try { $Host.UI.RawUI.WindowTitle = 'Minecraft 下载器' } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 512
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::UseNagleAlgorithm = $false
# .NET Framework 的同步 HttpWebRequest 内部依赖线程池；线程池默认只按 CPU 核数起步、
# 之后每秒才补约 2 个线程，几十个并发请求会在这里排队，所以先把下限调高
[void][Threading.ThreadPool]::SetMinThreads(256, 256)
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------- 中断清理 ----------------
# 工作线程把正在写的临时文件、正在进行的连接登记在这里；
# 一旦中断（Ctrl+C / 关闭窗口 / 注销 / 关机），就断开连接、删掉临时文件和本次新建、还没装完的文件夹。
# 强杀进程、断电时来不及清理，则由下次启动时的 Clear-Leftovers 兜底。
$IncompleteMarker = '.mcdl-incomplete'       # 新建的原版版本文件夹：中断时只删本脚本放进去的文件
$WholeMarker      = '.mcdl-incomplete-all'   # 整个文件夹都是本次新建的（加载器版本、整合包、Java、临时目录）：中断时整个删掉
$Ctl       = [hashtable]::Synchronized(@{ Cancel = $false })
$TempFiles = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]'
$Requests  = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[object,object]'
$FreshList = [System.Collections.Generic.List[string]]::new()   # 本次新建、尚未装完的文件夹（C# 不可用时的后备）

# 关闭窗口时 PowerShell 本身不会执行 finally，只能用 Win32 控制台事件处理器（C# 编写）
$CleanupReady = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;

public static class McdlCleanup
{
    private delegate bool HandlerRoutine(int ctrlType);

    [DllImport("kernel32.dll")]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    private static HandlerRoutine handler;   // keep a reference so the GC can't collect it
    private static int ran;

    public static Hashtable Ctl;
    public static ConcurrentDictionary<string, object> TempFiles;
    public static ConcurrentDictionary<object, object> Requests;
    // folders created by this run that must be cleaned up if the run is interrupted
    public static ConcurrentDictionary<string, object> FreshDirs = new ConcurrentDictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    public static string MarkerName;        // vanilla version folder: delete only files this script creates
    public static string WholeMarkerName;   // folder created entirely by this run: delete all of it

    public static void Install()
    {
        if (handler != null) return;
        handler = new HandlerRoutine(OnCtrl);
        SetConsoleCtrlHandler(handler, true);
    }

    // 0 = Ctrl+C, 1 = Ctrl+Break, 2 = close window, 5 = logoff, 6 = shutdown.
    // Windows allows about 5 seconds here before it kills the process.
    private static bool OnCtrl(int ctrlType)
    {
        Cleanup();
        return false;   // let the default handler end the process
    }

    public static void Cleanup()
    {
        if (Interlocked.Exchange(ref ran, 1) == 1) return;
        if (Ctl != null) Ctl["Cancel"] = true;
        if (Requests != null)
        {
            foreach (object r in Requests.Keys)
            {
                WebRequest w = r as WebRequest;
                if (w == null)
                {
                    // PowerShell may hand us the request wrapped in a PSObject
                    var p = r.GetType().GetProperty("BaseObject");
                    if (p != null) w = p.GetValue(r, null) as WebRequest;
                }
                if (w != null) { try { w.Abort(); } catch { } }
            }
        }
        // aborted workers close their file handles shortly after, so retry for up to ~2 s
        for (int i = 0; i < 10 && TempFiles != null && !TempFiles.IsEmpty; i++)
        {
            foreach (string f in TempFiles.Keys)
            {
                try
                {
                    if (File.Exists(f)) File.Delete(f);
                    object o;
                    TempFiles.TryRemove(f, out o);
                }
                catch { }
            }
            if (!TempFiles.IsEmpty) Thread.Sleep(200);
        }
        foreach (string d in FreshDirs.Keys) CleanDir(d);
    }

    // Only touches folders carrying one of our markers.
    public static void CleanDir(string dir)
    {
        try
        {
            dir = dir.TrimEnd('\\');
            if (!Directory.Exists(dir)) return;
            string whole = Path.Combine(dir, WholeMarkerName);
            if (File.Exists(whole))
            {
                for (int i = 0; i < 5; i++)
                {
                    bool ok = true;
                    foreach (string sub in Directory.GetDirectories(dir)) { try { Directory.Delete(sub, true); } catch { ok = false; } }
                    foreach (string f in Directory.GetFiles(dir))
                    {
                        if (string.Equals(f, whole, StringComparison.OrdinalIgnoreCase)) continue;
                        try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } catch { ok = false; }
                    }
                    if (ok) { File.Delete(whole); Directory.Delete(dir, false); return; }
                    Thread.Sleep(300);
                }
                return;
            }
            string name = Path.GetFileName(dir);
            string marker = Path.Combine(dir, MarkerName);
            if (!File.Exists(marker)) return;
            if (!File.Exists(Path.Combine(dir, name + ".json")))
            {
                string jar = Path.Combine(dir, name + ".jar");
                if (File.Exists(jar)) File.Delete(jar);
                foreach (string f in Directory.GetFiles(dir, "*.mcdl")) { try { File.Delete(f); } catch { } }
            }
            File.Delete(marker);
            if (Directory.GetFileSystemEntries(dir).Length == 0) Directory.Delete(dir);
        }
        catch { }
    }
}
'@
    [McdlCleanup]::Ctl = $Ctl
    [McdlCleanup]::TempFiles = $TempFiles
    [McdlCleanup]::Requests = $Requests
    [McdlCleanup]::MarkerName = $IncompleteMarker
    [McdlCleanup]::WholeMarkerName = $WholeMarker
    [McdlCleanup]::Install()
    $CleanupReady = $true
} catch {
    Write-Host '提示：无法启用“中断时立即清理”（系统不允许编译 C# 代码），残留会在下次运行时清理。' -ForegroundColor Yellow
}

# 代理：只用系统里显式设置的代理（Clash / v2rayN 的“系统代理”）或 PAC，否则直连。
# 不用 .NET 默认的 WPAD 自动探测，它每个新域名都要走一遍，且内部加锁，高并发时会拖慢
$ProxyText = '直连'
$inet = $null
try { $inet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch {}
if ($inet -and $inet.AutoConfigURL) {
    $ProxyText = '系统 PAC 代理'
} else {
    $proxyServer = $null
    if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
        $proxyServer = [string]$inet.ProxyServer
        if ($proxyServer.Contains('=')) {
            if ($proxyServer -match '(?:^|;)https=([^;]+)') { $proxyServer = $Matches[1] }
            elseif ($proxyServer -match '(?:^|;)http=([^;]+)') { $proxyServer = $Matches[1] }
            else { $proxyServer = $null }   # 只有 socks 之类，.NET 不支持
        }
    }
    if ($proxyServer) {
        $wp = New-Object Net.WebProxy ('http://' + ($proxyServer -replace '^\w+://', ''))
        $wp.BypassProxyOnLocal = $true
        [Net.WebRequest]::DefaultWebProxy = $wp
        $ProxyText = '系统代理 ' + $proxyServer
    } else {
        [Net.WebRequest]::DefaultWebProxy = $null
    }
}

# ------------------------------- 通用工具 -------------------------------

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn2([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host $msg -ForegroundColor Red }

function Add-Slash([string]$p) {
    if ($p.EndsWith('\')) { return $p }
    return $p + '\'
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return '{0:N0} B' -f $b
}

# 返回 Dictionary（JSON 对象）或 object[]（JSON 数组）；数组用逗号包住，避免被 PowerShell 拆开
function ConvertFrom-JsonText([string]$text) {
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $js.RecursionLimit = 1000
    return , $js.DeserializeObject($text)
}

# 安全地逐层取 JSON 字段：J $obj 'downloads' 'client' 'url'，不存在返回 $null
function J($o) {
    foreach ($k in $args) {
        if ($o -isnot [System.Collections.Generic.IDictionary[string,object]]) { return $null }
        if (-not $o.ContainsKey($k)) { return $null }
        $o = $o[$k]
    }
    return , $o
}

function Get-Sha1Hex([byte[]]$data) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-LocalFile([string]$path, [string]$sha1) {
    if (-not [IO.File]::Exists($path)) { return $false }
    if (-not $sha1) { return $true }
    return ((Get-Sha1Hex ([IO.File]::ReadAllBytes($path))) -eq $sha1.ToLowerInvariant())
}

function Remove-Quiet([string]$path) {
    try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch {}
}

function Save-Bytes([string]$path, [byte[]]$data) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllBytes($path, $data)
}

function Test-Yes([string]$s) { return ([string]$s).Trim() -match '^(y|yes|是)$' }

# ---------------- 未完成标记 ----------------

# 与 McdlCleanup.CleanDir 相同：只处理带“未完成”标记的文件夹
function Clear-MarkedDir([string]$dir) {
    $dir = $dir.TrimEnd('\')
    if (-not [IO.Directory]::Exists($dir)) { return $false }
    # 整个文件夹都是那次运行新建的：全部删掉（标记最后删）
    $whole = $dir + '\' + $WholeMarker
    if ([IO.File]::Exists($whole)) {
        foreach ($sub in [IO.Directory]::GetDirectories($dir)) { try { [IO.Directory]::Delete($sub, $true) } catch {} }
        foreach ($f in [IO.Directory]::GetFiles($dir)) { if ($f -ne $whole) { Remove-Quiet $f } }
        if ([IO.Directory]::GetFileSystemEntries($dir).Length -le 1) {
            Remove-Quiet $whole
            try { [IO.Directory]::Delete($dir) } catch {}
        }
        return $true
    }
    # 新建的原版文件夹：只删本脚本放进去的文件，文件夹空了才删
    $name = [IO.Path]::GetFileName($dir)
    $marker = $dir + '\' + $IncompleteMarker
    if (-not [IO.File]::Exists($marker)) { return $false }
    if (-not [IO.File]::Exists($dir + '\' + $name + '.json')) {
        Remove-Quiet ($dir + '\' + $name + '.jar')
        foreach ($f in [IO.Directory]::GetFiles($dir, '*.mcdl')) { Remove-Quiet $f }
    }
    Remove-Quiet $marker
    try { if ([IO.Directory]::GetFileSystemEntries($dir).Length -eq 0) { [IO.Directory]::Delete($dir) } } catch {}
    return $true
}

# 给本次新建的文件夹打“未完成”标记，并登记到中断清理里
function Set-FreshMark([string]$dir, [string]$marker) {
    $dir = Add-Slash $dir
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText($dir + $marker, 'MC-Downloader: install in progress, removed automatically if interrupted')
    if ($CleanupReady) { [void][McdlCleanup]::FreshDirs.TryAdd($dir, $null) }
    if (-not $FreshList.Contains($dir)) { $FreshList.Add($dir) }
}
# 装好了：去掉标记，保留文件夹
function Clear-FreshMark([string]$dir, [string]$marker) {
    $dir = Add-Slash $dir
    Remove-Quiet ($dir + $marker)
    if ($CleanupReady) { $o = $null; [void][McdlCleanup]::FreshDirs.TryRemove($dir, [ref]$o) }
    [void]$FreshList.Remove($dir)
}
# 不要了：按标记删掉
function Remove-FreshDir([string]$dir) {
    $dir = Add-Slash $dir
    [void](Clear-MarkedDir $dir)
    if ($CleanupReady) { $o = $null; [void][McdlCleanup]::FreshDirs.TryRemove($dir, [ref]$o) }
    [void]$FreshList.Remove($dir)
}

# 临时工作目录（放 Forge / NeoForge 安装器和安装日志），用完即删
function New-WorkDir {
    $d = (Add-Slash ([IO.Path]::GetTempPath())) + 'MC-Downloader\' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '\'
    Set-FreshMark $d $WholeMarker
    return $d
}

# 启动时兜底：删掉上次被强杀 / 断电留下的临时文件（*.mcdl）和没装完的文件夹
function Clear-Leftovers([string]$mc) {
    $c = @{ Files = 0; Dirs = 0 }
    $delTmp = {
        param([string]$d, $opt)
        try {
            foreach ($f in @([IO.Directory]::EnumerateFiles($d, '*.mcdl', $opt))) {
                try { [IO.File]::Delete($f); $c.Files++ } catch {}
            }
        } catch {}
    }
    foreach ($sub in 'libraries', 'assets', 'resources') {
        if ([IO.Directory]::Exists($mc + $sub)) { & $delTmp ($mc + $sub) ([IO.SearchOption]::AllDirectories) }
    }
    $vroot = $mc + 'versions'
    if ([IO.Directory]::Exists($vroot)) {
        foreach ($vd in [IO.Directory]::GetDirectories($vroot)) {
            if (Clear-MarkedDir $vd) { $c.Dirs++; continue }
            # 整合包的 Mod 等会下载到版本文件夹的子目录里；存档目录很大，只看顶层
            & $delTmp $vd ([IO.SearchOption]::TopDirectoryOnly)
            $subs = @()
            try { $subs = [IO.Directory]::GetDirectories($vd) } catch {}
            foreach ($sd in $subs) {
                $opt = [IO.SearchOption]::AllDirectories
                if ([IO.Path]::GetFileName($sd) -eq 'saves') { $opt = [IO.SearchOption]::TopDirectoryOnly }
                & $delTmp $sd $opt
            }
        }
    }
    # Java 运行时、临时工作目录
    $javaRoot = (Add-Slash ([Environment]::GetFolderPath('ApplicationData'))) + '.minecraft\runtime'
    $workRoot = (Add-Slash ([IO.Path]::GetTempPath())) + 'MC-Downloader'
    foreach ($root in @($javaRoot, $workRoot)) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        foreach ($d in [IO.Directory]::GetDirectories($root)) {
            if (Clear-MarkedDir $d) { $c.Dirs++ } else { & $delTmp $d ([IO.SearchOption]::AllDirectories) }
        }
    }
    return [pscustomobject]@{ Files = $c.Files; Versions = $c.Dirs }
}

# ------------------------------- 下载源 -------------------------------

function ConvertTo-BmclUrl([string]$url) {
    $u = $url -replace '^https?://(piston-meta|piston-data|launchermeta|launcher)\.mojang\.com', $BmclRoot
    $u = $u -replace '^https?://libraries\.minecraft\.net', ($BmclRoot + '/maven')
    $u = $u -replace '^https?://resources\.download\.minecraft\.net', ($BmclRoot + '/assets')
    return $u
}

# 返回按优先级排好的地址列表（首选源在前，另一个源做备用）
function Get-Urls([string]$official) {
    $mirror = ConvertTo-BmclUrl $official
    if ($mirror -eq $official) { return , @($official) }
    if ($UseBmcl) { return , @($mirror, $official) }
    return , @($official, $mirror)
}

# 按用户选的下载源排序：镜像优先 或 官方优先（另一边做备用）
function Join-Sources($official, $mirror) {
    $o = @($official | Where-Object { $_ })
    $m = @($mirror | Where-Object { $_ })
    if ($UseBmcl) { $all = $m + $o } else { $all = $o + $m }
    return , @($all | Select-Object -Unique)
}

# Maven 仓库地址 → BMCLAPI 镜像（BMCLAPI 的 /maven 汇总了 Mojang、Forge、NeoForge、Fabric 的仓库）
function ConvertTo-MavenMirror([string]$url) {
    $m = $url -replace '^https?://(maven\.minecraftforge\.net|files\.minecraftforge\.net/maven|maven\.neoforged\.net/releases|maven\.fabricmc\.net|libraries\.minecraft\.net)/', ($BmclRoot + '/maven/')
    if ($m -eq $url) { $m = ConvertTo-BmclUrl $url }
    if ($m -eq $url) { return $null }
    return $m
}
function Get-LibUrls([string]$url) { return , (Join-Sources @($url) @(ConvertTo-MavenMirror $url)) }

function Get-SourceName([string]$u) {
    if ($u.StartsWith($BmclRoot, [StringComparison]::OrdinalIgnoreCase)) { return 'BMCLAPI' }
    try { return ([Uri]$u).Host } catch { return $u }
}

# 主线程下载一个小文件。同步的 GetResponse / Read 一旦卡住，从外面没法打断，
# 所以改用异步请求、由主线程计时：连接 $connectMs 毫秒没有响应，或者下载中途 $stallMs 毫秒没收到数据，
# 就 Abort() 掉这个请求并抛出 TimeoutException，由 Get-Remote 立刻换源重启
function Get-Bytes([string]$url, [int]$connectMs, [int]$stallMs) {
    $req = [Net.WebRequest]::Create($url)
    $req.UserAgent = $UserAgent
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $resp = $null
    try {
        $task = $req.GetResponseAsync()
        if (-not $task.Wait($connectMs)) {
            $req.Abort()
            throw [TimeoutException]::new('连接 ' + [int]($connectMs / 1000) + ' 秒没有响应')
        }
        $resp = $task.Result
        $s = $resp.GetResponseStream()
        $ms = [IO.MemoryStream]::new()
        $buf = [byte[]]::new(65536)
        while ($true) {
            $rt = $s.ReadAsync($buf, 0, $buf.Length)
            if (-not $rt.Wait($stallMs)) {
                $req.Abort()
                throw [TimeoutException]::new('下载中途 ' + [int]($stallMs / 1000) + ' 秒没有收到数据')
            }
            $n = $rt.Result
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        return , $ms.ToArray()
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
}

# 主线程用：下载小文件（版本列表、JSON、安装器），多源 + 卡住即重启 + 可选 SHA1 校验。
# 各个源轮流试；某次卡住（超时）就立刻断开、不等待，换下一个源重试（BMCLAPI 重试时会被分到别的节点）。
# 每一轮的时限放宽一些，避免网速本来就慢时被误判为卡住。
# 所有源都回答“没有这个文件”（HTTP 400/404/410）时抛出 FileNotFoundException，方便调用方判断“不支持”
function Get-Remote([string[]]$urls, [string]$what, [string]$sha1) {
    $list = @($urls | Where-Object { $_ } | Select-Object -Unique)
    $connectLimits = 8000, 12000, 20000   # 每一轮：连接多久没响应算卡住（毫秒）
    $stallLimits = 6000, 10000, 15000     # 每一轮：下载中途多久没数据算卡住（毫秒）
    $last = ''
    $dead = [System.Collections.Generic.HashSet[string]]::new()
    for ($round = 0; $round -lt $connectLimits.Count; $round++) {
        foreach ($u in $list) {
            if ($dead.Contains($u)) { continue }
            try {
                $data = Get-Bytes $u $connectLimits[$round] $stallLimits[$round]
                if (-not $sha1 -or (Get-Sha1Hex $data) -eq $sha1.ToLowerInvariant()) {
                    $global:McdlRemoteFrom = $u
                    return , $data
                }
                $last = "SHA1 校验失败（$($u)）"
            } catch {
                $e = $_.Exception
                while ($e.InnerException) { $e = $e.InnerException }
                $last = "$($e.Message)（$($u)）"
                if ($e -is [TimeoutException]) {
                    Write-Host "    $(Get-SourceName $u) $($e.Message)，已断开，换源重试..." -ForegroundColor DarkGray
                    continue
                }
                # 服务器明确说没有这个文件：换源可以，原地重试没有意义
                if ($e -is [Net.WebException] -and $e.Response -is [Net.HttpWebResponse]) {
                    $code = [int]$e.Response.StatusCode
                    if ($code -eq 400 -or $code -eq 404 -or $code -eq 410) {
                        [void]$dead.Add($u)
                        $last = "HTTP $($code)（$($u)）"
                        continue
                    }
                }
            }
            Start-Sleep -Milliseconds (300 + 700 * $round)
        }
        if ($dead.Count -ge $list.Count) { break }
    }
    if ($list.Count -gt 0 -and $dead.Count -ge $list.Count) { throw [IO.FileNotFoundException]::new("下载$($what)失败：服务器上没有这个文件（$($last)）") }
    throw "下载$($what)失败：$($last)"
}

function Get-JsonRemote($urls, [string]$what) {
    $bytes = Get-Remote $urls $what $null
    return , (ConvertFrom-JsonText ([Text.Encoding]::UTF8.GetString($bytes)))
}

# ------------------------------- PCL2 配置 -------------------------------

function Test-PclDir([string]$dir) {
    if (-not $dir -or -not [IO.Directory]::Exists($dir)) { return $false }
    if ([IO.File]::Exists($dir + 'PCL\Setup.ini')) { return $true }
    foreach ($f in [IO.Directory]::GetFiles($dir, '*.exe')) {
        if ([IO.Path]::GetFileName($f) -match 'Plain Craft Launcher|^PCL') { return $true }
    }
    return $false
}

# PCL2 的 ini 是 "键:值" 格式，编码可能是 UTF-8 或 GB18030
function Read-PclIni([string]$file) {
    $map = @{}
    if (-not [IO.File]::Exists($file)) { return $map }
    $bytes = [IO.File]::ReadAllBytes($file)
    try { $text = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes) }
    catch { $text = [Text.Encoding]::GetEncoding(54936).GetString($bytes) }
    foreach ($line in ($text.TrimStart([char]0xFEFF) -split "`r?`n")) {
        $i = $line.IndexOf(':')
        if ($i -gt 0) { $map[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    return $map
}

# 正式版 PCL2 用 HKCU\Software\PCL，开源自编译版用 PCLDebug
function Read-PclReg([string]$name) {
    foreach ($key in 'HKCU:\Software\PCL', 'HKCU:\Software\PCLDebug') {
        try {
            $v = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name
            if ($null -ne $v -and "$v" -ne '') { return [string]$v }
        } catch {}
    }
    return $null
}

# 与 PCL2 的 McFolderSelected / McFolderListLoadSub 逻辑一致
function Resolve-PclMcFolder([string]$pcl) {
    $ini = Read-PclIni ($pcl + 'PCL\Setup.ini')
    $sel = [string]$ini['LaunchFolderSelect']
    if ($sel) {
        $p = Add-Slash ($sel.Replace('$', $pcl))
        if ([IO.Directory]::Exists($p)) { return @{ Path = $p; Reason = 'PCL2 当前选中的文件夹' } }
        Write-Warn2 "PCL2 配置中选中的文件夹不存在：$($p)，改按 PCL2 默认规则查找。"
    }
    if ([IO.Directory]::Exists($pcl + 'versions')) {
        return @{ Path = $pcl; Reason = 'PCL2 所在文件夹' }
    }
    try {
        foreach ($d in [IO.Directory]::GetDirectories($pcl)) {
            if ([IO.Directory]::Exists($d + '\versions') -or [IO.Path]::GetFileName($d) -eq '.minecraft') {
                return @{ Path = (Add-Slash $d); Reason = 'PCL2 所在文件夹下的 MC 文件夹' }
            }
        }
    } catch {}
    $mojang = (Add-Slash ([Environment]::GetFolderPath('ApplicationData'))) + '.minecraft\'
    if ([IO.Directory]::Exists($mojang + 'versions')) {
        return @{ Path = $mojang; Reason = '官方启动器文件夹' }
    }
    $custom = Read-PclReg 'LaunchFolders'
    if ($custom) {
        foreach ($entry in $custom.Split('|')) {
            $i = $entry.IndexOf('>')
            if ($i -le 0) { continue }
            $fp = $entry.Substring($i + 1)
            if ($fp -and [IO.Directory]::Exists($fp)) {
                return @{ Path = (Add-Slash $fp); Reason = "PCL2 自定义文件夹「$($entry.Substring(0, $i))」" }
            }
        }
    }
    return @{ Path = $pcl + '.minecraft\'; Reason = 'PCL2 默认位置（将新建）' }
}

# 与 PCL2 导入整合包时一样：给这个版本单独开启版本隔离（Mod、配置、存档都放在版本文件夹里）
function Set-PclIsolation([string]$instDir) {
    $iniPath = $instDir + 'PCL\Setup.ini'
    $ini = Read-PclIni $iniPath
    $ini['VersionArgumentIndie'] = '1'
    $ini['VersionArgumentIndieV2'] = 'True'
    $sb = [Text.StringBuilder]::new()
    foreach ($k in @($ini.Keys)) { [void]$sb.Append($k).Append(':').Append($ini[$k]).Append("`r`n") }
    [void][IO.Directory]::CreateDirectory($instDir + 'PCL')
    [IO.File]::WriteAllText($iniPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}

# Forge / NeoForge 安装器要求 MC 文件夹里有 launcher_profiles.json；没有就按 PCL2 的格式建一个
function Initialize-LauncherProfiles([string]$mc) {
    $f = $mc + 'launcher_profiles.json'
    if ([IO.File]::Exists($f)) { return }
    $now = [DateTime]::Now.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss") + '.0000Z'
    $json = '{"profiles":{"PCL":{"icon":"Grass","name":"PCL","lastVersionId":"latest-release","type":"latest-release","lastUsed":"' + $now + '"}},"selectedProfile":"PCL","clientToken":"23323323323323323323323323323333"}'
    [IO.File]::WriteAllText($f, $json, [Text.UTF8Encoding]::new($false))
}

# ------------------------------- 版本解析 -------------------------------

# Mojang 规则：有 rules 时默认禁止，按顺序匹配，最后一条匹配的规则生效
function Test-Rules($rules) {
    if ($null -eq $rules) { return $true }
    $allow = $false
    foreach ($r in $rules) {
        $match = $true
        $os = J $r 'os'
        if ($null -ne $os) {
            $name = J $os 'name'
            if ($name -and $name -ne 'windows') { $match = $false }
            if ((J $os 'arch') -eq 'x86' -and [Environment]::Is64BitOperatingSystem) { $match = $false }
        }
        if ($null -ne (J $r 'features')) { $match = $false }
        if ($match) { $allow = ((J $r 'action') -eq 'allow') }
    }
    return $allow
}

function Show-Versions([string]$type, [int]$limit) {
    $ids = @($versions | Where-Object { (J $_ 'type') -eq $type } | ForEach-Object { J $_ 'id' })
    if ($limit -gt 0 -and $ids.Count -gt $limit) { $ids = $ids[0..($limit - 1)] }
    $line = ''
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $line += ([string]$ids[$i]).PadRight(14)
        if (($i + 1) % 7 -eq 0) { Write-Host ('  ' + $line); $line = '' }
    }
    if ($line) { Write-Host ('  ' + $line) }
}

function Add-Job([string]$url, [string]$path, [string]$sha1, $size) {
    if (-not $url) { return }
    if (-not $seen.Add($path)) { return }
    $jobs.Add([pscustomobject]@{ Urls = (Get-Urls $url); Path = $path; Sha1 = $sha1; Size = [long]$size })
}

# 直接给出地址列表（已按优先级排好）的版本
function Add-JobMulti($urls, [string]$path, [string]$sha1, $size) {
    $list = @($urls | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    if (-not $seen.Add($path)) { return }
    $jobs.Add([pscustomobject]@{ Urls = $list; Path = $path; Sha1 = $sha1; Size = [long]$size })
}

function ConvertTo-MavenPath([string]$coord) {
    $ext = 'jar'
    $at = $coord.IndexOf('@')
    if ($at -ge 0) { $ext = $coord.Substring($at + 1); $coord = $coord.Substring(0, $at) }
    $p = $coord.Split(':')
    if ($p.Count -lt 3) { throw "无法识别的库名：$($coord)" }
    $file = $p[1] + '-' + $p[2]
    if ($p.Count -ge 4) { $file += '-' + $p[3] }
    return $p[0].Replace('.', '/') + '/' + $p[1] + '/' + $p[2] + '/' + $file + '.' + $ext
}

# 加载器的库文件：有 downloads.artifact 就按它下；只有 name + url 的（Fabric 等）按 Maven 规则拼路径
function Add-LibraryJob($lib) {
    if (-not (Test-Rules (J $lib 'rules'))) { return }
    $art = J $lib 'downloads' 'artifact'
    if ($null -ne $art) {
        $url = [string](J $art 'url')
        $p = [string](J $art 'path')
        if (-not $url -or -not $p) { return }   # 地址为空 = 安装器自带或安装时才生成的文件
        Add-JobMulti (Get-LibUrls $url) ($mcDir + 'libraries\' + $p.Replace('/', '\')) (J $art 'sha1') (J $art 'size')
        return
    }
    $name = [string](J $lib 'name')
    if (-not $name) { return }
    $rel = ConvertTo-MavenPath $name
    $base = [string](J $lib 'url')
    if (-not $base) { $base = 'https://libraries.minecraft.net/' }
    if (-not $base.EndsWith('/')) { $base += '/' }
    Add-JobMulti (Get-LibUrls ($base + $rel)) ($mcDir + 'libraries\' + $rel.Replace('/', '\')) (J $lib 'sha1') (J $lib 'size')
}

# 把原版 $versionId 需要的文件加入下载队列；版本 JSON 先留在内存里，全部下完后再写入
function Add-VanillaJobs([string]$versionId) {
    $entry = $vmap[$versionId]
    if ($null -eq $entry -or -not (J $entry 'url')) { throw "版本列表里找不到 $($versionId) 的下载地址" }
    $verDir = $mcDir + 'versions\' + $versionId + '\'
    Write-Info "正在获取 $($versionId) 的版本信息..."
    $jsonBytes = Get-Remote (Get-Urls (J $entry 'url')) '版本 JSON' (J $entry 'sha1')
    $verJson = ConvertFrom-JsonText ([Text.Encoding]::UTF8.GetString($jsonBytes))

    # 客户端本体
    $client = J $verJson 'downloads' 'client'
    if ($null -eq $client) { throw '版本 JSON 里没有 client 下载信息' }
    Add-Job (J $client 'url') ($verDir + $versionId + '.jar') (J $client 'sha1') (J $client 'size')

    # 依赖库（含 natives）
    $arch = '32'
    if ([Environment]::Is64BitOperatingSystem) { $arch = '64' }
    foreach ($lib in (J $verJson 'libraries')) {
        if (-not (Test-Rules (J $lib 'rules'))) { continue }
        $art = J $lib 'downloads' 'artifact'
        if ($null -ne $art) {
            Add-Job (J $art 'url') ($mcDir + 'libraries\' + ([string](J $art 'path')).Replace('/', '\')) (J $art 'sha1') (J $art 'size')
        }
        $cls = J $lib 'natives' 'windows'
        if ($cls) {
            $nat = J $lib 'downloads' 'classifiers' ($cls.Replace('${arch}', $arch))
            if ($null -ne $nat) {
                Add-Job (J $nat 'url') ($mcDir + 'libraries\' + ([string](J $nat 'path')).Replace('/', '\')) (J $nat 'sha1') (J $nat 'size')
            }
        }
    }

    # log4j 配置
    $log = J $verJson 'logging' 'client' 'file'
    if ($null -ne $log) {
        Add-Job (J $log 'url') ($mcDir + 'assets\log_configs\' + (J $log 'id')) (J $log 'sha1') (J $log 'size')
    }

    # 资源索引 + 资源文件
    $ai = J $verJson 'assetIndex'
    if ($null -ne $ai) {
        $aiPath = $mcDir + 'assets\indexes\' + (J $ai 'id') + '.json'
        if (Test-LocalFile $aiPath (J $ai 'sha1')) {
            $aiBytes = [IO.File]::ReadAllBytes($aiPath)
        } else {
            Write-Info '正在获取资源索引...'
            $aiBytes = Get-Remote (Get-Urls (J $ai 'url')) '资源索引' (J $ai 'sha1')
            Save-Bytes $aiPath $aiBytes
        }
        $aiJson = ConvertFrom-JsonText ([Text.Encoding]::UTF8.GetString($aiBytes))
        $mapToResources = [bool](J $aiJson 'map_to_resources')
        $virtual = [bool](J $aiJson 'virtual')
        $objects = J $aiJson 'objects'
        if ($null -ne $objects) {
            foreach ($kv in $objects.GetEnumerator()) {
                $hash = [string](J $kv.Value 'hash')
                $sub = $hash.Substring(0, 2)
                if ($mapToResources) { $local = $mcDir + 'resources\' + $kv.Key.Replace('/', '\') }
                elseif ($virtual) { $local = $mcDir + 'assets\virtual\legacy\' + $kv.Key.Replace('/', '\') }
                else { $local = $mcDir + 'assets\objects\' + $sub + '\' + $hash }
                Add-Job ('https://resources.download.minecraft.net/' + $sub + '/' + $hash) $local $hash (J $kv.Value 'size')
            }
        }
    }

    return [pscustomobject]@{
        Id = $versionId; Entry = $entry; Dir = $verDir
        JsonPath = $verDir + $versionId + '.json'; JsonBytes = $jsonBytes; Json = $verJson
    }
}

# 写版本 JSON：只把顶层的 "id" 换成新的版本名（文件夹名必须和 id 一致），其余内容原样保留
function Save-VersionJson([string]$text, [string]$oldId, [string]$name) {
    $re = [regex]::new('"id"\s*:\s*"' + [regex]::Escape($oldId) + '"')
    if ($re.IsMatch($text)) {
        $escaped = $name.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
        $text = $re.Replace($text, ('"id": "' + $escaped + '"'), 1)
    } else {
        $obj = ConvertFrom-JsonText $text
        $obj['id'] = $name
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        $text = $js.Serialize($obj)
    }
    $path = $mcDir + 'versions\' + $name + '\' + $name + '.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

# ------------------------------- 加载器版本列表 -------------------------------

# Fabric：支持 1.14 及以上（含快照）；meta 返回的列表从新到旧
function Get-FabricVersions([string]$mc) {
    $p = '/v2/versions/loader/' + [Uri]::EscapeDataString($mc)
    $data = $null
    try { $data = Get-JsonRemote (Join-Sources @('https://meta.fabricmc.net' + $p) @($BmclRoot + '/fabric-meta' + $p)) 'Fabric 版本列表' }
    catch [IO.FileNotFoundException] { return , @() }
    $list = @(foreach ($e in $data) {
        $l = J $e 'loader'
        if ($null -eq $l) { continue }
        $stable = [bool](J $l 'stable')
        $tag = '测试版'
        if ($stable) { $tag = '稳定版' }
        [pscustomobject]@{ Kind = 'Fabric'; Mc = $mc; Version = [string](J $l 'version'); Stable = $stable; Tag = $tag }
    })
    return , $list
}

# Forge：本脚本只支持新式安装器，即 MC 1.13 及以上、以及 1.12.2 的 14.23.5.2851 之后的构建
function Test-ForgeSupported([string]$mc) {
    try { $v = [version]$mc } catch { return $false }
    return ($v -ge [version]'1.13' -or $v -eq [version]'1.12.2')
}
function New-ForgeItem([string]$mc, [string]$v, [string]$full, [string]$sha) {
    return [pscustomobject]@{ Kind = 'Forge'; Mc = $mc; Version = $v; Full = $full; Artifact = 'forge'; Group = 'net/minecraftforge'; Sha1 = $sha; Stable = $true; Tag = '' }
}
function Get-ForgeVersions([string]$mc) {
    if (-not (Test-ForgeSupported $mc)) { return , @() }
    $items = [System.Collections.Generic.List[object]]::new()
    $recommended = ''; $latest = ''
    $sources = @('official', 'bmcl')
    if ($UseBmcl) { $sources = @('bmcl', 'official') }
    $answered = $false   # 至少有一个源正常回答了（哪怕回答“没有”）
    $lastErr = $null
    foreach ($src in $sources) {
        try {
            if ($src -eq 'bmcl') {
                $data = Get-JsonRemote @($BmclRoot + '/forge/minecraft/' + [Uri]::EscapeDataString($mc)) 'Forge 版本列表'
                foreach ($e in @($data | Sort-Object { [long](J $_ 'build') } -Descending)) {
                    $v = [string](J $e 'version')
                    $full = $mc + '-' + $v
                    $branch = [string](J $e 'branch')
                    if ($branch) { $full += '-' + $branch }
                    $sha = $null
                    foreach ($f in (J $e 'files')) {
                        if ((J $f 'category') -eq 'installer' -and (J $f 'format') -eq 'jar') { $sha = [string](J $f 'hash') }
                    }
                    $items.Add((New-ForgeItem $mc $v $full $sha))
                }
                try {
                    foreach ($pr in (Get-JsonRemote @($BmclRoot + '/forge/promos') 'Forge 推荐版本')) {
                        $nm = [string](J $pr 'name')
                        if ($nm -eq ($mc + '-recommended')) { $recommended = [string](J $pr 'build' 'version') }
                        if ($nm -eq ($mc + '-latest')) { $latest = [string](J $pr 'build' 'version') }
                    }
                } catch {}
            } else {
                $meta = Get-JsonRemote @('https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json') 'Forge 版本列表'
                $arr = J $meta $mc
                if ($null -ne $arr) {
                    for ($i = $arr.Count - 1; $i -ge 0; $i--) {
                        $full = [string]$arr[$i]
                        $items.Add((New-ForgeItem $mc $full.Substring($mc.Length + 1) $full $null))
                    }
                }
                try {
                    $pr = J (Get-JsonRemote @('https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json') 'Forge 推荐版本') 'promos'
                    $recommended = [string](J $pr ($mc + '-recommended'))
                    $latest = [string](J $pr ($mc + '-latest'))
                } catch {}
            }
            $answered = $true
            if ($items.Count -gt 0) { break }
        } catch [IO.FileNotFoundException] {
            $answered = $true
            $items.Clear()
        } catch {
            $lastErr = $_.Exception.Message
            $items.Clear()
        }
    }
    if (-not $answered -and $lastErr) { throw "获取 Forge 版本列表失败：$($lastErr)" }
    $list = @(foreach ($it in $items) {
        if ($mc -eq '1.12.2') {
            $parts = $it.Version.Split('.')
            $build = 0
            if ($parts.Count -lt 4 -or -not [int]::TryParse($parts[3], [ref]$build) -or $build -lt 2851) { continue }
        }
        if ($recommended -and $it.Version -eq $recommended) { $it.Tag = '推荐版' }
        elseif ($latest -and $it.Version -eq $latest) { $it.Tag = '最新版' }
        $it
    })
    return , $list
}

# NeoForge 版本号 → MC 版本：21.1.x → 1.21.1、21.0.x → 1.21、20.4.x → 1.20.4；26 起改为 26.1.2.x → 26.1.2、26.3.0.x → 26.3
function Get-NeoForgeMc([string]$v) {
    if ($v -match '^0\.' -or $v -match 'snapshot|alpha') { return $null }
    $p = (($v -split '[-+]')[0]).Split('.')
    $major = 0
    if ($p.Count -lt 3 -or -not [int]::TryParse($p[0], [ref]$major)) { return $null }
    if ($major -ge 26) {
        if ($p.Count -lt 4) { return $null }
        $mc = $p[0] + '.' + $p[1]
        if ($p[2] -ne '0') { $mc += '.' + $p[2] }
        return $mc
    }
    $mc = '1.' + $p[0]
    if ($p[1] -ne '0') { $mc += '.' + $p[1] }
    return $mc
}
function Get-VersionSortKey([string]$v) {
    return (@((($v -split '[-+]')[0]).Split('.') | ForEach-Object { $_.PadLeft(10, '0') }) -join '.')
}
# 1.20.1 的 NeoForge 沿用 Forge 的坐标（net.neoforged:forge:1.20.1-47.1.x），从 1.20.2 起才改为 net.neoforged:neoforge
function New-NeoForgeItem([string]$mc, [string]$v) {
    $beta = ($v -match 'beta|alpha')
    $tag = '稳定版'
    if ($beta) { $tag = '测试版' }
    if ($mc -eq '1.20.1') {
        $short = $v -replace '^1\.20\.1-', ''
        return [pscustomobject]@{ Kind = 'NeoForge'; Mc = $mc; Version = $short; Full = '1.20.1-' + $short; Artifact = 'forge'; Group = 'net/neoforged'; Sha1 = $null; Stable = (-not $beta); Tag = $tag }
    }
    return [pscustomobject]@{ Kind = 'NeoForge'; Mc = $mc; Version = $v; Full = $v; Artifact = 'neoforge'; Group = 'net/neoforged'; Sha1 = $null; Stable = (-not $beta); Tag = $tag }
}
function Get-NeoForgeVersions([string]$mc) {
    $found = [System.Collections.Generic.List[string]]::new()
    $sources = @('official', 'bmcl')
    if ($UseBmcl) { $sources = @('bmcl', 'official') }
    $answered = $false
    $lastErr = $null
    foreach ($src in $sources) {
        try {
            if ($src -eq 'bmcl') {
                foreach ($e in (Get-JsonRemote @($BmclRoot + '/neoforge/list/' + [Uri]::EscapeDataString($mc)) 'NeoForge 版本列表')) {
                    $v = [string](J $e 'version')
                    if ($v -and $v -notmatch 'snapshot|alpha') { $found.Add($v) }
                }
            } elseif ($mc -eq '1.20.1') {
                $d = Get-JsonRemote @('https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge') 'NeoForge 版本列表'
                foreach ($v in (J $d 'versions')) { if ([string]$v -like '1.20.1-*') { $found.Add([string]$v) } }
            } else {
                $d = Get-JsonRemote @('https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge') 'NeoForge 版本列表'
                foreach ($v in (J $d 'versions')) { if ((Get-NeoForgeMc ([string]$v)) -eq $mc) { $found.Add([string]$v) } }
            }
            $answered = $true
            if ($found.Count -gt 0) { break }
        } catch [IO.FileNotFoundException] {
            $answered = $true
            $found.Clear()
        } catch {
            $lastErr = $_.Exception.Message
            $found.Clear()
        }
    }
    if (-not $answered -and $lastErr) { throw "获取 NeoForge 版本列表失败：$($lastErr)" }
    # 1.20.1 的版本号带 “1.20.1-” 前缀，去掉后才能正确排序
    $vals = @(foreach ($v in $found) { $v -replace '^1\.20\.1-', '' })
    $sorted = @($vals | Select-Object -Unique | Sort-Object { Get-VersionSortKey $_ } -Descending)
    return , @(foreach ($v in $sorted) { New-NeoForgeItem $mc $v })
}

# 取得某个 MC 版本可用的加载器版本，并选出默认值（Forge：推荐版 > 最新版；其他：最新稳定版）
function Get-LoaderChoices([string]$kind, [string]$mc) {
    if ($kind -eq 'fabric') {
        $list = Get-FabricVersions $mc; $name = 'Fabric'
        $why = "Fabric 没有适用于 Minecraft $($mc) 的版本（Fabric 只支持 1.14 及以上）"
    } elseif ($kind -eq 'forge') {
        $list = Get-ForgeVersions $mc; $name = 'Forge'
        $why = "没有可安装的 Forge：本脚本支持 Minecraft 1.12.2 和 1.13 及以上，且需要 Forge 已发布对应版本"
    } else {
        $list = Get-NeoForgeVersions $mc; $name = 'NeoForge'
        $why = "NeoForge 没有适用于 Minecraft $($mc) 的版本（NeoForge 从 1.20.1 开始才有）"
    }
    $default = $null
    if ($kind -eq 'forge') {
        $default = @($list | Where-Object { $_.Tag -eq '推荐版' })[0]
        if (-not $default) { $default = @($list | Where-Object { $_.Tag -eq '最新版' })[0] }
    } else {
        $default = @($list | Where-Object { $_.Stable })[0]
    }
    if (-not $default -and $list.Count -gt 0) { $default = $list[0] }
    return [pscustomobject]@{ Name = $name; List = $list; Default = $default; Why = $why }
}

function Show-LoaderList($list) {
    $line = ''
    $i = 0
    foreach ($it in $list) {
        $mark = ''
        if ($it.Tag -eq '推荐版') { $mark = ' *' } elseif (-not $it.Stable) { $mark = ' ~' }
        $line += ($it.Version + $mark).PadRight(20)
        $i++
        if ($i % 5 -eq 0) { Write-Host ('  ' + $line); $line = '' }
    }
    if ($line) { Write-Host ('  ' + $line) }
    Write-Host '  （从新到旧排列；* = 推荐版，~ = 测试版）' -ForegroundColor DarkGray
}

function Select-LoaderVersion($choices) {
    $d = $choices.Default
    $tagText = ''
    if ($d.Tag) { $tagText = '，' + $d.Tag }
    Write-Host ('  {0} 共有 {1} 个版本可选。' -f $choices.Name, $choices.List.Count)
    while ($true) {
        $in = (Read-Host ('  选择 {0} 版本（回车 = {1}{2}；list = 列出全部）' -f $choices.Name, $d.Version, $tagText)).Trim()
        if (-not $in) { return $d }
        if ($in -eq 'list') { Show-LoaderList $choices.List; continue }
        foreach ($it in $choices.List) { if ($it.Version -eq $in) { return $it } }
        Write-Err "  没有这个版本：$($in)，输入 list 查看全部。"
    }
}

# ------------------------------- 加载器安装 -------------------------------

# Fabric：取加载器的版本 JSON（它继承原版，只多出几个库），把库加入下载队列
function Add-FabricJobs([string]$mc, [string]$loader) {
    $p = '/v2/versions/loader/' + [Uri]::EscapeDataString($mc) + '/' + [Uri]::EscapeDataString($loader) + '/profile/json'
    Write-Info "正在获取 Fabric $($loader) 的安装信息..."
    $text = [Text.Encoding]::UTF8.GetString((Get-Remote (Join-Sources @('https://meta.fabricmc.net' + $p) @($BmclRoot + '/fabric-meta' + $p)) 'Fabric 安装信息' $null))
    $prof = ConvertFrom-JsonText $text
    foreach ($lib in (J $prof 'libraries')) { Add-LibraryJob $lib }
    return [pscustomobject]@{ Id = [string](J $prof 'id'); Text = $text }
}

function Read-ZipText($entry) {
    $s = $entry.Open()
    try { return [IO.StreamReader]::new($s, [Text.Encoding]::UTF8).ReadToEnd() } finally { $s.Dispose() }
}

# Forge / NeoForge：下载官方安装器，读出它的安装配置和版本 JSON，把需要的库提前加入下载队列
# （安装器发现库已存在且校验通过就不会再下，这样只剩打补丁这一步）
function Get-ForgeInstaller($loader) {
    $file = $loader.Artifact + '-' + $loader.Full + '-installer.jar'
    $rel = $loader.Group + '/' + $loader.Artifact + '/' + $loader.Full + '/' + $file
    if ($loader.Kind -eq 'Forge') { $official = 'https://maven.minecraftforge.net/' + $rel }
    else { $official = 'https://maven.neoforged.net/releases/' + $rel }
    $mirror = $BmclRoot + '/maven/' + $rel
    $sha1 = $loader.Sha1
    if (-not $sha1) {
        try {
            $t = [Text.Encoding]::ASCII.GetString((Get-Remote @($official + '.sha1') "$($loader.Kind) 安装器校验值" $null))
            if ($t -match '([0-9a-fA-F]{40})') { $sha1 = $Matches[1].ToLowerInvariant() }
        } catch {}
    }
    Write-Info "正在下载 $($loader.Kind) $($loader.Version) 安装器..."
    $bytes = Get-Remote (Join-Sources @($official) @($mirror)) "$($loader.Kind) 安装器" $sha1
    $path = $WorkDir + $file
    [IO.File]::WriteAllBytes($path, $bytes)

    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $pe = $zip.GetEntry('install_profile.json')
        if ($null -eq $pe) { throw "$($loader.Kind) 安装器里没有 install_profile.json，文件可能已损坏" }
        $instProf = ConvertFrom-JsonText (Read-ZipText $pe)
        if ($null -ne (J $instProf 'versionInfo')) { throw '这是旧式 Forge 安装器（1.12.2 之前的版本），暂不支持' }
        $jsonName = ([string](J $instProf 'json')).TrimStart('/')
        if (-not $jsonName) { $jsonName = 'version.json' }
        $ve = $zip.GetEntry($jsonName)
        if ($null -eq $ve) { throw "$($loader.Kind) 安装器里没有 $($jsonName)" }
        $verText = Read-ZipText $ve
    } finally { $zip.Dispose() }
    $verJson = ConvertFrom-JsonText $verText

    $procs = 0
    foreach ($p in (J $instProf 'processors')) {
        $sides = J $p 'sides'
        if ($null -eq $sides -or @($sides) -contains 'client') { $procs++ }
    }
    foreach ($lib in (J $instProf 'libraries')) { Add-LibraryJob $lib }
    foreach ($lib in (J $verJson 'libraries')) { Add-LibraryJob $lib }
    # 补丁步骤的最终产物（打好补丁的客户端 jar），装完后用它确认安装器真的跑完了
    $patched = $null
    $pc = [string](J $instProf 'data' 'PATCHED' 'client')
    if ($pc -match '^\[(.+)\]$') { $patched = $mcDir + 'libraries\' + (ConvertTo-MavenPath $Matches[1]).Replace('/', '\') }
    return [pscustomobject]@{
        Path = $path; Id = [string](J $verJson 'id'); Text = $verText
        Processors = $procs; Inherits = [string](J $verJson 'inheritsFrom'); Patched = $patched
    }
}

# 把压缩包里以 $prefix 开头的文件解压到 $dest（覆盖同名文件，拒绝越界路径），返回解压的文件数
function Expand-ZipPrefix($zip, [string]$prefix, [string]$dest) {
    $count = 0
    foreach ($e in $zip.Entries) {
        $n = $e.FullName.Replace('\', '/')
        if ($prefix -and -not $n.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rel = $n.Substring($prefix.Length)
        if (-not $rel -or $rel.EndsWith('/')) { continue }
        $target = Resolve-InsidePath $dest $rel
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        $count++
    }
    return $count
}

# 运行官方安装器的命令行模式（--installClient），它会给游戏 jar 打补丁并写好版本文件
function Invoke-ForgeInstaller([string]$java, [string]$installer, [string]$mc, [string]$logFile) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $java
    # useSystemProxies：让安装器（下载 Mojang 映射文件时）也走系统代理
    $psi.Arguments = '-Djava.net.useSystemProxies=true -jar "' + $installer + '" "--installClient=' + $mc.TrimEnd('\') + '"'
    $psi.WorkingDirectory = [IO.Path]::GetDirectoryName($installer)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $tail = [System.Collections.Generic.Queue[string]]::new()
    $log = [IO.StreamWriter]::new($logFile, $false, [Text.UTF8Encoding]::new($false))
    try {
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            $log.WriteLine($line)
            $tail.Enqueue($line)
            if ($tail.Count -gt 15) { [void]$tail.Dequeue() }
            $show = $line.Trim()
            if ($show.Length -gt 72) { $show = $show.Substring(0, 72) }
            Write-Host -NoNewline ("`r    " + $show.PadRight(76))
        }
        $p.WaitForExit()
        $err = $errTask.GetAwaiter().GetResult()
        if ($err) { $log.WriteLine($err) }
    } finally { $log.Dispose() }
    Write-Host ''
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Tail = @($tail.ToArray()); Err = [string]$err }
}

# ------------------------------- Java -------------------------------

# 读 Java 主版本号：先看 Java 目录里的 release 文件，没有再运行 java -version
function Get-JavaMajor([string]$exe) {
    try {
        $jhome = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($exe))
        $ver = $null
        $rel = $jhome + '\release'
        if ([IO.File]::Exists($rel)) {
            foreach ($line in [IO.File]::ReadAllLines($rel)) {
                if ($line -match '^JAVA_VERSION="?([^"]+)"?') { $ver = $Matches[1]; break }
            }
        }
        if (-not $ver) {
            $psi = [Diagnostics.ProcessStartInfo]::new($exe, '-version')
            $psi.UseShellExecute = $false
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $p = [Diagnostics.Process]::Start($psi)
            $out = $p.StandardError.ReadToEnd() + $p.StandardOutput.ReadToEnd()
            [void]$p.WaitForExit(10000)
            if ($out -match 'version "([^"]+)"') { $ver = $Matches[1] }
        }
        if (-not $ver) { return 0 }
        if ($ver -match '^1\.(\d+)') { return [int]$Matches[1] }   # 1.8.0_381 → 8
        if ($ver -match '^(\d+)') { return [int]$Matches[1] }      # 17.0.8 → 17
    } catch {}
    return 0
}

# 找一个主版本号正好是 $major 的 Java（Forge 的安装器和补丁工具要用和游戏一样的 Java 版本，避免老工具在新 Java 上出错）
function Find-Java([int]$major) {
    $cands = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$p)
        if ($p -and [IO.File]::Exists($p) -and -not $cands.Contains($p)) { $cands.Add($p) }
    }
    # 1. Mojang / PCL2 下载的 Java（%APPDATA%\.minecraft\runtime 和当前 MC 文件夹的 runtime）
    foreach ($root in @(((Add-Slash ([Environment]::GetFolderPath('ApplicationData'))) + '.minecraft\runtime'), ($mcDir + 'runtime'))) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        foreach ($d in [IO.Directory]::GetDirectories($root)) {
            & $add ($d + '\bin\java.exe')
            $comp = [IO.Path]::GetFileName($d)
            & $add ($d + '\windows-x64\' + $comp + '\bin\java.exe')
            & $add ($d + '\windows-arm64\' + $comp + '\bin\java.exe')
        }
    }
    # 2. PCL2 记录的 Java 列表（旧版 PCL2 存在注册表 LaunchArgumentJavaAll）
    try {
        $pclJava = Read-PclReg 'LaunchArgumentJavaAll'
        if ($pclJava) {
            foreach ($e in (ConvertFrom-JsonText $pclJava)) {
                $jp = [string](J $e 'Path')
                if (-not $jp) { continue }
                if ($jp.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $jp = [IO.Path]::GetDirectoryName($jp) }
                $jp = Add-Slash $jp
                & $add ($jp + 'java.exe')
                & $add ($jp + 'bin\java.exe')
            }
        }
    } catch {}
    # 3. JAVA_HOME、PATH
    if ($env:JAVA_HOME) { & $add ((Add-Slash $env:JAVA_HOME) + 'bin\java.exe') }
    foreach ($d in ([string]$env:Path).Split(';')) { if ($d) { & $add ((Add-Slash $d.Trim('"')) + 'java.exe') } }
    # 4. 注册表里登记的 Java
    foreach ($k in 'HKLM:\SOFTWARE\JavaSoft\Java Runtime Environment', 'HKLM:\SOFTWARE\JavaSoft\JRE', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit', 'HKLM:\SOFTWARE\JavaSoft\JDK') {
        try {
            foreach ($sk in (Get-ChildItem -LiteralPath $k -ErrorAction Stop)) {
                $jh = (Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue).JavaHome
                if ($jh) { & $add ((Add-Slash $jh) + 'bin\java.exe') }
            }
        } catch {}
    }
    # 5. 常见安装目录
    $pfs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    foreach ($pf in $pfs) {
        foreach ($vendor in 'Java', 'Eclipse Adoptium', 'Eclipse Foundation', 'AdoptOpenJDK', 'Microsoft', 'Zulu', 'BellSoft', 'Amazon Corretto', 'Semeru', 'Azul') {
            $vd = (Add-Slash $pf) + $vendor
            if (-not [IO.Directory]::Exists($vd)) { continue }
            foreach ($jd in [IO.Directory]::GetDirectories($vd)) { & $add ($jd + '\bin\java.exe') }
        }
    }
    foreach ($c in $cands) {
        if ((Get-JavaMajor $c) -eq $major) { return $c }
    }
    return $null
}

# 没有合适的 Java 时：下载 Mojang 官方的 Java 运行时，放到 PCL2 下载 Java 时用的同一个位置
function Add-JavaRuntimeJobs([string]$component) {
    $all = Get-JsonRemote (Get-Urls $JavaRuntimeIndex) 'Java 下载列表'
    $cpu = $env:PROCESSOR_ARCHITEW6432
    if (-not $cpu) { $cpu = $env:PROCESSOR_ARCHITECTURE }
    $plats = @('windows-x86')
    if ($cpu -eq 'ARM64') { $plats = @('windows-arm64', 'windows-x64') }
    elseif ([Environment]::Is64BitOperatingSystem) { $plats = @('windows-x64') }
    $entry = $null
    foreach ($pl in $plats) {
        $list = J $all $pl $component
        if ($null -ne $list -and @($list).Count -gt 0) { $entry = @($list)[0]; break }
    }
    if ($null -eq $entry) { throw "Mojang 没有提供 $($component) 的 Windows 版 Java，请自行安装后重试" }
    $man = ConvertFrom-JsonText ([Text.Encoding]::UTF8.GetString((Get-Remote (Get-Urls (J $entry 'manifest' 'url')) 'Java 文件清单' (J $entry 'manifest' 'sha1'))))
    $dir = (Add-Slash ([Environment]::GetFolderPath('ApplicationData'))) + '.minecraft\runtime\' + $component + '\'
    # 与 PCL2 相同：跳过 3 个大量重复、没有实际用处的文件
    $skip = @('12976a6c2b227cbac58969c1455444596c894656', 'c80e4bab46e34d02826eab226a4441d0970f2aba', '84d2102ad171863db04e7ee22a259d1f6c5de4a5')
    foreach ($kv in (J $man 'files').GetEnumerator()) {
        $raw = J $kv.Value 'downloads' 'raw'
        if ($null -eq $raw) { continue }   # 目录、链接
        $sha = [string](J $raw 'sha1')
        if ($skip -contains $sha) { continue }
        Add-Job (J $raw 'url') ($dir + $kv.Key.Replace('/', '\')) $sha (J $raw 'size')
    }
    return [pscustomobject]@{ Dir = $dir; Exe = $dir + 'bin\java.exe'; Name = [string](J $entry 'version' 'name') }
}

# ------------------------------- Modrinth 整合包 -------------------------------

# 版本名里不能有 Windows 不允许的字符；PCL2 还不允许 ! 和 ;
function Get-SafeName([string]$name) {
    $n = [string]$name
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace([string]$c, '') }
    return $n.Replace('!', '').Replace(';', '').Trim().TrimEnd('.')
}

# 整合包里的相对路径 → 版本文件夹里的绝对路径；拒绝 .. 或绝对路径之类跳出目标文件夹的写法
function Resolve-InsidePath([string]$root, [string]$rel) {
    $rootFull = Add-Slash ([IO.Path]::GetFullPath($root))
    $p = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $rel.Replace('/', '\').TrimStart('\')))
    if (-not $p.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "整合包里有越出版本文件夹的文件路径，已拒绝安装：$($rel)"
    }
    return $p
}

# Modrinth 的下载地址 → 国内 MCIM 镜像（PCL2 也用它），只作为官方地址失败时的备用
function ConvertTo-McimUrl([string]$u) {
    $m = $u -replace '^https?://cdn\.modrinth\.com/', 'https://mod.mcimirror.top/'
    if ($m -eq $u) { return $null }
    return $m
}

# 读取 .mrpack：modrinth.index.json 写明了 MC 版本、加载器，以及每个文件的下载地址、SHA1、大小
function Read-Mrpack([string]$file) {
    try { $zip = [IO.Compression.ZipFile]::OpenRead($file) }
    catch { throw '打不开这个文件：它可能已损坏，或者不是 zip / mrpack 格式' }
    $entry = $zip.GetEntry('modrinth.index.json')
    if ($null -eq $entry) { $zip.Dispose(); throw '这不是 Modrinth 整合包：压缩包根目录里没有 modrinth.index.json' }
    $idx = ConvertFrom-JsonText (Read-ZipText $entry)
    if ((J $idx 'game') -and (J $idx 'game') -ne 'minecraft') { $zip.Dispose(); throw "这个整合包不是 Minecraft 的（game = $(J $idx 'game')）" }
    $deps = J $idx 'dependencies'
    $mc = [string](J $deps 'minecraft')
    if (-not $mc) { $zip.Dispose(); throw '整合包里没有写明 Minecraft 版本' }

    $loader = $null
    $loaderCount = 0
    $bad = @()
    foreach ($k in @($deps.Keys)) {
        $v = [string]$deps[$k]
        if ($k -eq 'minecraft') { continue }
        if ($k -eq 'fabric-loader') {
            $loader = [pscustomobject]@{ Kind = 'Fabric'; Mc = $mc; Version = $v; Stable = $true; Tag = '' }
            $loaderCount++
        } elseif ($k -eq 'forge') {
            $short = $v -replace ('^' + [regex]::Escape($mc) + '-'), ''
            $loader = New-ForgeItem $mc $short ($mc + '-' + $short) $null
            $loaderCount++
        } elseif ($k -eq 'neoforge') {
            $loader = New-NeoForgeItem $mc $v
            $loaderCount++
        } elseif ($k -eq 'quilt-loader') {
            $bad += 'Quilt'
        } else {
            $bad += $k
        }
    }
    if ($bad.Count -gt 0) { $zip.Dispose(); throw "这个整合包需要 $($bad -join '、') 加载器，目前只支持 Fabric、Forge、NeoForge" }
    if ($loaderCount -gt 1) { $zip.Dispose(); throw '这个整合包同时写了多个加载器，无法安装' }
    if ($null -ne $loader -and $loader.Kind -eq 'Forge') {
        $ok = Test-ForgeSupported $mc
        if ($ok -and $mc -eq '1.12.2') {
            $parts = $loader.Version.Split('.')
            $build = 0
            $ok = ($parts.Count -ge 4 -and [int]::TryParse($parts[3], [ref]$build) -and $build -ge 2851)
        }
        if (-not $ok) { $zip.Dispose(); throw "这个整合包用的是 Minecraft $($mc) 的旧版 Forge（$($loader.Version)），本脚本只支持 1.12.2（14.23.5.2851 之后）和 1.13 及以上的 Forge" }
    }

    $files = [System.Collections.Generic.List[object]]::new()
    $optional = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (J $idx 'files')) {
        $client = [string](J $f 'env' 'client')
        if ($client -eq 'unsupported') { continue }   # 仅服务端需要的文件
        $d = J $f 'downloads'
        $item = [pscustomobject]@{ Rel = [string](J $f 'path'); Urls = @($d); Sha1 = [string](J $f 'hashes' 'sha1'); Size = (J $f 'fileSize') }
        if ($client -eq 'optional') { $optional.Add($item) } else { $files.Add($item) }
    }
    return [pscustomobject]@{
        Zip = $zip; File = $file; Name = [string](J $idx 'name'); Version = [string](J $idx 'versionId')
        Mc = $mc; Loader = $loader; Files = $files; Optional = $optional
    }
}

# 询问版本名：不能和原版文件夹同名；已存在时可以选择覆盖安装到它里面
function Read-VersionName([string]$default, [string]$vanillaId) {
    while ($true) {
        $in = $default
        if ($Interactive) {
            $t = (Read-Host "  版本名称（回车 = $($default)）").Trim()
            if ($t) { $in = $t }
        }
        $safe = Get-SafeName $in
        if (-not $safe -or $safe -ne $in.Trim()) {
            if (-not $Interactive) { throw "版本名称无效：$($in)" }
            Write-Err '  名称不能为空，也不能包含 \ / : * ? " < > | ! ; 这些字符。'
            continue
        }
        if ($safe -eq $vanillaId) {
            if (-not $Interactive) { throw "版本名称不能和原版 $($vanillaId) 相同" }
            Write-Err "  名称不能和原版 $($vanillaId) 相同，那是原版自己的文件夹。"
            continue
        }
        if ([IO.Directory]::Exists($mcDir + 'versions\' + $safe)) {
            if (-not $Interactive) { throw "已经有一个叫「$($safe)」的版本了，请换个名字" }
            $yn = Read-Host "  已经有一个叫「$($safe)」的版本。输入 y 覆盖安装到它里面（保留其中的 Mod、存档和配置；如果它原来是别的加载器，里面的 Mod 可能不兼容），直接回车则换一个名字"
            if (Test-Yes $yn) { return [pscustomobject]@{ Name = $safe; Existing = $true } }
            $default = $safe + '-2'
            continue
        }
        return [pscustomobject]@{ Name = $safe; Existing = $false }
    }
}

# ------------------------------- 多线程下载 -------------------------------

# 每个工作线程从共享队列取任务；统计写在各自的哈希表里，主线程汇总显示。
# 主线程同时当“看门狗”：某个连接太久收不到数据就把它 Abort()，
# 对应的工作线程会捕获到异常并立刻换源重试（不杀线程，避免文件句柄残留）。
$Worker = {
    param($Queue, $Stat, $Failed, $Ctl, $TempFiles, $Requests, $UA)
    $buf = [byte[]]::new(81920)
    $shaFile = [Security.Cryptography.SHA1]::Create()   # 校验本地已有的文件
    $shaNet = [Security.Cryptography.SHA1]::Create()    # 边下边算，下完不必再打开文件

    function Test-Ok([string]$path, [string]$sha1, [long]$size) {
        $fi = [IO.FileInfo]::new($path)
        if (-not $fi.Exists) { return $false }
        if ($size -gt 0 -and $fi.Length -ne $size) { return $false }
        if (-not $sha1) { return $true }
        $fs = [IO.File]::OpenRead($path)
        try { $h = $shaFile.ComputeHash($fs) } finally { $fs.Dispose() }
        return ([BitConverter]::ToString($h).Replace('-', '').ToLowerInvariant() -eq $sha1.ToLowerInvariant())
    }

    # 下载到 $file，返回实际收到的大小和 SHA1
    function Save-Url([string]$url, [string]$file) {
        $Stat.Aborted = 0
        $Stat.LastData = [DateTime]::UtcNow.Ticks
        $req = [Net.WebRequest]::Create($url)
        $req.UserAgent = $UA
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 30000
        $Stat.Req = $req
        $Stat.Active = 1
        [void]$Requests.TryAdd($req, $null)   # 登记，中断时统一断开
        try {
            if ($Ctl.Cancel) { throw '下载已中断' }
            $resp = $req.GetResponse()
            try {
                $in = $resp.GetResponseStream()
                $out = [IO.File]::Create($file)
                $shaNet.Initialize()
                $got = [long]0
                try {
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                        [void]$shaNet.TransformBlock($buf, 0, $n, $null, 0)
                        $got += $n
                        $Stat.Bytes += $n
                        $Stat.LastData = [DateTime]::UtcNow.Ticks
                    }
                } finally { $out.Dispose(); $in.Dispose() }
                [void]$shaNet.TransformFinalBlock($buf, 0, 0)
                return [pscustomobject]@{ Size = $got; Sha1 = [BitConverter]::ToString($shaNet.Hash).Replace('-', '').ToLowerInvariant() }
            } finally { $resp.Close() }
        } finally {
            $Stat.Active = 0
            $Stat.Req = $null
            $o = $null
            [void]$Requests.TryRemove($req, [ref]$o)
        }
    }

    # 杀毒软件等常在文件刚写完时短暂占用它，改名失败就等一会儿再试（最多约 20 秒）
    function Move-Retry([string]$src, [string]$dst) {
        $i = 0
        while ($true) {
            $i++
            try {
                if ([IO.File]::Exists($dst)) { [IO.File]::Delete($dst) }
                [IO.File]::Move($src, $dst)
                return
            } catch {
                if ($i -ge 15) { throw }
                [Threading.Thread]::Sleep([Math]::Min(200 * $i, 2000))
            }
        }
    }

    # 删掉后从登记表移除；删不掉（仍被占用）就留在登记表里，等全部下完或中断时统一清理
    function Remove-Tmp([string]$p) {
        try {
            if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) }
            $o = $null
            [void]$TempFiles.TryRemove($p, [ref]$o)
        } catch {}
    }

    $job = $null
    while (-not $Ctl.Cancel -and $Queue.TryDequeue([ref]$job)) {
        try {
            if (Test-Ok $job.Path $job.Sha1 $job.Size) {
                $Stat.Skipped++
            } else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($job.Path))
                $want = ([string]$job.Sha1).ToLowerInvariant()
                $ok = $false
                $err = ''
                for ($round = 0; $round -lt 3 -and -not $ok -and -not $Ctl.Cancel; $round++) {
                    foreach ($u in @($job.Urls)) {
                        if ($Ctl.Cancel) { break }
                        # 每次尝试都用新的临时文件名，避免撞上仍被占用的上一个
                        $tmp = $job.Path + '.' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.mcdl'
                        [void]$TempFiles.TryAdd($tmp, $null)   # 登记，中断时统一删除
                        $aborted = $false
                        try {
                            $r = Save-Url $u $tmp
                            if (($job.Size -le 0 -or $r.Size -eq $job.Size) -and (-not $want -or $r.Sha1 -eq $want)) {
                                Move-Retry $tmp $job.Path
                                $o = $null
                                [void]$TempFiles.TryRemove($tmp, [ref]$o)
                                $ok = $true
                                break
                            }
                            $err = 'SHA1/大小校验失败'
                        } catch {
                            $e = $_.Exception
                            while ($e.InnerException) { $e = $e.InnerException }
                            $err = $e.Message
                            if ($Stat.Aborted -eq 1) { $aborted = $true; $err = '连接无响应，已断开重试' }
                        }
                        Remove-Tmp $tmp
                        if (-not $aborted -and -not $Ctl.Cancel) { [Threading.Thread]::Sleep(200 + 500 * $round) }
                    }
                }
                if ($ok) {
                    $Stat.Ok++
                } else {
                    $Stat.Failed++
                    $Failed.Enqueue($job.Path + '  (' + $err + ')')
                }
            }
        } catch {
            $Stat.Failed++
            $Failed.Enqueue($job.Path + '  (' + $_.Exception.Message + ')')
        } finally {
            $Stat.Done++
        }
    }
    $shaFile.Dispose()
    $shaNet.Dispose()
}

function Invoke-Downloads($jobList, [int]$threads) {
    # 大文件先下，避免最后只剩一个大 jar 单线程慢慢跑
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    foreach ($j in ($jobList | Sort-Object -Property Size -Descending)) { $queue.Enqueue($j) }
    $failed = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $count = [Math]::Max(1, [Math]::Min($threads, $jobList.Count))

    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $count, $iss, $Host)
    $pool.Open()
    $workers = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $count; $i++) {
        $st = [hashtable]::Synchronized(@{
            Done = 0; Ok = 0; Skipped = 0; Failed = 0; Bytes = [long]0
            Active = 0; LastData = [long]0; Req = $null; Aborted = 0
        })
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($Worker).AddArgument($queue).AddArgument($st).AddArgument($failed).AddArgument($Ctl).AddArgument($TempFiles).AddArgument($Requests).AddArgument($UserAgent)
        $workers.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Stat = $st })
    }

    $total = $jobList.Count
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastBytes = [long]0
    $lastDone = 0
    $lastTime = 0.0
    $speed = 0.0
    $fps = 0.0
    $aborts = 0
    while ($true) {
        $finished = $true
        foreach ($w in $workers) { if (-not $w.Handle.IsCompleted) { $finished = $false; break } }
        $done = 0; $ok = 0; $skip = 0; $fail = 0; $active = 0; $bytes = [long]0
        foreach ($w in $workers) {
            $s = $w.Stat
            $done += $s.Done; $ok += $s.Ok; $skip += $s.Skipped; $fail += $s.Failed; $active += $s.Active; $bytes += $s.Bytes
        }
        $now = $sw.Elapsed.TotalSeconds
        if ($now - $lastTime -ge 0.9) {
            $span = $now - $lastTime
            $inst = ($bytes - $lastBytes) / $span
            $instF = ($done - $lastDone) / $span
            if ($speed -eq 0) { $speed = $inst } else { $speed = $speed * 0.6 + $inst * 0.4 }
            if ($fps -eq 0) { $fps = $instF } else { $fps = $fps * 0.6 + $instF * 0.4 }
            $lastBytes = $bytes
            $lastDone = $done
            $lastTime = $now
        }
        $pct = 100.0
        if ($total -gt 0) { $pct = 100.0 * $done / $total }

        # 看门狗：正在传输却太久收不到数据的连接直接断开，对应线程会立刻换源重试
        $limit = $StallSeconds
        if ($pct -ge $TailPercent) { $limit = $TailStallSeconds }
        if ($limit -gt 0 -and -not $finished) {
            $limitTicks = [long]($limit * 10000000)
            foreach ($w in $workers) {
                $s = $w.Stat
                $r = $s.Req
                if ($null -ne $r -and $s.Active -eq 1 -and ([DateTime]::UtcNow.Ticks - [long]$s.LastData) -gt $limitTicks) {
                    $s.Aborted = 1
                    $s.LastData = [DateTime]::UtcNow.Ticks
                    try { $r.Abort() } catch {}
                    $aborts++
                }
            }
        }

        # “并发”= 此刻正在传输的连接数；“断开”= 看门狗断开重试的次数
        $line = '  [{0,5:N1}%] {1}/{2}  {3}/s  {4:N0} 个/s  并发 {5,2}  已下 {6}  失败 {7}  断开 {8}' -f $pct, $done, $total, (Format-Size $speed), $fps, $active, (Format-Size $bytes), $fail, $aborts
        Write-Host -NoNewline ("`r" + $line.PadRight(90))
        if ($finished) { break }
        Start-Sleep -Milliseconds 400
    }
    Write-Host ''

    foreach ($w in $workers) {
        try { [void]$w.PS.EndInvoke($w.Handle) } catch { Write-Err "  工作线程异常：$($_.Exception.Message)" }
        $w.PS.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    # 收尾：清理当时被占用、没删掉的临时文件（最多再等约 3 秒）
    for ($i = 0; $i -lt 10 -and $TempFiles.Count -gt 0; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds 300 }
        foreach ($p in @($TempFiles.Keys)) {
            try {
                if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) }
                $o = $null
                [void]$TempFiles.TryRemove($p, [ref]$o)
            } catch {}
        }
    }

    return [pscustomobject]@{
        Total = $total; Ok = $ok; Skipped = $skip; Failed = $fail; Bytes = $bytes; Aborts = $aborts
        FailedList = @($failed.ToArray()); Seconds = $sw.Elapsed.TotalSeconds
    }
}

# 下完后如果有失败的文件，等几秒把它们单独再下一轮
function Invoke-DownloadsWithRetry($jobList, [int]$threads) {
    $r = Invoke-Downloads $jobList $threads
    if ($r.Failed -le 0 -or $Ctl.Cancel) { return $r }
    $byPath = @{}
    foreach ($j in $jobList) { $byPath[$j.Path] = $j }
    $retry = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $r.FailedList) {
        $i = $s.IndexOf('  (')
        $pth = $s
        if ($i -gt 0) { $pth = $s.Substring(0, $i) }
        if ($byPath.ContainsKey($pth)) { $retry.Add($byPath[$pth]) }
    }
    if ($retry.Count -eq 0) { return $r }
    Write-Warn2 "  有 $($retry.Count) 个文件下载失败，3 秒后单独再试一轮..."
    Start-Sleep -Seconds 3
    $r2 = Invoke-Downloads $retry $threads
    return [pscustomobject]@{
        Total = $r.Total; Ok = $r.Ok + $r2.Ok; Skipped = $r.Skipped + $r2.Skipped; Failed = $r2.Failed
        Bytes = $r.Bytes + $r2.Bytes; Aborts = $r.Aborts + $r2.Aborts
        FailedList = $r2.FailedList; Seconds = $r.Seconds + $r2.Seconds + 3
    }
}

# ------------------------------- 主流程 -------------------------------

try {
    Write-Host ''
    Write-Host '  ======================================================' -ForegroundColor DarkCyan
    Write-Host '     Minecraft 下载器   原版 / Fabric / Forge / NeoForge' -ForegroundColor DarkCyan
    Write-Host '                        Modrinth 整合包（.mrpack）' -ForegroundColor DarkCyan
    Write-Host "     项目主页：$($RepoUrl)" -ForegroundColor DarkGray
    Write-Host '  ======================================================' -ForegroundColor DarkCyan
    Write-Host ''

    # ---- 命令行参数（顺序随意）：版本号 / bmcl|official / 线程数 / fabric|forge|neoforge / 整合包文件 ----
    $argVersion = $null; $argSource = $null; $argThreads = 0; $argPack = $null; $argLoader = $null
    $cliArgs = @(foreach ($m in [regex]::Matches([string]$env:MCDL_ARGS, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    })
    $cliArgs = @($cliArgs | Where-Object { $_ })
    foreach ($a in $cliArgs) {
        $n = 0
        if ($a -match '\.(mrpack|zip)$' -and [IO.File]::Exists($a)) { $argPack = [IO.Path]::GetFullPath($a) }
        elseif ([int]::TryParse($a, [ref]$n)) { $argThreads = $n }
        elseif ($a -match '^(bmcl|bmclapi|mirror)$') { $argSource = 'bmcl' }
        elseif ($a -match '^(official|mojang)$') { $argSource = 'official' }
        elseif ($a -match '^(fabric|forge|neoforge)$') { $argLoader = $a.ToLowerInvariant() }
        else { $argVersion = $a }
    }
    # 把整合包拖到 bat 上也算交互模式（还要问版本名等）
    $Interactive = ($cliArgs.Count -eq 0) -or [bool]$argPack

    # ---- 定位 PCL2 与 MC 文件夹 ----
    $pclDir = $null
    $scriptDir = Add-Slash $env:MCDL_DIR
    if (Test-PclDir $scriptDir) {
        $pclDir = $scriptDir
    } elseif ($Interactive) {
        Write-Warn2 '脚本所在文件夹里没有找到 PCL2。'
        while ($true) {
            $in = (Read-Host '把 PCL2 的 exe 或它所在的文件夹拖进本窗口后回车（直接回车 = 不用 PCL2，下到官方 .minecraft）').Trim().Trim('"')
            if (-not $in) { break }
            if ([IO.File]::Exists($in)) { $in = [IO.Path]::GetDirectoryName($in) }
            $in = Add-Slash $in
            if (Test-PclDir $in) { $pclDir = $in; break }
            Write-Err '这里看起来不是 PCL2 的文件夹（没有 PCL\Setup.ini 或 PCL2 的 exe），请重新输入。'
        }
    } else {
        Write-Warn2 '脚本所在文件夹里没有找到 PCL2，将使用官方启动器的 .minecraft 文件夹。'
    }

    if ($pclDir) {
        Write-Info "PCL2 位置：$($pclDir)"
        $mc = Resolve-PclMcFolder $pclDir
    } else {
        $mc = @{ Path = (Add-Slash ([Environment]::GetFolderPath('ApplicationData'))) + '.minecraft\'; Reason = '官方启动器默认文件夹' }
    }
    $mcDir = $mc.Path
    Write-Info "MC 文件夹：$($mcDir)  （$($mc.Reason)）"

    # ---- 清理上次中断（强杀 / 断电）留下的残留 ----
    if ([IO.Directory]::Exists($mcDir)) {
        $lo = Clear-Leftovers $mcDir
        if ($lo.Files -gt 0 -or $lo.Versions -gt 0) {
            Write-Warn2 "已清理上次中断留下的 $($lo.Files) 个临时文件、$($lo.Versions) 个没装完的文件夹。"
        }
    }

    # ---- 选择要安装什么 ----
    $Mode = 'vanilla'
    if ($argPack) { $Mode = 'mrpack' }
    elseif ($argLoader) { $Mode = $argLoader }
    elseif ($cliArgs.Count -eq 0) {
        Write-Host ''
        Write-Host '  要安装什么？'
        Write-Host '    [1] 纯净原版'
        Write-Host '    [2] 原版 + Fabric'
        Write-Host '    [3] 原版 + Forge'
        Write-Host '    [4] 原版 + NeoForge'
        Write-Host '    [5] 导入 Modrinth 整合包（.mrpack）'
        $sel = (Read-Host '  请选择（默认 1）').Trim()
        if ($sel -eq '2') { $Mode = 'fabric' }
        elseif ($sel -eq '3') { $Mode = 'forge' }
        elseif ($sel -eq '4') { $Mode = 'neoforge' }
        elseif ($sel -eq '5') { $Mode = 'mrpack' }
    }

    # ---- 整合包：先读出它需要什么 ----
    $Pack = $null
    $IncludeOptional = $false
    if ($Mode -eq 'mrpack') {
        $packFile = $argPack
        while (-not $packFile) {
            $in = (Read-Host '  把 .mrpack 整合包文件拖进本窗口后回车').Trim().Trim('"')
            if (-not $in) { continue }
            if ([IO.File]::Exists($in)) { $packFile = [IO.Path]::GetFullPath($in) } else { Write-Err '  找不到这个文件，请重新拖入。' }
        }
        Write-Info "正在读取整合包：$([IO.Path]::GetFileName($packFile))"
        $Pack = Read-Mrpack $packFile
        $loaderText = '不需要加载器'
        if ($Pack.Loader) { $loaderText = $Pack.Loader.Kind + ' ' + $Pack.Loader.Version }
        Write-Host "  整合包：$($Pack.Name) $($Pack.Version)"
        Write-Host "  需要  ：Minecraft $($Pack.Mc) + $($loaderText)，共 $($Pack.Files.Count + $Pack.Optional.Count) 个文件"
        if ($Pack.Optional.Count -gt 0) {
            Write-Host "  其中有 $($Pack.Optional.Count) 个可选文件："
            foreach ($o in $Pack.Optional) { Write-Host ('    - ' + [IO.Path]::GetFileName($o.Rel)) }
            $IncludeOptional = Test-Yes (Read-Host '  要一起安装这些可选文件吗？[y/N]')
        }
    }

    # ---- 下载源与线程数：默认取 PCL2 的设置 ----
    $Threads = $MaxThreads
    $n = 0
    if ([int]::TryParse([string](Read-PclReg 'ToolDownloadThread'), [ref]$n)) { $Threads = $n + 1 }
    $UseBmcl = ((Read-PclReg 'ToolDownloadSource') -ne '2')   # PCL2：2 = 尽量用官方源
    if ($argSource) { $UseBmcl = ($argSource -eq 'bmcl') }
    if ($argThreads -gt 0) { $Threads = $argThreads }
    $Threads = [Math]::Max(1, [Math]::Min($MaxThreads, $Threads))

    if ($Interactive) {
        Write-Host ''
        $defSrc = '2'
        if ($UseBmcl) { $defSrc = '1' }
        $s = (Read-Host "下载源：[1] BMCLAPI 镜像（国内推荐）  [2] 官方源    默认 $($defSrc)").Trim()
        if ($s -eq '1') { $UseBmcl = $true } elseif ($s -eq '2') { $UseBmcl = $false }
        $t = (Read-Host "下载线程数 1-$($MaxThreads)    默认 $($Threads)").Trim()
        $n = 0
        if ([int]::TryParse($t, [ref]$n)) { $Threads = [Math]::Max(1, [Math]::Min($MaxThreads, $n)) }
    }

    # ---- 版本列表 ----
    Write-Host ''
    Write-Info '正在获取版本列表...'
    $swList = [Diagnostics.Stopwatch]::StartNew()
    $manifest = ConvertFrom-JsonText ([Text.Encoding]::UTF8.GetString((Get-Remote (Get-Urls $OfficialManifest) '版本列表' $null)))
    $listFrom = Get-SourceName ([string]$global:McdlRemoteFrom)
    $versions = J $manifest 'versions'
    $latestRelease = J $manifest 'latest' 'release'
    $latestSnapshot = J $manifest 'latest' 'snapshot'
    $vmap = @{}
    foreach ($v in $versions) { $vmap[[string](J $v 'id')] = $v }
    Write-Host ('  最新正式版：{0}    最新快照：{1}    （来自 {2}，用时 {3:N1} 秒）' -f $latestRelease, $latestSnapshot, $listFrom, $swList.Elapsed.TotalSeconds)

    # ---- 选择 Minecraft 版本（装加载器时顺便确认这个版本有对应的加载器） ----
    $VersionId = $null
    $Choices = $null
    if ($Pack) {
        if (-not $vmap.ContainsKey($Pack.Mc)) { throw "版本列表里没有整合包需要的 Minecraft $($Pack.Mc)" }
        $VersionId = [string](J ($vmap[$Pack.Mc]) 'id')
    }
    $useArg = [bool]$argVersion
    while (-not $VersionId) {
        $cand = $null
        if ($useArg) {
            $useArg = $false
            $a = $argVersion
            if ($a -eq 'latest') { $a = $latestRelease } elseif ($a -eq 'snapshot') { $a = $latestSnapshot }
            if ($vmap.ContainsKey($a)) { $cand = [string](J ($vmap[$a]) 'id') }
            elseif (-not $Interactive) { throw "找不到版本 $($a)" }
            else { Write-Err "  找不到版本 $($a)" }
        } elseif (-not $Interactive) {
            $cand = $latestRelease
        } else {
            $in = (Read-Host "输入 Minecraft 版本号（回车 = $($latestRelease)；list = 列出正式版；snap = 列出最近快照）").Trim()
            if ($in -eq '' -or $in -eq 'latest') { $cand = $latestRelease }
            elseif ($in -eq 'snapshot') { $cand = $latestSnapshot }
            elseif ($in -eq 'list') { Show-Versions 'release' 0; continue }
            elseif ($in -eq 'snap') { Show-Versions 'snapshot' 42; continue }
            elseif ($vmap.ContainsKey($in)) { $cand = [string](J ($vmap[$in]) 'id') }
            else { Write-Err "  找不到版本 $($in)，输入 list 查看可用版本。"; continue }
        }
        if (-not $cand) { continue }
        if ($Mode -eq 'fabric' -or $Mode -eq 'forge' -or $Mode -eq 'neoforge') {
            Write-Info "正在获取 Minecraft $($cand) 可用的加载器版本..."
            try { $ch = Get-LoaderChoices $Mode $cand }
            catch {
                if (-not $Interactive) { throw }
                Write-Err ('  ' + $_.Exception.Message + '（可以再输入一次版本号重试）')
                continue
            }
            if ($ch.List.Count -eq 0) {
                if (-not $Interactive) { throw $ch.Why }
                Write-Err ('  ' + $ch.Why + '，请换一个 Minecraft 版本。')
                continue
            }
            $Choices = $ch
        }
        $VersionId = $cand
    }

    # ---- 选择加载器版本 ----
    $Loader = $null
    if ($Pack) { $Loader = $Pack.Loader }
    elseif ($Choices) {
        if ($Interactive) { $Loader = Select-LoaderVersion $Choices } else { $Loader = $Choices.Default }
    }

    # ---- 版本名称（纯净原版直接用版本号；其他都新建一个独立的版本文件夹） ----
    $InstName = $null
    $InstExisting = $false
    if ($Mode -ne 'vanilla') {
        if ($Pack) {
            $def = Get-SafeName $Pack.Name
            if (-not $def) { $def = Get-SafeName ([IO.Path]::GetFileNameWithoutExtension($Pack.File)) }
            if (-not $def) { $def = 'Modpack' }
        } elseif ($Loader.Kind -eq 'Fabric') { $def = '{0}-Fabric {1}' -f $VersionId, $Loader.Version }
        elseif ($Loader.Kind -eq 'Forge') { $def = '{0}-Forge_{1}' -f $VersionId, $Loader.Version }
        else { $def = '{0}-NeoForge_{1}' -f $VersionId, $Loader.Version }
        $def = Get-SafeName $def
        Write-Host ''
        $nm = Read-VersionName $def $VersionId
        $InstName = $nm.Name
        $InstExisting = $nm.Existing
    }
    $instDir = $null
    if ($InstName) { $instDir = $mcDir + 'versions\' + $InstName + '\' }

    # ---- 列出要下载的文件 ----
    Write-Host ''
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $WorkDir = $null
    $van = Add-VanillaJobs $VersionId
    $nVanilla = $jobs.Count

    $fab = $null; $forge = $null; $javaExe = $null; $javaPlan = $null
    if ($Loader -and $Loader.Kind -eq 'Fabric') {
        $fab = Add-FabricJobs $VersionId $Loader.Version
    } elseif ($Loader) {
        $WorkDir = New-WorkDir
        $forge = Get-ForgeInstaller $Loader
        if ($forge.Inherits -and $forge.Inherits -ne $VersionId) { throw "$($Loader.Kind) $($Loader.Version) 是给 Minecraft $($forge.Inherits) 用的，与所选的 $($VersionId) 不符" }
        if ($forge.Processors -gt 0) {
            # 安装器要用 Java 运行补丁工具：用 MC 要求的那个 Java 版本
            $needJava = [int](J $van.Json 'javaVersion' 'majorVersion')
            if ($needJava -le 0) { $needJava = 8 }
            $component = [string](J $van.Json 'javaVersion' 'component')
            if (-not $component) { $component = 'jre-legacy' }
            Write-Info "正在查找 Java $($needJava)（$($Loader.Kind) 安装器需要）..."
            $javaExe = Find-Java $needJava
            if (-not $javaExe) {
                Write-Warn2 "  电脑上没有找到 Java $($needJava)，将下载 Mojang 官方的 Java（$($component)）。"
                $javaPlan = Add-JavaRuntimeJobs $component
                $javaExe = $javaPlan.Exe
            }
        }
    }
    $nLoader = $jobs.Count - $nVanilla

    if ($Pack) {
        $packFiles = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $Pack.Files) { $packFiles.Add($f) }
        if ($IncludeOptional) { foreach ($f in $Pack.Optional) { $packFiles.Add($f) } }
        foreach ($f in $packFiles) {
            $target = Resolve-InsidePath $instDir $f.Rel
            # 整合包里的文件：先用整合包给的官方地址，MCIM 镜像只做备用
            $urls = @($f.Urls) + @(foreach ($u in $f.Urls) { ConvertTo-McimUrl $u })
            Add-JobMulti $urls $target $f.Sha1 $f.Size
        }
    }
    $nPack = $jobs.Count - $nVanilla - $nLoader

    # ---- 确认 ----
    $totalSize = [long]0
    foreach ($j in $jobs) { $totalSize += $j.Size }
    $srcText = '官方源（失败时自动切换 BMCLAPI 镜像）'
    if ($UseBmcl) { $srcText = 'BMCLAPI 镜像（失败时自动切换官方源）' }
    Write-Host ''
    if ($Pack) { Write-Host "  整合包    ：$($Pack.Name) $($Pack.Version)（Modrinth）" }
    if ($Loader) { Write-Host "  版本      ：Minecraft $($VersionId) + $($Loader.Kind) $($Loader.Version)" }
    else { Write-Host "  版本      ：Minecraft $($VersionId)  （$(J $van.Entry 'type')）" }
    if ($InstName) {
        $how = '新建'
        if ($InstExisting) { $how = '覆盖安装到已有版本' }
        Write-Host "  安装为    ：$($instDir)（$($how)，单独开启版本隔离）"
        Write-Host "  原版文件  ：$($van.Dir)（与其他版本共用，不会被修改）"
    } else {
        Write-Host "  安装到    ：$($van.Dir)"
    }
    if ($javaExe -and -not $javaPlan) { Write-Host "  Java      ：$($javaExe)" }
    if ($javaPlan) { Write-Host "  Java      ：将下载 Java $($javaPlan.Name) 到 $($javaPlan.Dir)" }
    Write-Host "  下载源    ：$($srcText)"
    Write-Host "  线程数    ：$($Threads)"
    Write-Host "  网络      ：$($ProxyText)"
    $parts = "原版 $($nVanilla)"
    if ($nLoader -gt 0) { $parts += "、加载器 / Java $($nLoader)" }
    if ($nPack -gt 0) { $parts += "、整合包 $($nPack)" }
    Write-Host "  文件      ：$($jobs.Count) 个（$($parts)），共约 $(Format-Size $totalSize)（已存在且校验通过的会跳过）"
    $javaMajor = J $van.Json 'javaVersion' 'majorVersion'
    if ($javaMajor) { Write-Host "  游戏需要  ：Java $($javaMajor)（PCL2 启动时会自动选择）" }
    Write-Host ''
    if ($Interactive) { [void](Read-Host '按回车开始安装（直接关闭窗口可取消）') }

    # ---- 打“未完成”标记 ----
    # 原版：本地还没有 JSON = 全新安装，中断时只删本脚本放进去的文件；已有的原版绝不动
    $freshVanilla = -not [IO.File]::Exists($van.JsonPath)
    [void][IO.Directory]::CreateDirectory($van.Dir)
    if ($freshVanilla) { Set-FreshMark $van.Dir $IncompleteMarker }
    # 加载器版本 / 整合包：本次新建的文件夹，中断时整个删掉；覆盖安装到已有版本时不打标记
    $freshInst = $false
    if ($instDir) {
        $freshInst = -not [IO.Directory]::Exists($instDir)
        [void][IO.Directory]::CreateDirectory($instDir)
        if ($freshInst) { Set-FreshMark $instDir $WholeMarker }
    }
    # Java：本次新建的文件夹，中断时整个删掉，避免留下一个不完整的 Java（已存在的文件夹不打标记，绝不整个删）
    $freshJava = $false
    if ($javaPlan -and -not [IO.Directory]::Exists($javaPlan.Dir)) {
        $freshJava = $true
        Set-FreshMark $javaPlan.Dir $WholeMarker
    }

    $completed = $false
    $installFailedLog = $null
    try {
        # ---- 下载 ----
        $result = Invoke-DownloadsWithRetry $jobs $Threads

        # 原版 JSON 最后写入：PCL2 以它为准识别版本（原版即使有文件没下好，PCL2 启动时也会补全）
        Save-Bytes $van.JsonPath $van.JsonBytes
        if ($freshVanilla) { Clear-FreshMark $van.Dir $IncompleteMarker }

        if ($Mode -ne 'vanilla' -and $result.Failed -gt 0) {
            # 加载器 / 整合包需要的文件不齐，就不往下安装，免得装出一个启动就崩的版本
            if ($WorkDir) { Remove-FreshDir $WorkDir }
            if ($freshJava) { Remove-FreshDir $javaPlan.Dir }
            if ($freshInst) {
                if ($Pack) { Clear-FreshMark $instDir $WholeMarker }   # 整合包已下好的文件留着，下次覆盖安装时直接跳过
                else { Remove-FreshDir $instDir }
            }
            $completed = $true
        } else {
            if ($freshJava) { Clear-FreshMark $javaPlan.Dir $WholeMarker }

            # ---- 安装加载器 ----
            if ($fab) {
                Save-VersionJson $fab.Text $fab.Id $InstName
            } elseif ($forge) {
                if ($forge.Processors -gt 0) {
                    Write-Host ''
                    Write-Info "正在运行 $($Loader.Kind) 安装器（给游戏打补丁，需要一两分钟；其间会从 Mojang 下载映射文件）..."
                    Initialize-LauncherProfiles $mcDir
                    # 安装器会写 versions\<它自己的版本名>；这个文件夹如果是本次才出现的，装完后删掉
                    $idDir = $mcDir + 'versions\' + $forge.Id + '\'
                    $madeIdDir = $false
                    if ($forge.Id -ne $InstName -and -not [IO.Directory]::Exists($idDir)) {
                        Set-FreshMark $idDir $WholeMarker
                        $madeIdDir = $true
                    }
                    $logFile = $WorkDir + 'installer.log'
                    $ir = Invoke-ForgeInstaller $javaExe $forge.Path $mcDir $logFile
                    $patchedOk = (-not $forge.Patched) -or [IO.File]::Exists($forge.Patched)
                    if ($ir.ExitCode -ne 0 -or -not $patchedOk) {
                        if ($ir.ExitCode -eq 0) { Write-Err "  安装器显示成功，但没有生成打好补丁的游戏文件：$($forge.Patched)" }
                        $installFailedLog = $scriptDir + 'MC-Downloader-install.log'
                        try { Copy-Item -LiteralPath $logFile -Destination $installFailedLog -Force } catch { $installFailedLog = $null }
                        Write-Err "  $($Loader.Kind) 安装器出错（退出码 $($ir.ExitCode)），最后几行输出："
                        foreach ($l in $ir.Tail) { Write-Err ('    ' + $l) }
                        if ($ir.Err) { Write-Err ('    ' + ((@($ir.Err.Trim() -split "`r?`n") | Select-Object -Last 3) -join ' / ')) }
                        $msg = "$($Loader.Kind) 安装失败"
                        if ($installFailedLog) { $msg += "，完整日志已保存到 $($installFailedLog)" }
                        throw $msg
                    }
                    if ($madeIdDir) { Remove-FreshDir $idDir }
                } else {
                    # 没有补丁步骤（如 Forge 1.12.2）：把安装器自带的库解压到 libraries 即可，不需要 Java
                    $iz = [IO.Compression.ZipFile]::OpenRead($forge.Path)
                    try { [void](Expand-ZipPrefix $iz 'maven/' ($mcDir + 'libraries\')) } finally { $iz.Dispose() }
                }
                Save-VersionJson $forge.Text $forge.Id $InstName
            } elseif ($Pack) {
                # 不需要加载器的整合包：复制一份原版作为独立版本
                Save-VersionJson ([Text.Encoding]::UTF8.GetString($van.JsonBytes)) $VersionId $InstName
                Copy-Item -LiteralPath ($van.Dir + $VersionId + '.jar') -Destination ($instDir + $InstName + '.jar') -Force
            }

            # ---- 整合包：解压覆盖文件（配置、资源包等）----
            if ($Pack) {
                Write-Info '正在解压整合包里的配置文件...'
                $nOv = Expand-ZipPrefix $Pack.Zip 'overrides/' $instDir
                $nOv += Expand-ZipPrefix $Pack.Zip 'client-overrides/' $instDir
                Write-Host "  已解压 $($nOv) 个文件"
                $Pack.Zip.Dispose()
            }

            if ($InstName) {
                Set-PclIsolation $instDir
                if ($freshInst) { Clear-FreshMark $instDir $WholeMarker }
            }
            if ($WorkDir) { Remove-FreshDir $WorkDir }
            $completed = $true
        }
    } finally {
        # 走到这里还没完成 = 被 Ctrl+C 或出错打断（关闭窗口由控制台事件处理器负责）
        if (-not $completed) {
            Write-Host ''
            Write-Warn2 '  安装被中断，正在清理临时文件和没装完的文件夹...'
            if ($Pack -and $Pack.Zip) { try { $Pack.Zip.Dispose() } catch {} }
            if ($CleanupReady) {
                [McdlCleanup]::Cleanup()
            } else {
                $Ctl.Cancel = $true
                foreach ($r in @($Requests.Keys)) { try { $r.Abort() } catch {} }
                Start-Sleep -Milliseconds 800
                foreach ($p in @($TempFiles.Keys)) { Remove-Quiet $p }
                foreach ($d in @($FreshList)) { [void](Clear-MarkedDir $d) }
            }
        }
    }

    Write-Host ''
    Write-Host ("  下载：新下载 {0} 个，跳过 {1} 个，失败 {2} 个，共 {3}，用时 {4:N1} 秒，卡住断开重试 {5} 次" -f $result.Ok, $result.Skipped, $result.Failed, (Format-Size $result.Bytes), $result.Seconds, $result.Aborts)
    if ($result.Failed -gt 0) {
        Write-Err '  以下文件下载失败：'
        $result.FailedList | Select-Object -First 20 | ForEach-Object { Write-Err ('    ' + $_) }
        if ($result.Failed -gt 20) { Write-Err "    ……另有 $($result.Failed - 20) 个" }
        if ($Mode -eq 'vanilla') {
            Write-Err '  重新运行本脚本可继续补全，PCL2 启动时也会自动补全。'
        } else {
            Write-Err '  因为文件不齐，这次没有继续安装。重新运行并选择同样的内容即可继续（已下好的文件会自动跳过）。'
            if ($Pack) { Write-Err "  版本名请填同一个「$($InstName)」，并输入 y 覆盖安装到它里面。" }
        }
        exit 2
    }
    Write-Host ''
    if ($Mode -eq 'vanilla') {
        Write-Host "  $($VersionId) 已就绪，打开 PCL2 的版本选择即可看到（没出现就点一下刷新）。" -ForegroundColor Green
    } else {
        Write-Host "  「$($InstName)」已安装好：打开 PCL2 → 版本选择，选中它即可启动（没出现就点一下刷新）。" -ForegroundColor Green
        Write-Host "  它已单独开启版本隔离，Mod 请放在 $($instDir)mods" -ForegroundColor Green
    }
    exit 0
} catch {
    Write-Host ''
    Write-Err ('  出错了：' + $_.Exception.Message)
    exit 1
}
