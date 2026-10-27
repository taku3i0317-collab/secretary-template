# UserPromptSubmit フック：本人のメッセージが「合図」1行だけのとき、journal/記録/<年-月>.md に追記する。AI は通らない。
# 合図: status/生活.md の「ボタン」表と「間隔」表の左の列にある言葉だけ（固定の項目は無い。使う人が決める）。
#   この2つの表は、記録のボタンの MOD（soshiki-zu の記録・kiroku-botan）が読む形と同じ。
#   例: 表に「朝ごはん」「洗濯」があれば「朝ごはん」「朝ごはん 7:40」「洗濯 なし」。時刻を付ければその時刻、無ければ今。
#   合図でないメッセージ（「洗濯しなきゃ」「朝ごはん何にしよう」）には何もしない。
# status/生活.md が無い人（記録を使わない人）には何もしない。
# 追記だけで、消さない・直さない。間違えたら打ち直す（あとの行が勝つ）。失敗しても exit 0。
# もう1つの仕事＝声かけ：status/生活.md「声かけ」表の時刻を過ぎていて、まだ記録も声かけも無い項目があれば、
#   1行出す（会話の中に出る）。出したら「通知:<項目>」を記録に追記して、その日はもう出さない。
$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if (-not $raw) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $p = ([string]$j.prompt).Trim()

    $root = $env:CLAUDE_PROJECT_DIR
    if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
    $seikatsu = Join-Path $root 'status\生活.md'
    if (-not (Test-Path $seikatsu)) { exit 0 }
    $lines = Get-Content $seikatsu -Encoding UTF8
    $now = Get-Date
    $dir = Join-Path $root 'journal\記録'
    $todayFile = Join-Path $dir ($now.ToString('yyyy-MM') + '.md')
    $out = @()

    # --- 声かけ（status/生活.md「声かけ」表：| 項目 | から | まで | 曜 | 言い方 |）---
    $doneToday = @{}
    if (Test-Path $todayFile) {
        $d = $now.ToString('yyyy-MM-dd')
        foreach ($l in Get-Content $todayFile -Encoding UTF8) {
            if ($l -match '^- (\d{4}-\d{2}-\d{2}) \d{2}:\d{2} (\S+)' -and $Matches[1] -eq $d) { $doneToday[$Matches[2]] = $true }
        }
    }
    $youbi = @('日','月','火','水','木','金','土')[[int]$now.DayOfWeek]
    $hm = $now.ToString('HH:mm')
    $section = ''
    foreach ($l in $lines) {
        if ($l -match '^## 声かけ') { $section = 'v'; continue }
        if ($l -match '^## ') { $section = ''; continue }
        if ($section -ne 'v' -or -not ($l -match '^\|')) { continue }
        $c = ($l -split '\|') | ForEach-Object { $_.Trim() }
        if ($c.Count -lt 7 -or $c[2] -notmatch '^\d{2}:\d{2}$') { continue }
        $item = $c[1]; $from = $c[2]; $to = $c[3]; $days = $c[4]; $say = $c[5]
        if ($to -notmatch '^\d{2}:\d{2}$') { $to = '23:59' }
        if (-not ($days -eq '毎日' -or ($days -split '・') -contains $youbi)) { continue }
        if ($hm -lt $from -or $hm -gt $to) { continue }
        if ($doneToday[$item] -or $doneToday["通知:$item"]) { continue }
        $out += "声かけ：$say（$hm）"
        New-Item -ItemType Directory -Force $dir | Out-Null
        if (-not (Test-Path $todayFile)) { @("# $($now.ToString('yyyy-MM')) の記録（フックが追記。1行1件。あとの行が勝つ。秘書は書かない）", '') | Set-Content $todayFile -Encoding UTF8 }
        Add-Content $todayFile "- $($now.ToString('yyyy-MM-dd HH:mm')) 通知:$item" -Encoding UTF8
    }

    # --- 合図の記録 ---
    if (-not $p -or $p.Length -gt 40) { if ($out) { $out -join "`n" }; exit 0 }

    # 合図の一覧：「ボタン」表（| 項目 | まとまり | なしの言い方 |）と「間隔」表（| 項目 | 日数 | メモ |）の左の列。
    # 下の固定の一覧は空のまま（MOD は「ボタン」表が無いときだけ、この行を読む）
    $items = @()
    $section = ''
    foreach ($l in $lines) {
        if ($l -match '^## (ボタン|間隔)') { $section = 'k'; continue }
        if ($l -match '^## ') { $section = ''; continue }
        if ($section -ne 'k' -or -not ($l -match '^\|')) { continue }
        $cells = ($l -split '\|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -ge 3 -and $cells[1] -and $cells[1] -notmatch '^:?-+:?$' -and $cells[1] -ne '項目') { $items += $cells[1] }
    }
    if ($items.Count -eq 0) { if ($out) { $out -join "`n" }; exit 0 }
    $alt = ($items | Select-Object -Unique | ForEach-Object { [regex]::Escape($_) }) -join '|'
    # <合図> [H:mm] [短いメモ（空白なし・15文字まで・？で終わらない）]
    if ($p -notmatch "^($alt)(?:\s+(\d{1,2})[:：](\d{2}))?(?:\s+([^\s？?]{1,15}))?$") { if ($out) { $out -join "`n" }; exit 0 }
    $item = $Matches[1]; $note = $Matches[4]
    $t = Get-Date
    if ($Matches[2]) {
        $h = [int]$Matches[2]; $mi = [int]$Matches[3]
        if ($h -gt 23 -or $mi -gt 59) { $out += "記録しなかった：時刻がおかしい（$p）"; $out -join "`n"; exit 0 }
        $t = Get-Date -Hour $h -Minute $mi -Second 0
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir ($t.ToString('yyyy-MM') + '.md')
    if (-not (Test-Path $file)) {
        @("# $($t.ToString('yyyy-MM')) の記録（フックが追記。1行1件。あとの行が勝つ。秘書は書かない）", '') | Set-Content $file -Encoding UTF8
    }
    $line = "- $($t.ToString('yyyy-MM-dd HH:mm')) $item"
    if ($note) { $line += " $note" }
    Add-Content $file $line -Encoding UTF8
    $out += "記録した：$item $($t.ToString('HH:mm'))$(if ($note) { " $note" })（journal/記録/$($t.ToString('yyyy-MM')).md）。秘書は一言返すだけでよい。「なし」のときは理由を聞いたり責めたりしない"
    $out -join "`n"
    exit 0
} catch {
    "記録に失敗：$($_.Exception.Message)"
    exit 0
}
