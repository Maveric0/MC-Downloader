# MC-Downloader

一个双击就能用的 Minecraft 安装脚本（只有一个 `.bat` 文件），配合 [PCL2](https://github.com/Hex-Dragon/PCL2) 使用：多线程下载原版，安装 Fabric / Forge / NeoForge，导入 Modrinth 整合包。

## 功能

- **纯净原版**：官方源 / BMCLAPI 镜像，最高 64 线程；每个文件都校验 SHA1，中断后重新运行可以接着补全
- **原版 + Fabric / Forge / NeoForge**：可以选择 Minecraft 版本和加载器版本
- **导入 Modrinth 整合包（`.mrpack`）**：装成一个单独的版本
- **跟随 PCL2 的设置**：装到 PCL2 当前选中的 MC 文件夹，默认线程数和下载源也和 PCL2 一致
- **互不冲突**：每个加载器版本和整合包都有自己的版本文件夹，并单独开启 PCL2 的版本隔离，Mod 不会混在一起
- **自动准备 Java**：Forge / NeoForge 安装时需要 Java，找不到合适的版本时会自动下载 Mojang 官方的 Java
- **中断自动清理**：按 Ctrl+C 或关闭窗口时，自动删除临时文件和没装完的文件夹

## 使用方法

1. 下载 [`MC-Downloader.bat`](MC-Downloader.bat)，放到 PCL2 的 exe 旁边（不放也可以，运行时会让你拖入 PCL2 的位置）
2. 双击运行，按提示选择要安装的内容
3. 装好后打开 PCL2，在版本选择里就能看到（没出现就点一下刷新）

导入整合包时，也可以直接把 `.mrpack` 文件拖到 bat 上。

命令行用法：

```bat
MC-Downloader.bat 1.20.1                  :: 纯净原版 1.20.1
MC-Downloader.bat 1.20.1 official 32      :: 官方源、32 线程
MC-Downloader.bat fabric 1.20.1           :: 原版 + Fabric（使用推荐 / 最新稳定版）
MC-Downloader.bat latest bmcl             :: 最新正式版，BMCLAPI 镜像
```

## 支持范围

| 内容 | 支持的 Minecraft 版本 |
|---|---|
| 纯净原版 | 全部（含快照） |
| Fabric | 1.14 及以上 |
| Forge | 1.12.2（14.23.5.2851 及之后的构建）、1.13 及以上 |
| NeoForge | 1.20.1 及以上 |
| Modrinth 整合包 | 使用 Fabric / Forge / NeoForge 或不需要加载器的 `.mrpack` |

暂不支持：CurseForge 整合包、Quilt、1.12.2 之前的 Forge。

## 系统要求

- Windows 10 / 11（使用系统自带的 PowerShell 5.1，不需要额外安装任何东西）
- 安装 Forge / NeoForge 时需要 Java；电脑上没有合适的版本时会自动下载

## 注意事项

- 自己编辑脚本后，请保存为 **UTF-8（无 BOM）** 编码、**CRLF** 换行，否则可能乱码或无法运行
- 安装 Forge / NeoForge 时，官方安装器会从 Mojang 下载一个映射文件（约 9MB），这一步不经过镜像
- Forge / NeoForge 安装失败时，完整日志会保存到 bat 旁边的 `MC-Downloader-install.log`

## 致谢

- [BMCLAPI](https://bmclapidoc.bangbang93.com/)：国内下载镜像
- [PCL2](https://github.com/Hex-Dragon/PCL2)：MC 文件夹的选择规则、版本隔离等行为参考了它的开源代码
- [MCIM](https://mod.mcimirror.top/)：Modrinth 文件的国内镜像（作为备用）
