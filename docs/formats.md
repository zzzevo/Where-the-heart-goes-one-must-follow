# 格式参考与排错手册

本文记录脚本背后的格式细节，以及遇到异常时怎么定位。

---

## 1. 文件头魔数速查

不要相信扩展名。压缩包只要改个后缀就能骗过大多数工具和扫描器。

| 格式 | 偏移 | 特征字节 | ASCII |
|---|---|---|---|
| ZIP | 0 | `50 4B 03 04` | `PK..` |
| ZIP（空归档） | 0 | `50 4B 05 06` | `PK..` |
| RAR 4.x | 0 | `52 61 72 21 1A 07 00` | `Rar!...` |
| RAR 5.x | 0 | `52 61 72 21 1A 07 01 00` | `Rar!....` |
| 7-Zip | 0 | `37 7A BC AF 27 1C` | `7z¼¯'·` |
| GZIP | 0 | `1F 8B` | |
| BZIP2 | 0 | `42 5A 68` | `BZh` |
| XZ | 0 | `FD 37 7A 58 5A 00` | |
| Zstandard | 0 | `28 B5 2F FD` | |
| TAR | **257** | `75 73 74 61 72` | `ustar` |
| ISO 9660 | **32769** | `43 44 30 30 31` | `CD001` |
| CAB | 0 | `4D 53 43 46` | `MSCF` |

> TAR 的魔数在 **257**，不是 0。因为前 257 字节是文件名、权限、时间戳等字段。

最小检测代码（只读 512 字节，不要 `ReadAllBytes` 读整个文件）：

```powershell
function Get-Magic([string]$p) {
    $fs = [IO.File]::OpenRead($p)
    try {
        $b = New-Object byte[] 512
        $n = $fs.Read($b, 0, 512)
        if ($n -lt 4) { return 'RAW' }
        if ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) { return 'ZIP' }
        if ($b[0] -eq 0x52 -and $b[1] -eq 0x61 -and $b[2] -eq 0x72 -and $b[3] -eq 0x21) { return 'RAR' }
        if ($b[0] -eq 0x37 -and $b[1] -eq 0x7A -and $b[2] -eq 0xBC -and $b[3] -eq 0xAF) { return '7Z' }
        if ($b[0] -eq 0x1F -and $b[1] -eq 0x8B) { return 'GZIP' }
        if ($n -ge 262 -and [Text.Encoding]::ASCII.GetString($b, 257, 5) -eq 'ustar') { return 'TAR' }
        return 'RAW'
    }
    finally { $fs.Close() }
}
```

> ⚠️ 别用 `[IO.File]::ReadAllBytes()` 判断大文件类型——一个 500MB 的包会直接吃掉 500MB 内存。只读前 512 字节。

---

## 2. TAR 格式（按偏移直切的依据）

TAR 极其简单，没有中心目录，就是头块和数据交替排列：

```
偏移 0           偏移 512
┌──────────────┬──────────────┬──────────────┬──────────────┬─────
│  头块 512B   │  数据（补齐   │  头块 512B   │  数据 ...    │ 结束
│              │  到 512 倍数）│              │              │ (两个全零块)
└──────────────┴──────────────┴──────────────┴──────────────┴─────
```

头块内部字段（POSIX ustar）：

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 100 | 文件名 |
| 100 | 8 | 权限模式（八进制） |
| 124 | 12 | **文件大小（八进制）** |
| 136 | 12 | 修改时间（八进制） |
| 156 | 1 | **类型标志**：`'0'`/`\0`=普通文件，`'5'`=目录，`'2'`=符号链接 |
| 257 | 6 | 魔数 `ustar` |

**下一个头块的偏移 = 当前偏移 + 512 + ⌈大小 / 512⌉ × 512**

于是单文件 tar 的载荷可以被无损取出，**完全不需要文件名能正确解码**：

```powershell
# 读头 -> 取大小 -> 从偏移 512 复制
function Copy-Range($src, $dst, [long]$offset, [long]$size) {
    $i = [IO.File]::OpenRead($src); $o = [IO.File]::Create($dst)
    try {
        $i.Position = $offset
        $buf = New-Object byte[] (8MB); $rem = $size
        while ($rem -gt 0) {
            $n = [int][Math]::Min([long]$buf.Length, $rem)
            $r = $i.Read($buf, 0, $n); if ($r -le 0) { break }
            $o.Write($buf, 0, $r); $rem -= $r
        }
    } finally { $o.Close(); $i.Close() }
}
```

### 为什么必须这么做

打包者常**故意破坏文件名**：末尾追加一个多字节字符、写入 GBK 而非 UTF-8、甚至塞入换行符。后果是：

- `bsdtar` 报 `Invalid empty pathname`，或者更糟——**静默跳过**，退出码 0 但一个文件都没解出来
- Python `tarfile` 会用 `surrogateescape` 解出无法写盘的名字

**只要不解析文件名，这些问题就全部消失。**

---

## 3. ZIP 结构与加密方式

### 两种加密

| 方式 | 标志 | 强度 | Python `zipfile` | 7-Zip | libarchive |
|---|---|---|---|---|---|
| ZipCrypto（传统） | 通用标志位 bit 0 | 弱（已知明文可破） | 只能读，**极慢** | ✅ | ✅ |
| AES-256 | 压缩方法 = 99 | 强 | ❌ 不支持 | ✅ | 部分 |

判断方法：条目 `flag_bits & 0x1` 为真即加密；`compress_type == 99` 即 AES。

### 为什么 Python 解 ZipCrypto 那么慢

CPython 的 `zipfile` 里，ZipCrypto 解密是**纯 Python 逐字节循环**（`_ZipDecrypter`），每 12 字节更新一次密钥并校验 CRC。实测吞吐约 **1.4 MB/s**。

C 实现的 libarchive / 7-Zip 能达到 **25 MB/s 以上**。

| 533.9 MB 加密条目 | 耗时 |
|---|---|
| Python `zipfile` | 383 秒 |
| libarchive (`bsdtar`) | 11 秒 |

**结论：Python 只用来试探密码，实际解包交给 7-Zip 或 bsdtar。**

### 快速试探密码的技巧

不需要解整个包。ZipCrypto 的每个条目开头有 12 字节加密头，读一小段就能验证密码：

```python
import zipfile
z = zipfile.ZipFile(src)
infos = [i for i in z.infolist() if not i.filename.endswith('/')]
with z.open(infos[0], pwd=pwd.encode()) as f:
    f.read(1024)      # 读 1KB 即可判定
```

每个候选密码只需毫秒级。

---

## 4. 密码线索的常见位置

按命中率排序：

1. **目录名 / 文件名本身** —— 最常见。如 `解压码1111/`、`密码：abc.txt`
2. **压缩包注释** —— `7z l -slt 包.zip` 可看到 `Comment` 字段
3. **同目录的说明文件** —— `.txt`、`.url`、`说明.htm`、`readme`
4. **分享页面 / 群公告** —— 需要人工看

脚本用正则从条目名里自动挖：

```
(?:解压码|解压密码|压缩密码|密码|提取码|pass(?:word)?)\s*[:：]?\s*([A-Za-z0-9_\-\.]{1,32})
```

---

## 5. 识别与防范 zip 炸弹

多层嵌套 + 高压缩比是 zip 炸弹的典型特征。

**判断指标：解出总体积 / 压缩包体积**

| 比值 | 判断 |
|---|---|
| < 10 | 正常（普通压缩） |
| 10 ~ 200 | 偏高，留意 |
| > 200 | **可疑，脚本会中止** |
| > 1000 | 几乎可以确定是炸弹 |

脚本在列出 zip 目录后立即用**中央目录里的声明大小**计算比值，不需要真正解包就能拦截。

> 注意：嵌套层数本身就是一种资源消耗攻击。脚本的 `-MaxLayers` 同时兼作这个防护。

---

## 6. 排查清单

遇到解不开的包，按顺序过一遍：

1. **确认真实格式** —— 看魔数，别看扩展名
2. **确认层数** —— 解出来只有一个文件就继续剥
3. **确认加密** —— 条目 `flag_bits & 1`、`compress_type == 99`
4. **找密码** —— 目录名 → 注释 → 同目录说明文件
5. **解出来是空的？** —— 十有八九是文件名畸形，换偏移直切
6. **中文名乱码？** —— `7z x -mcp=936`（GBK）或 `-mcp=65001`（UTF-8）
7. **卡很久？** —— 检查是不是 Python 在解大加密包

### 常用命令备查

```powershell
# 只列目录（快，不读数据）
7z l 包.zip
7z l -slt 包.zip | Select-String 'Comment|Encrypted|Method'

# 指定代码页解包
7z x 包.zip -o输出 -p密码 -mcp=936 -y

# 测试密码是否正确（不落盘）
7z t 包.zip -p密码

# libarchive 走 stdout 看吞吐
bsdtar -xOf 包.zip --passphrase 密码
```
