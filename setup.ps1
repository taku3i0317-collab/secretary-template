# 秘書のフォルダの準備を1回で済ませるスクリプト（テンプレートから作ったフォルダの中で動かす）
#   使い方（PowerShell で、このフォルダの中で）:
#     powershell -ExecutionPolicy Bypass -File .\setup.ps1
#   やること: 1. Git の名前とメール  2. 秘書の設定ファイルがそろっているか  3. 組織図などの追加機能  4. 最初の保存（commit・push）
#   何かを変える前に必ず聞く。もう済んでいる所は飛ばすので、何回流しても壊れない。ネットからスクリプトを落として流すことはしない。
#   作業フォルダを秘書に読ませる（.claude/settings.json の additionalDirectories に足す。足す前に聞く）:
#     powershell -ExecutionPolicy Bypass -File .\setup.ps1 -AddFolder "C:\Users\あなた\myapp"
param(
    [switch]$Yes,          # 質問に全部「はい」で答える（確かめ用）
    [switch]$NoPlugins,    # 追加機能（組織図など）の所を飛ばす
    [string]$AddFolder     # 秘書に読ませる作業フォルダ（1回に1つ。これを付けたときは、この仕事だけする）
)
# Windows PowerShell 5.1 は、git などが出す注意（標準エラー）を止まる失敗として扱うことがあるので Continue。結果は1つずつ確かめる
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = $PSScriptRoot
Set-Location $root

function Ask([string]$q, [bool]$default = $true) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    if ($Yes) { Write-Host "$q $hint → y（-Yes）"; return $true }
    $a = Read-Host "$q $hint"
    if (-not $a) { return $default }
    return ($a -match '^(y|yes|はい|うん)$')
}
function Step([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Skip([string]$t) { Write-Host "  --  $t" -ForegroundColor DarkGray }
function Warn([string]$t) { Write-Host "  !!  $t" -ForegroundColor Yellow }
$problems = @()

# --- 作業フォルダを足す（-AddFolder のときだけ。ほかの準備はしない） ---
if ($AddFolder) {
    $sp = Join-Path $root '.claude\settings.json'
    $text = [IO.File]::ReadAllText($sp, [Text.Encoding]::UTF8)
    $cur = @((($text | ConvertFrom-Json).permissions.additionalDirectories) | Where-Object { $_ })
    $add = @()
    foreach ($f in $AddFolder) {
        if (-not (Test-Path $f -PathType Container)) { Warn "フォルダが無い: $f"; continue }
        $full = (Resolve-Path $f).Path.TrimEnd('\') -replace '\\', '/'
        if ($full -eq ($root -replace '\\', '/')) { Skip "これは秘書のフォルダ自身: $full"; continue }
        if ($cur -contains $full) { Ok "もう入っている: $full"; continue }
        $add += $full
    }
    if ($add.Count -eq 0) { Write-Host '足すものはありません。何も変えていません。'; exit 0 }
    Write-Host '秘書が読めるフォルダに、次を足します（.claude/settings.json の additionalDirectories）:' -ForegroundColor Cyan
    $add | ForEach-Object { Write-Host "  + $_" }
    Write-Host '  秘書はこのフォルダを読めるようになる。中を書きかえるのは、そのフォルダで動く作業場のセッションだけ（秘書の決まり）'
    if (-not (Ask '足しますか？')) { Write-Host 'やめました。何も変えていません。'; exit 0 }
    $all = @($cur + $add) | ForEach-Object { '"' + $_ + '"' }
    $arr = '"additionalDirectories": [' + ($all -join ', ') + ']'
    if ($text -match '"additionalDirectories"\s*:\s*\[[^\]]*\]') {
        $text = [regex]::Replace($text, '"additionalDirectories"\s*:\s*\[[^\]]*\]', $arr)
    } else {
        $text = [regex]::Replace($text, '("permissions"\s*:\s*\{)(\r?\n)(\s*)', { param($m) $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value + $arr + ',' + $m.Groups[2].Value + $m.Groups[3].Value }, 1)
    }
    try { $null = $text | ConvertFrom-Json } catch { Warn "書きかえた結果が JSON として読めないので、やめた（$($_.Exception.Message)）"; exit 1 }
    [IO.File]::WriteAllText($sp, $text, [Text.UTF8Encoding]::new($false))
    Ok '足した。秘書のセッションを開き直すと効く'
    Write-Host '  保存（commit）は秘書がする。秘書に「settings に作業フォルダを足した。保存して」と言う'
    exit 0
}

Write-Host '秘書のフォルダの準備をします。やることは4つです:' -ForegroundColor Cyan
Write-Host '  1. Git に名前とメールが入っているか（無ければ聞いて入れる）'
Write-Host '  2. 秘書の設定ファイル（.claude/）がそろっているか（見るだけ。書きかえない）'
Write-Host '  3. 組織図（soshiki-zu）を入れるか（入れる前に聞く。もう入っていれば飛ばす）'
Write-Host '  4. 最初の保存（commit と push）（する前に聞く）'
Write-Host "フォルダ: $root"
if (-not (Ask 'はじめますか？')) { Write-Host 'やめました。何も変えていません。'; exit 0 }

# --- 1. Git ---
Step '1. Git の名前とメール'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Warn 'Git が見つからない。README の「1. アプリを2つ入れる」で Git を入れてから、もう一度流してください'
    exit 1
}
if (-not (Test-Path (Join-Path $root '.git'))) {
    Warn 'このフォルダは Git の保存場所（git clone したフォルダ）ではない。README の「3」で clone したフォルダの中で流してください'
    exit 1
}
foreach ($key in 'user.name', 'user.email') {
    $v = (git config --global $key) 2>$null
    if ($v) { Ok "$key は入っている（$v）"; continue }
    if ($key -eq 'user.email') { Write-Host '  メールは GitHub の Settings → Emails にある「…@users.noreply.github.com」を使うと、本物のアドレスが記録に残らない' }
    $label = if ($key -eq 'user.name') { '名前' } else { 'メール' }
    if ($Yes) { Warn "$key が空（-Yes では入れない）"; $problems += "Git の $label"; continue }
    $in = Read-Host "  Git に入れる$label"
    if ($in) { git config --global $key $in; Ok "$key を入れた（$in）" } else { Warn "$key は空のまま"; $problems += "Git の $label" }
}

# --- 2. 秘書の設定ファイル ---
Step '2. 秘書の設定ファイル（.claude/）'
$need = @(
    '.claude\settings.json',
    '.claude\scripts\session-start.ps1', '.claude\scripts\life-log.ps1', '.claude\scripts\life-today.ps1',
    '.claude\agents\researcher.md', '.claude\agents\generator.md', '.claude\agents\critic.md', '.claude\agents\judge.md', '.claude\agents\finisher.md',
    '.claude\skills\hajime\SKILL.md', '.claude\skills\kugiri\SKILL.md', '.claude\skills\tenken\SKILL.md',
    'CLAUDE.md', 'status\index.md', 'status\締め切り.md', 'roles\roster.md'
)
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $root $_)) })
if ($missing.Count -eq 0) { Ok "そろっている（$($need.Count) 個）" }
else {
    $missing | ForEach-Object { Warn "無い: $_" }
    Warn 'テンプレートから作り直すか、テンプレートの同じファイルを写してください（このスクリプトはネットから取ってこない）'
    $problems += '.claude/ のファイルが足りない'
}
try {
    $null = Get-Content (Join-Path $root '.claude\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Ok 'settings.json は読める'
} catch { Warn "settings.json が読めない（$($_.Exception.Message)）"; $problems += 'settings.json' }
$env:CLAUDE_PROJECT_DIR = $root
$first = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.claude\scripts\session-start.ps1') | Out-String).Trim()
if ($first -match 'フック失敗') { Warn "会話の最初の行が作れない: $first"; $problems += '会話の最初の行' }
else { Ok '会話の最初の行が作れる:'; $first -split "`n" | ForEach-Object { Write-Host "      $_" } }

# --- 3. 追加機能 ---
Step '3. 組織図（soshiki-zu）と記録のボタン（kiroku-botan）'
$plugins = @(
    @{ name = 'soshiki-zu';   src = 'taku3i0317-collab/soshiki-zu';   what = '右に組織図を出す（おすすめ）'; default = $true },
    @{ name = 'kiroku-botan'; src = 'taku3i0317-collab/kiroku-botan'; what = '記録のボタンのペイン（組織図の下にも同じボタンがあるので、無くてもよい）'; default = $false }
)
if ($NoPlugins) { Skip '飛ばした（-NoPlugins）' }
elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Skip 'このパソコンでは claude の命令が使えないので、アプリの画面から入れる（README の「5」）'
} else {
    $list = (claude plugin list 2>&1 | Out-String)
    foreach ($p in $plugins) {
        if ($list -match [regex]::Escape("$($p.name)@")) { Ok "$($p.name) はもう入っている"; continue }
        if (-not (Ask "  $($p.name) を入れますか？ $($p.what)" $p.default)) { Skip "$($p.name) は入れなかった"; continue }
        claude plugin install $p.name --marketplace $p.src
        if ($LASTEXITCODE -eq 0) { Ok "$($p.name) を入れた" } else { Warn "$($p.name) が入らなかった（README の「5」の画面からでも入れられる）"; $problems += $p.name }
    }
}

# --- 4. 最初の保存 ---
Step '4. 最初の保存（commit と push）'
$dirty = (git -c core.quotepath=false status --porcelain | Out-String).Trim()
if ($dirty) {
    Write-Host '  まだ保存していない変更:'
    $dirty -split "`n" | ForEach-Object { Write-Host "      $_" }
    if (Ask '  これを保存（commit）しますか？') {
        git add -A
        git commit -q -m 'はじめの準備（setup.ps1）'
        if ($LASTEXITCODE -eq 0) { Ok '保存した' } else { Warn '保存できなかった（Git の名前とメールを見てください）'; $problems += 'commit' }
    } else { Skip '保存しなかった' }
} else { Ok '保存していない変更は無い' }
$remote = (git remote | Out-String).Trim()
if (-not $remote) {
    Skip '送り先（GitHub）が無いので push は飛ばした（GitHub から clone したフォルダなら、ふつうは有る）'
} else {
    git fetch -q 2>$null
    $ahead = (git rev-list --count '@{u}..HEAD' 2>$null)
    if ($LASTEXITCODE -ne 0) { $ahead = 1 }
    if ([int]$ahead -eq 0) { Ok 'GitHub と同じ（push するものは無い）' }
    elseif (Ask "  GitHub に送り（push）ますか？（$ahead 個の保存）") {
        git push -u origin HEAD
        if ($LASTEXITCODE -eq 0) { Ok '送った' } else { Warn 'push できなかった（初めてなら、出てきたログインの画面で許可してから、もう一度流す）'; $problems += 'push' }
    } else { Skip 'push しなかった' }
}

# --- まとめ ---
Step 'まとめ'
if ($problems.Count -eq 0) {
    Ok '準備できました'
} else {
    Warn ('まだのこと: ' + ($problems -join '・') + '。直してからもう一度流してください（済んだ所は飛ばします）')
}
Write-Host ''
Write-Host '次は: Claude のデスクトップアプリ → Code → このフォルダを選んで会話を始め、「信頼する」を押して /hajime と打つ'
Write-Host "  フォルダ: $root"
