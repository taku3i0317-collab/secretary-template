# SessionStart フック：秘書が会話の最初に読む行（締め切り／inbox／今日の記録）を出す。
# 失敗しても必ず終了コード 0 で「フック失敗：理由」を標準出力に出す（無音にしない）。
$ErrorActionPreference = 'Stop'
try {
    $root = $env:CLAUDE_PROJECT_DIR
    if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $today = Get-Date
    $lines = @()

    # 0. まだ始めていない（/hajime 前）なら、それだけ言う
    $claudeMd = Join-Path $root 'CLAUDE.md'
    if ((Test-Path $claudeMd) -and ((Get-Content $claudeMd -Raw -Encoding UTF8) -match '【まだ】')) {
        $lines += 'はじめの設定がまだ（CLAUDE.md に【まだ】が残っている）。本人に /hajime を打ってもらう'
    }

    # 1. 締め切り：status/締め切り.md の「## 予定」表
    #    | 日付 | 部門 | 出すもの・やること | 状態 |   日付は YYYY-MM-DD、状態が「済」の行は数えない
    $shime = Join-Path $root 'status\締め切り.md'
    $near = @()
    if (Test-Path $shime) {
        $section = ''
        foreach ($l in Get-Content $shime -Encoding UTF8) {
            if ($l -match '^## 予定') { $section = 'yotei'; continue }
            if ($l -match '^## ') { $section = ''; continue }
            if ($section -ne 'yotei' -or -not ($l -match '^\|')) { continue }
            $cells = ($l -split '\|') | ForEach-Object { $_.Trim() }
            if ($cells.Count -ge 5 -and $cells[1] -match '^\d{4}-\d{2}-\d{2}$') {
                $d = [DateTime]::ParseExact($cells[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                $diff = ($d.Date - $today.Date).Days
                if ($diff -ge 0 -and $diff -le 7 -and $cells[4] -ne '済') {
                    $near += "$($cells[1]) $($cells[2])：$($cells[3])（あと${diff}日）"
                }
            }
        }
        if ($near.Count -gt 0) { $lines += '締め切り7日以内: ' + ($near -join '、') } else { $lines += '締め切り7日以内: なし' }
    } else {
        $lines += 'フック失敗：status/締め切り.md が無い'
    }

    # 2. inbox 直下の未処理件数（README と _ で始まるもの、done/ は数えない）
    $inbox = Join-Path $root 'inbox'
    $n = 0
    if (Test-Path $inbox) {
        $n = (Get-ChildItem $inbox -File | Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '_*' }).Count
    }
    $lines += "inbox 未処理: ${n}件"

    # 3. 今日の記録（任意。status/生活.md があるときだけ。life-today.ps1 が1行にする）
    if (Test-Path (Join-Path $root 'status\生活.md')) {
        $lines += ((& (Join-Path $PSScriptRoot 'life-today.ps1') -Now $today | Out-String).Trim())
    }

    $lines -join "`n"
    exit 0
} catch {
    "フック失敗：$($_.Exception.Message)"
    exit 0
}
