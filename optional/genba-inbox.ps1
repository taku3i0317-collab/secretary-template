# 秘書から「別のリポで働く現場」へ用事を伝える唯一の出口。現場の監督（その現場を見ている会話）の INBOX に追記するだけ。
# 現場の中の他のファイルには書かない。行き先は status/*.md の「## 出口」表（| 現場 | 監督の INBOX（絶対パス） |）で引く。
# 表に無い現場・無いファイルには書かない。送った本文は journal/現場/<年-月>.md にも残す（何を伝えたかの控え）。
# 使い方: genba-inbox.ps1 -Genba kakeibo -Text "次はこれをやってほしい（本人の決定）"
# 置き場所: .claude/scripts/genba-inbox.ps1（本人が手で置く。秘書は .claude/scripts を書けない決まり）
param(
    [Parameter(Mandatory=$true)][string]$Genba,
    [Parameter(Mandatory=$true)][string]$Text
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$target = $null
foreach ($f in Get-ChildItem (Join-Path $root 'status') -Filter '*.md' -File) {
    $section = ''
    foreach ($l in Get-Content $f.FullName -Encoding UTF8) {
        if ($l -match '^## 出口') { $section = 'd'; continue }
        if ($l -match '^## ') { $section = ''; continue }
        if ($section -eq 'd' -and $l -match '^\|') {
            $c = ($l -split '\|') | ForEach-Object { $_.Trim() }
            if ($c.Count -ge 4 -and $c[1] -eq $Genba -and $c[2] -match '^[A-Za-z]:\\') { $target = $c[2] }
        }
    }
}
if (-not $target) { Write-Error "status/ の「## 出口」表に現場「$Genba」が無い（または INBOX の欄が絶対パスでない）"; exit 2 }
if (-not (Test-Path $target)) { Write-Error "監督の INBOX が無い: $target（表のパスを直すか、現場が止まっている）"; exit 2 }
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$block = @('', "## 秘書より（$stamp）", $Text.Trim(), '') -join "`n"
Add-Content $target $block -Encoding UTF8
$logDir = Join-Path $root 'journal\現場'
New-Item -ItemType Directory -Force $logDir | Out-Null
Add-Content (Join-Path $logDir ((Get-Date -Format 'yyyy-MM') + '.md')) ("- $stamp → ${Genba}：" + ($Text.Trim() -replace "`r?`n", ' ／ ')) -Encoding UTF8
Write-Output "伝えた：$Genba の監督の INBOX（$target）に追記。控えは journal/現場/"
exit 0
