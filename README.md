# nested-archive-unpacker

**一键剥离「套娃压缩包」** —— 自动识别真实格式、自动找密码、自动循环剥层，专治各种多层嵌套 + 改名的分享包。

`PowerShell 5.1+` · `Windows` · `MIT`

---

## 它解决什么问题

很多网盘/论坛分享的资源会被打包成这种形态：

```
外层 .tar
 └ 某某资源.zip            ← 扩展名被改过
    └ 某某资源.tar         ← 还是加密的，密码藏在目录名里
       └ 某某资源.zip      ← 真实内容
```

打包者的目的是**规避平台的自动内容扫描**，常见于正版资源、也常见于夹带恶意文件的包。特征通常是：

- 扩展名和真实格式不符（`.tar` 里装着 `zip`）
- `tar` ↔ `zip` 交替嵌套多层
- 条目名被**人为破坏**（末尾追加字节、用 GBK 编码），让自动扫描器和常规解包工具认不出来
- 密码写在目录名或文件名里（`解压码1111`、`密码：abc`）

手工处理这种包要来回试十几次，这个脚本把整个流程自动化了。

---

## 特性

| 能力 | 说明 |
|---|---|
| **真实格式识别** | 读文件头魔数，不信扩展名 |
| **自动循环剥层** | `tar` ↔ `zip` 反复套娃也能剥到底，`-MaxLayers` 防无限嵌套 |
| **自动找密码** | 从包内条目名里正则挖 `解压码/密码/提取码`，再退化到常见弱密码表 |
| **畸形文件名免疫** | `tar` 一律走「按偏移直切」，完全不解析文件名 |
| **解密速度优化** | 优先 7-Zip → bsdtar(libarchive) → Python，规避 Python `zipfile` 的慢速 ZipCrypto |
| **zip 炸弹保护** | 解出体积超过压缩包 200 倍时中止 |
| **可选杀毒预扫** | 解包前调用 Windows Defender 扫描原包 |

### 性能实测

对一个 533.9 MB、4 层嵌套（`tar→zip→tar→zip`，含 ZipCrypto 加密层）的真实包：

```
第 0 层  [TAR]  533.9 MB   成员 3 个（文件 1 个）→ 按偏移直切
第 1 层  [ZIP]  533.9 MB   条目 1 个  → 自动命中密码
第 2 层  [TAR]  533.9 MB   成员 2 个（文件 1 个）→ 按偏移直切
第 3 层  [ZIP]  533.9 MB   条目 17 个 → 真实内容
完成：17 个文件，564.7 MB，耗时 32.7 秒
```

> 对比：用 Python `zipfile` 单独解那一层加密 zip 需要 **383 秒**。差距来自 ZipCrypto 的实现方式，见 [docs/formats.md](docs/formats.md)。

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1+（系统自带）
- **可选但强烈建议**：[7-Zip](https://www.7-zip.org/) —— 处理 AES 加密和 GBK 乱码文件名最稳
- 可选：Python（用于快速试探 zip 密码，只读 1KB，秒级）
- 可选：libarchive 的 `bsdtar`（Win10 1803+ 自带 `C:\Windows\System32\tar.exe`）

脚本会自动探测这些工具，全部缺失时仍可处理未加密的 `zip`/`tar`。

**7-Zip 可以装到任意目录。** 探测顺序是「注册表登记的安装路径 → PATH → 常见默认位置」，
所以像 `D:\Winrar\7-Zip\` 这种自定义安装也能识别（7-Zip 官方安装包会写
`HKLM\SOFTWARE\7-Zip\Path64`）。

> 实测差异：同一个 533.9 MB、4 层嵌套的包，用 `bsdtar` 解要 32.7 秒，
> 用 7-Zip 只要 **17.6 秒**。

---

## 用法

### 方式一：拖拽（最省事，推荐）

把压缩包**直接拖到 `unpack.cmd` 上**，松手即解。也支持一次拖多个。

双击 `unpack.cmd` 则会提示你粘贴路径。

### 方式二：右键菜单

安装一次（只写 HKCU，不需要管理员权限）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install-context-menu.ps1
```

之后在 `.zip` / `.tar` / `.rar` / `.7z` / `.gz` 等文件上右键，选「**用 Nested Unpacker 解包**」。

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install-context-menu.ps1 -Uninstall
```

### 方式三：命令行

> 📌 下面几条是**任选其一**，不是要依次执行。它们只是同一个命令的不同参数组合。

```powershell
# 最简：丢个包进去，输出到同级的「<包名>_解出」
powershell -ExecutionPolicy Bypass -File .\unpack-nested.ps1 "D:\下载\某某资源.tar"

# 已知密码
powershell -ExecutionPolicy Bypass -File .\unpack-nested.ps1 "包.zip" -Password 1111

# 指定输出目录 + 放宽层数上限
powershell -ExecutionPolicy Bypass -File .\unpack-nested.ps1 "包.zip" -OutDir "D:\输出" -MaxLayers 60

# 保留每一层中间产物（排查问题时有用）
powershell -ExecutionPolicy Bypass -File .\unpack-nested.ps1 "包.zip" -KeepLayers

# 跳过 Defender 预扫描（大文件能省几分钟）
powershell -ExecutionPolicy Bypass -File .\unpack-nested.ps1 "包.zip" -NoScan
```

#### 嫌命令太长？设个别名

把下面这行加进你的 PowerShell 配置文件，之后只敲 `unpack 包.zip` 就行：

```powershell
Add-Content $PROFILE 'function unpack { powershell -NoProfile -ExecutionPolicy Bypass -File "D:\你的路径\unpack-nested.ps1" @args }'
```

新开一个 PowerShell 窗口生效。

> ⚠️ 直接 `.\unpack-nested.ps1` 会被 PowerShell 执行策略拦截，必须用
> `powershell -ExecutionPolicy Bypass -File` 调用（或用上面的别名）。


### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Path` | 必填 | 输入压缩包路径 |
| `-OutDir` | `<包名>_解出` | 输出目录 |
| `-Password` | 自动探测 | 解压密码 |
| `-MaxLayers` | `40` | 最大剥层数 |
| `-KeepLayers` | 关 | 保留中间层 |
| `-NoScan` | 关 | 跳过 Defender 预扫描 |

---

## 工作原理

四个关键点，也是这类包最容易卡住的地方：

### 1. 用魔数判断格式，不用扩展名

| 格式 | 特征 |
|---|---|
| ZIP | 开头 `50 4B 03 04` |
| TAR | **偏移 257** 处是 `ustar` |
| RAR | 开头 `52 61 72 21` |
| 7Z | 开头 `37 7A BC AF 27 1C` |
| GZIP | 开头 `1F 8B` |

### 2. 循环剥层，靠「解出几个文件」判断是否到底

```
单文件  → 还是包装层，继续剥
多文件  → 真实内容，停止
非压缩包 → 真实内容，停止
```

### 3. tar 走「按偏移直切」，绕开文件名

`tar` 结构极简，可以完全跳过文件名解析：

```
[512字节头][数据补齐到512][512字节头][数据...]...
头内：偏移 0-99   文件名（可能有畸形字节）
      偏移 124-135 文件大小（八进制）
      偏移 156     类型（'0'=普通文件, '5'=目录）
```

只要读第一个头 → 取大小 → 从偏移 512 复制这么多字节。**畸形名、乱码名、编码问题一律无视。**

> 这一点很关键：`bsdtar` 遇到被破坏的文件名会**静默跳过**——不报错、不失败，只是返回 0 个文件。

### 4. 解密用 C 实现，别用 Python `zipfile`

Python 的 `zipfile` 解 ZipCrypto 是**纯 Python 逐字节循环**，约 1.4 MB/s。同样一层 533.9 MB 的加密 zip：

| 工具 | 耗时 |
|---|---|
| Python `zipfile` | **383 秒** |
| libarchive (`bsdtar`) | **11 秒** |

所以脚本用 Python **只做密码试探**（读第一个条目 1KB 即可验证），实际解包交给 7-Zip 或 `bsdtar`。

更多细节见 [docs/formats.md](docs/formats.md)。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 解出来是**空的** | 文件名畸形，解包器静默跳过 | 脚本已对 tar 自动切偏移；zip 建议装 7-Zip |
| 中文名变成 `闃叉渤锜` | GBK 字节被当 UTF-8 解释 | `7z x -mcp=936` |
| 提示需要密码 | 自动探测失败 | 手动输入，或 `-Password` |
| 卡很久没输出 | 大概率是 Python 在解大加密包 | 装 7-Zip，脚本会自动优先用它 |
| 层数太多剥不完 | `-MaxLayers` 到顶 | 调大上限；若体积不收敛则疑似恶意构造 |

---

## 安全提醒

这类「多层 + 加密 + 防扫描」的包，**除了正版资源，也常被用来夹带恶意程序**——多层加密的目的之一就是让网盘和杀软的自动扫描失效。

- 解包前先扫一遍（脚本默认会调用 Windows Defender）
- 关注**压缩比**：几百 MB 解出几十 GB 就是 zip 炸弹
- 解出来的 `.exe` / `.lnk` / `.scr` / `.bat` **一律不要双击**
- 先在空目录里解，看清内容再移动

---

## 路线图

- [ ] Python 跨平台版本（Linux / macOS）
- [ ] AES-256 加密 zip 的原生支持（`pyzipper`）
- [ ] 支持 RAR5 / 分卷包
- [ ] 并发解密加速

---

## 许可证

[MIT](LICENSE)

---

## English summary

A PowerShell tool that automatically peels **multi-layer nested archives** (`tar` ↔ `zip`, possibly encrypted and obfuscated), commonly used to evade automated content scanning on file-sharing platforms.

Key techniques: magic-byte format detection, iterative layer peeling, **offset-based tar extraction** to bypass malformed filenames, and delegating ZipCrypto decryption to libarchive/7-Zip instead of Python's slow pure-Python implementation (35× faster).
