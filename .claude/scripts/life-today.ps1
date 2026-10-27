# 今日の記録を1行にする。SessionStart から呼ばれる。AI は通らない。
# 読むもの: journal/記録/<年-月>.md（今月と先月）、status/生活.md の「ボタン」「間隔」「定例」表
#   ボタン: | 項目 | まとまり | なしの言い方 |   → 今日したか（○ ／ − ／ なし）。間隔表にもある項目は間隔のほうで出す
#   間隔:   | 項目 | 日数 | メモ |                 → 前にした日からの日数（日数をこえたら ←目安超え）
#   この2つの表は、記録のボタンの MOD（soshiki-zu の記録・kiroku-botan）が読む形と同じ
# 出すもの: 1行。失敗しても exit 0
param([DateTime]$Now = (Get-Date))
$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $root = $env:CLAUDE_PROJECT_DIR
    if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
    $today = $Now.Date

    # 1. 記録を読む（今月と先月）。項目ごとに「最後にした時刻」と「今日の最後の行」を取る（あとの行が勝つ）
    $lastDone = @{}; $todayLast = @{}
    foreach ($m in @($Now.AddMonths(-1), $Now)) {
        $f = Join-Path $root ("journal\記録\" + $m.ToString('yyyy-MM') + '.md')
        if (-not (Test-Path $f)) { continue }
        foreach ($l in Get-Content $f -Encoding UTF8) {
            if ($l -notmatch '^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) (\S+)(?: (\S+))?') { continue }
            $name = $Matches[2]; $note = $Matches[3]
            if ($name -like '通知:*') { continue }
            $t = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $nashi = ($note -eq 'なし')
            if (-not $nashi) { $lastDone[$name] = $t }
            if ($t.Date -eq $today) { $todayLast[$name] = @{ t = $t; nashi = $nashi } }
        }
    }

    # 2. status/生活.md のボタン・間隔・定例（今日の曜日）
    $seikatsu = Join-Path $root 'status\生活.md'
    $youbi = @('日','月','火','水','木','金','土')[[int]$Now.DayOfWeek]
    $buttons = @(); $kankaku = [ordered]@{}; $teirei = @()
    if (Test-Path $seikatsu) {
        $section = ''
        foreach ($l in Get-Content $seikatsu -Encoding UTF8) {
            if ($l -match '^## ボタン') { $section = 'button'; continue }
            if ($l -match '^## 間隔') { $section = 'kankaku'; continue }
            if ($l -match '^## 定例') { $section = 'teirei'; continue }
            if ($l -match '^## ') { $section = ''; continue }
            if (-not ($l -match '^\|')) { continue }
            $cells = ($l -split '\|') | ForEach-Object { $_.Trim() }
            if ($cells.Count -lt 3 -or -not $cells[1] -or $cells[1] -match '^:?-+:?$' -or $cells[1] -in @('曜','項目')) { continue }
            if ($section -eq 'button') { $buttons += $cells[1] }
            if ($section -eq 'kankaku' -and $cells[2] -match '^\d+$') { $kankaku[$cells[1]] = [int]$cells[2] }
            if ($section -eq 'teirei' -and $cells.Count -ge 4) {
                $w = $cells[1]; $hit = $false
                if ($w -eq '毎日' -or ($w -split '・') -contains $youbi) { $hit = $true }
                elseif ($w -match '^第(\d)([日月火水木金土])$' -and $Matches[2] -eq $youbi -and [math]::Ceiling($Now.Day / 7) -eq [int]$Matches[1]) { $hit = $true }
                if ($hit) { $teirei += "$($cells[2])（$($cells[3])）" }
            }
        }
    }

    # 3. 組み立て
    $daily = foreach ($k in ($buttons | Select-Object -Unique)) {
        if ($kankaku.Contains($k)) { continue }
        if ($todayLast[$k]) { if ($todayLast[$k].nashi) { "$k なし" } else { "$k ○" } } else { "$k −" }
    }
    $interval = foreach ($k in $kankaku.Keys) {
        if ($lastDone[$k]) {
            $d = ($today - $lastDone[$k].Date).Days
            "$k ${d}日前$(if ($d -ge $kankaku[$k]) { '←目安超え' })"
        } else { "$k 記録なし" }
    }
    $parts = @()
    if (@($daily).Count -gt 0) { $parts += (@($daily) -join ' ／ ') }
    if (@($interval).Count -gt 0) { $parts += (@($interval) -join ' ／ ') }
    if ($teirei.Count -gt 0) { $parts += "今日（$youbi）: " + ($teirei -join '、') }
    if ($parts.Count -eq 0) { $parts += '項目なし（status/生活.md の「ボタン」「間隔」表が空）' }
    "今日の記録（$($Now.ToString('HH:mm'))時点）: " + ($parts -join ' ｜ ')
    exit 0
} catch {
    "今日の記録: 取得失敗（$($_.Exception.Message)）"
    exit 0
}
