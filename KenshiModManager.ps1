# Kenshi Mod Manager
# Удобный список модов Kenshi: названия и картинки из Workshop, поиск, порядок загрузки,
# проверка зависимостей, свои отметки «работает / не работает», дата загрузки.
# Положить в папку игры Kenshi рядом с kenshi_x64.exe и запускать через "Kenshi Mod Manager.bat".
param(
    [string]$KenshiDir = $PSScriptRoot,
    [switch]$TestDataOnly
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- пути
$CfgPath      = Join-Path $KenshiDir 'data\mods.cfg'
$LocalModsDir = Join-Path $KenshiDir 'mods'
$SteamApps    = Split-Path (Split-Path $KenshiDir -Parent) -Parent      # ...\steamapps
$WorkshopDir  = Join-Path $SteamApps 'workshop\content\233860'
$StatusPath   = Join-Path $KenshiDir 'KenshiModManager.status.json'
$CacheDir     = Join-Path $KenshiDir '_kmm_cache'
$BaseMasters  = @('gamedata.base','newwworld.mod','dialogue.mod','rebirth.mod')
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- чтение .mod
function Read-KString([System.IO.BinaryReader]$r) {
    $len = $r.ReadInt32()
    if ($len -lt 0 -or $len -gt 20000000) { throw "bad string length $len" }
    if ($len -eq 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($r.ReadBytes($len))
}

function Get-ModHeader([string]$Path) {
    $res = [pscustomobject]@{ Author = ''; Description = ''; Deps = @(); Error = $null }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $r  = New-Object System.IO.BinaryReader($fs)
        $ft = $r.ReadInt32()
        if ($ft -eq 17) { [void]$r.ReadInt32() }          # размер заголовка
        elseif ($ft -ne 16) { $res.Error = "неизвестный формат ($ft)"; return $res }
        [void]$r.ReadInt32()                              # версия
        $res.Author      = Read-KString $r
        $res.Description = Read-KString $r
        $deps            = Read-KString $r
        $res.Deps = @($deps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch {
        $res.Error = $_.Exception.Message
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    return $res
}

function Get-InfoData([string]$Dir) {
    $res = [pscustomobject]@{ Title = ''; LastUpdate = $null }
    $info = Get-ChildItem -LiteralPath $Dir -Filter '_*.info' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $info) { return $res }
    try {
        [xml]$x = [System.IO.File]::ReadAllText($info.FullName)
        $t = $x.ModData.title
        if ($t) { $res.Title = [System.Net.WebUtility]::HtmlDecode($t).Trim() }
        $u = $x.ModData.lastUpdate
        if ($u) { try { $res.LastUpdate = [datetime]::Parse($u, [System.Globalization.CultureInfo]::InvariantCulture) } catch { } }
    } catch { }
    return $res
}

function Get-PreviewPath([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    $f = Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like '_*.img' } | Select-Object -First 1
    if (-not $f) {
        $f = Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^(preview|thumb|_?logo).*\.(png|jpe?g|gif|bmp)$' } | Select-Object -First 1
    }
    if ($f) { return $f.FullName }
    return $null
}

function Get-CleanText([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '\[/?(h\d|b|i|u|list|olist|\*|code|quote|spoiler|strike|noparse|hr|table|tr|td|th)[^\]]*\]', ''
    $s = $s -replace '\[url=([^\]]*)\]([^\[]*)\[/url\]', '$2 ($1)'
    $s = $s -replace '\[/?url[^\]]*\]', ''
    $s = $s -replace '\[img\][^\[]*\[/img\]', ''
    return ($s -replace "`r?`n", "`r`n").Trim()
}

# ---------------------------------------------------------------- статусы «работает / не работает»
$script:Status = @{}

function Load-Status {
    $script:Status = @{}
    if (Test-Path -LiteralPath $StatusPath) {
        try {
            $j = [System.IO.File]::ReadAllText($StatusPath) | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($p.Value -eq 'ok' -or $p.Value -eq 'bad') { $script:Status[$p.Name.ToLowerInvariant()] = [string]$p.Value }
            }
        } catch { }
    }
}

function Save-Status {
    $o = [ordered]@{}
    foreach ($k in ($script:Status.Keys | Sort-Object)) { $o[$k] = $script:Status[$k] }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$o)
    if (-not $json -or $json -eq 'null') { $json = '{}' }
    [System.IO.File]::WriteAllText($StatusPath, $json, $Utf8NoBom)
}

function Get-StatusText([string]$key) {
    if ($script:Status.ContainsKey($key)) {
        if ($script:Status[$key] -eq 'ok') { return '✔ работает' }
        return '✖ не работает'
    }
    return '— не отмечен'
}

# ---------------------------------------------------------------- модель данных
$script:Mods     = New-Object System.Collections.Generic.List[object]   # все найденные моды
$script:ByFile   = @{}                                                  # имя файла (нижний регистр) -> мод
$script:Order    = New-Object System.Collections.Generic.List[string]   # включённые, в порядке загрузки
$script:Dirty    = $false

function New-ModObject($file, $dir, $source, $id) {
    return [pscustomobject]@{
        File = $file; Key = $file.ToLowerInvariant(); Title = [System.IO.Path]::GetFileNameWithoutExtension($file)
        Source = $source; Id = $id; Dir = $dir; Path = ''; Author = ''; Description = ''; Deps = @()
        ReadError = $null; Duplicate = $false; Problem = ''; Level = 0
        Downloaded = $null; AuthorUpdate = $null; Preview = $null; ImageKey = '_none'; Special = $false; InGenesis = 0; GenesisVia = ''
    }
}

function Add-ModEntry($file, $dir, $source, $id) {
    $m = New-ModObject $file $dir $source $id
    $m.Path = Join-Path $dir $file
    $h = Get-ModHeader $m.Path
    $m.Author = $h.Author; $m.Description = $h.Description; $m.Deps = $h.Deps; $m.ReadError = $h.Error
    $info = Get-InfoData $dir
    if ($info.Title) { $m.Title = $info.Title }
    $m.AuthorUpdate = $info.LastUpdate
    try { $m.Downloaded = (Get-Item -LiteralPath $m.Path).LastWriteTime } catch { }
    $m.Preview = Get-PreviewPath $dir
    $script:Mods.Add($m)
    if ($script:ByFile.ContainsKey($m.Key)) {
        $script:ByFile[$m.Key].Duplicate = $true
        $m.Duplicate = $true
    } else {
        $script:ByFile[$m.Key] = $m
    }
}

function Load-All {
    $script:Mods.Clear(); $script:ByFile.Clear(); $script:Order.Clear()
    if (Test-Path -LiteralPath $LocalModsDir) {
        foreach ($d in Get-ChildItem -LiteralPath $LocalModsDir -Directory) {
            foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Filter '*.mod' -File) {
                Add-ModEntry $f.Name $d.FullName 'Локальный' ''
            }
        }
    }
    if (Test-Path -LiteralPath $WorkshopDir) {
        foreach ($d in Get-ChildItem -LiteralPath $WorkshopDir -Directory) {
            foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Filter '*.mod' -File) {
                Add-ModEntry $f.Name $d.FullName 'Workshop' $d.Name
            }
        }
    }
    if (Test-Path -LiteralPath $CfgPath) {
        $seen = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($CfgPath)) {
            $n = $line.Trim()
            if (-not $n -or -not $n.ToLowerInvariant().EndsWith('.mod')) { continue }
            if ($seen.ContainsKey($n.ToLowerInvariant())) { continue }
            $seen[$n.ToLowerInvariant()] = $true
            $script:Order.Add($n)
            if (-not $script:ByFile.ContainsKey($n.ToLowerInvariant())) {
                $m = New-ModObject $n '' 'нет файла' ''
                $script:Mods.Add($m); $script:ByFile[$m.Key] = $m
            }
        }
    }
    $script:Dirty = $false
    Update-Problems
}

function Get-OrderIndex([string]$file) {
    for ($i = 0; $i -lt $script:Order.Count; $i++) {
        if ($script:Order[$i].ToLowerInvariant() -eq $file.ToLowerInvariant()) { return $i }
    }
    return -1
}

function Update-Problems {
    $pos = @{}
    for ($i = 0; $i -lt $script:Order.Count; $i++) { $pos[$script:Order[$i].ToLowerInvariant()] = $i }
    foreach ($m in $script:Mods) {
        $p = New-Object System.Collections.Generic.List[string]; $lvl = 0
        $enabled = $pos.ContainsKey($m.Key)
        if ($m.Source -eq 'нет файла') { $p.Add('включён, но файла нет на диске'); $lvl = 2 }
        if ($m.Duplicate) {
            $all = @($script:Mods | Where-Object { $_.Key -eq $m.Key })
            $p.Add("файл есть в $($all.Count) местах — игра возьмёт любой"); if ($lvl -lt 2) { $lvl = 2 }
        }
        if ($m.ReadError) { $p.Add("не читается: $($m.ReadError)"); if ($lvl -lt 1) { $lvl = 1 } }
        if ($enabled) {
            foreach ($d in $m.Deps) {
                $dk = $d.ToLowerInvariant()
                if ($BaseMasters -contains $dk) { continue }
                if (-not $pos.ContainsKey($dk)) {
                    $dn = Get-NormName $d
                    $inBundle = ($script:BundleSrc -and $pos.ContainsKey($script:BundleSrc.Key) -and $script:BundleCounts.ContainsKey($dn) -and $script:BundleCounts[$dn] -ge $BundleMin)
                    if (-not $inBundle) { $p.Add("не включена зависимость $d"); if ($lvl -lt 1) { $lvl = 1 } }
                }
                elseif ($pos[$dk] -gt $pos[$m.Key]) { $p.Add("зависимость $d стоит НИЖЕ"); $lvl = 2 }
            }
            if ($m.InGenesis -gt 0 -and $script:BundleSrc -and $pos.ContainsKey($script:BundleSrc.Key) -and $pos[$m.Key] -gt $pos[$script:BundleSrc.Key]) {
                $p.Add("уже есть в $([System.IO.Path]::GetFileNameWithoutExtension($script:BundleSrc.File)) и стоит ниже него — перетирает его версию"); if ($lvl -lt 1) { $lvl = 1 }
            }
        }
        $m.Problem = ($p -join '; '); $m.Level = $lvl
    }
}

function Save-Cfg {
    $dir = Split-Path $CfgPath -Parent
    if (Test-Path -LiteralPath $CfgPath) {
        $bak = Join-Path $dir ('mods.cfg.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item -LiteralPath $CfgPath -Destination $bak
        Get-ChildItem -LiteralPath $dir -Filter 'mods.cfg.bak_*' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 15 | Remove-Item -ErrorAction SilentlyContinue
    }
    $text = ($script:Order -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($CfgPath, $text, $Utf8NoBom)
    $script:Dirty = $false
}

function Format-Date($d) { if ($d) { return $d.ToString('dd.MM.yyyy HH:mm') } return '' }

# ---------------------------------------------------------------- состав Genesis
# Genesis — сборник: у каждой его записи ID вида "1214-CBT Faction Furniture.mod" — это мод, из которого запись пришла.
$CompilationNames = @('genesis.mod')
$BundleMin = 5     # сколько записей из мода должно быть внутри сборника, чтобы считать мод «в составе»
$script:BundleSrc = $null
$script:BundleCounts = @{}

function Get-NormName([string]$n) {
    $b = [System.IO.Path]::GetFileNameWithoutExtension($n).ToLowerInvariant()
    return ($b -replace '[^\p{L}\p{Nd}]', '')
}

function Get-BundledCounts($m) {
    $fi = Get-Item -LiteralPath $m.Path
    $stamp = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    $cache = Join-Path $CacheDir ('bundled_' + ($m.Key -replace '[^\w]', '_') + '.json')
    if (Test-Path -LiteralPath $cache) {
        try {
            $j = [System.IO.File]::ReadAllText($cache) | ConvertFrom-Json
            if ($j.stamp -eq $stamp) {
                $h = @{}; foreach ($pp in $j.counts.PSObject.Properties) { $h[$pp.Name] = [int]$pp.Value }
                return $h
            }
        } catch { }
    }
    $latin = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin.GetString([System.IO.File]::ReadAllBytes($m.Path))
    $rx = New-Object System.Text.RegularExpressions.Regex('\d{1,9}-([\x20-\x7e\x80-\xff]{1,100}?\.mod)')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($mt in $rx.Matches($text)) { [void]$seen.Add($mt.Value) }
    $text = $null
    $h = @{}
    foreach ($tok in $seen) {
        $name = $tok.Substring($tok.IndexOf('-') + 1)
        $name = [System.Text.Encoding]::UTF8.GetString($latin.GetBytes($name))
        $k = Get-NormName $name
        if ($h.ContainsKey($k)) { $h[$k]++ } else { $h[$k] = 1 }
    }
    try {
        if (-not (Test-Path -LiteralPath $CacheDir)) { [void](New-Item -ItemType Directory -Path $CacheDir) }
        $o = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
        $json = ConvertTo-Json -Depth 3 -InputObject ([pscustomobject]@{ stamp = $stamp; counts = [pscustomobject]$o })
        [System.IO.File]::WriteAllText($cache, $json, $Utf8NoBom)
    } catch { }
    return $h
}

function Update-Bundled {
    $script:BundleSrc = $null; $script:BundleCounts = @{}
    foreach ($c in $CompilationNames) {
        if ($script:ByFile.ContainsKey($c)) {
            $g = $script:ByFile[$c]
            if ($g.Path -and (Test-Path -LiteralPath $g.Path)) {
                try { $script:BundleCounts = Get-BundledCounts $g; $script:BundleSrc = $g } catch { }
                break
            }
        }
    }
    $srcNorm = ''; if ($script:BundleSrc) { $srcNorm = Get-NormName $script:BundleSrc.File }
    foreach ($m in $script:Mods) {
        $m.InGenesis = 0; $m.GenesisVia = ''
        if (-not $script:BundleSrc -or $m -eq $script:BundleSrc -or $m.Special) { continue }
        $n = Get-NormName $m.File
        if ($n -eq $srcNorm) { continue }
        if ($script:BundleCounts.ContainsKey($n) -and $script:BundleCounts[$n] -ge $BundleMin) { $m.InGenesis = $script:BundleCounts[$n]; continue }
        $b = Get-TranslationBase $m.File
        if ($b) {
            $bn = Get-NormName $b
            if ($bn -ne $srcNorm -and $script:BundleCounts.ContainsKey($bn) -and $script:BundleCounts[$bn] -ge $BundleMin) { $m.GenesisVia = $b }
        }
    }
}

function Get-GenesisText($m) {
    if ($m.InGenesis -gt 0) { return "✔ в составе ($($m.InGenesis))" }
    if ($m.GenesisVia) { return 'перевод, оригинал в составе' }
    return ''
}

# ---------------------------------------------------------------- RE_Kenshi
function Get-REKenshi {
    $dll = Join-Path $KenshiDir 'RE_Kenshi.dll'
    if (-not (Test-Path -LiteralPath $dll)) { return $null }
    $ver = ''; $lib = ''
    $log = Join-Path $KenshiDir 'RE_Kenshi_log.txt'
    if (Test-Path -LiteralPath $log) {
        foreach ($l in (Get-Content -LiteralPath $log -TotalCount 30 -ErrorAction SilentlyContinue)) {
            if (-not $ver -and $l -match 'RE_Kenshi:\s*RE_Kenshi\s+([\d\.]+)') { $ver = $Matches[1] }
            if (-not $lib -and $l -match 'KenshiLib:\s*KenshiLib\s+([\d\.]+)') { $lib = $Matches[1] }
        }
    }
    $active = $false
    $pcfg = Join-Path $KenshiDir 'Plugins_x64.cfg'
    if (Test-Path -LiteralPath $pcfg) {
        foreach ($l in [System.IO.File]::ReadAllLines($pcfg)) { if ($l.Trim() -match '^Plugin\s*=\s*RE_Kenshi\s*$') { $active = $true } }
    }
    $title = 'RE_Kenshi установлен'
    $parts = @(); if ($ver) { $parts += "версия $ver" }; if ($lib) { $parts += "KenshiLib $lib" }
    if ($parts.Count) { $title += ' (' + ($parts -join ', ') + ')' }
    $problem = ''
    if (-not $active) { $problem = 'не прописан в Plugins_x64.cfg — игра его не загрузит' }
    return [pscustomobject]@{
        Special = $true; File = 'RE_Kenshi.dll'; Key = '_rekenshi'; Title = $title; Version = $ver; Lib = $lib
        Active = $active; Problem = $problem; Dir = (Join-Path $KenshiDir 'RE_Kenshi')
        Downloaded = (Get-Item -LiteralPath $dll).LastWriteTime
    }
}

# ---------------------------------------------------------------- авто-порядок
$RulesPath = Join-Path $KenshiDir 'KenshiModManager.rules.txt'
$DefaultRules = @'
# Правила авто-порядка для Kenshi Mod Manager.
# Формат строки:   МодА.mod > МодБ.mod   — МодА должен стоять НИЖЕ (грузиться после) МодБ
#                  МодА.mod < МодБ.mod   — МодА должен стоять ВЫШЕ (грузиться раньше) МодБ
# Строки с # — комментарии. Правило применяется, только если оба мода включены.
# Зависимости из самих .mod файлов и «перевод под оригиналом» учитываются автоматически.

GenesisRUS.mod > Genesis.mod
GenesisBarFix.mod > GenesisRUS.mod
GenesisBarFix.mod > Genesis.mod
Russian Translation Fix Plus.mod < Genesis.mod
Slopeless.mod < Genesis.mod
'@

function Get-Rules {
    if (-not (Test-Path -LiteralPath $RulesPath)) {
        try { [System.IO.File]::WriteAllText($RulesPath, ($DefaultRules -replace "`r?`n", "`r`n"), $Utf8NoBom) } catch { }
    }
    $text = $DefaultRules
    if (Test-Path -LiteralPath $RulesPath) { $text = [System.IO.File]::ReadAllText($RulesPath) }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^(.+?\.mod)\s*([<>])\s*(.+?\.mod)$') {
            $a = $Matches[1].Trim(); $b = $Matches[3].Trim()
            if ($Matches[2] -eq '>') { $list.Add(@($b, $a, "правило: $a ниже $b", 'late')) }   # b перед a, опускаем a
            else { $list.Add(@($a, $b, "правило: $a выше $b", 'early')) }                    # a перед b, поднимаем a
        }
    }
    return $list
}

function Get-TranslationBase([string]$file) {
    $n = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $pats = @('\s*-\s*RUS\b.*$', '\s*\[RU\]\s*$', '\s*\[RUS\]\s*$', '\s*\(rus\)\s*$', '\s+RUS patch\s*$', '\s+Rus patch\s*$',
              '\s+RUS\s*$', '\s+Rus\s*$', '\s+RU\s*$', '\s+rus\s*$', '_rus\s*$', '_ru\s*$', '\s*RUS\s*$')
    foreach ($p in $pats) {
        $b = [regex]::Replace($n, $p, '', 'IgnoreCase')
        if ($b -ne $n -and $b.Trim()) { return ($b.Trim() + '.mod') }
    }
    return $null
}

# Возвращает новый порядок. Нарушенные правила чинятся точечно:
#   перевод        -> опускаем перевод сразу под оригинал
#   зависимость    -> поднимаем зависимость сразу над модом, которому она нужна
#   правило "А < Б" -> поднимаем А над Б;  правило "А > Б" -> опускаем А под Б
function Get-AutoOrder {
    $ord = New-Object System.Collections.Generic.List[string]
    foreach ($f in $script:Order) { $ord.Add($f) }
    $canon = @{}; foreach ($f in $ord) { $canon[$f.ToLowerInvariant()] = $f }
    # ребро: @(раньше, позже, причина, кого двигать: 'early' = поднять первый, 'late' = опустить второй)
    $edges = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($ord)) {
        $m = $script:ByFile[$f.ToLowerInvariant()]
        if ($m) {
            foreach ($d in $m.Deps) {
                $dk = $d.ToLowerInvariant()
                if ($canon.ContainsKey($dk) -and $BaseMasters -notcontains $dk) { $edges.Add(@($canon[$dk], $f, "зависимость для $f", 'early')) }
            }
        }
        $b = Get-TranslationBase $f
        if ($b -and $canon.ContainsKey($b.ToLowerInvariant())) { $edges.Add(@($canon[$b.ToLowerInvariant()], $f, "перевод для $($canon[$b.ToLowerInvariant()])", 'late')) }
    }
    foreach ($r in (Get-Rules)) {
        $a = $r[0].ToLowerInvariant(); $b = $r[1].ToLowerInvariant()
        if ($canon.ContainsKey($a) -and $canon.ContainsKey($b)) { $edges.Add(@($canon[$a], $canon[$b], $r[2], $r[3])) }
    }
    # отбрасываем рёбра, которые образуют цикл
    $succ = @{}; foreach ($f in $ord) { $succ[$f] = New-Object System.Collections.Generic.List[string] }
    $good = New-Object System.Collections.Generic.List[object]; $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($e in $edges) {
        $a = $e[0]; $b = $e[1]
        if ($a -eq $b) { continue }
        $seen = @{}; $st = New-Object System.Collections.Generic.Stack[string]; $st.Push($b); $cyc = $false
        while ($st.Count) { $x = $st.Pop(); if ($x -eq $a) { $cyc = $true; break }
            if ($seen.ContainsKey($x)) { continue }; $seen[$x] = 1; foreach ($y in $succ[$x]) { $st.Push($y) } }
        if ($cyc) { $skipped.Add("$($e[2]) — противоречит другим правилам, пропущено"); continue }
        if (-not $succ[$a].Contains($b)) { $succ[$a].Add($b) }
        $good.Add($e)
    }
    $why = @{}
    for ($iter = 0; $iter -lt 5000; $iter++) {
        $pos = @{}; for ($i = 0; $i -lt $ord.Count; $i++) { $pos[$ord[$i]] = $i }
        $bad = $null
        foreach ($e in $good) { if ($pos[$e[0]] -gt $pos[$e[1]]) { $bad = $e; break } }
        if (-not $bad) { break }
        $a = $bad[0]; $b = $bad[1]
        if ($bad[3] -eq 'early') {
            $ord.RemoveAt($pos[$a]); $ord.Insert($ord.IndexOf($b), $a); $why[$a] = $bad[2]
        } else {
            $ord.RemoveAt($pos[$b]); $ord.Insert($ord.IndexOf($a) + 1, $b); $why[$b] = $bad[2]
        }
    }
    return [pscustomobject]@{ Order = $ord; Why = $why; Skipped = $skipped }
}

function Get-OrderChanges($old, $auto) {
    $o = @{}; for ($i = 0; $i -lt $old.Count; $i++) { $o[$old[$i]] = $i }
    $n = @{}; for ($i = 0; $i -lt $auto.Order.Count; $i++) { $n[$auto.Order[$i]] = $i }
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($k in $auto.Why.Keys) {
        if ($o[$k] -ne $n[$k]) { $res.Add([pscustomobject]@{ File = $k; From = $o[$k] + 1; To = $n[$k] + 1; Why = $auto.Why[$k] }) }
    }
    return @($res | Sort-Object To)
}

# ---------------------------------------------------------------- режим проверки без окна
if ($TestDataOnly) {
    Load-All; Load-Status; Update-Bundled; Update-Problems
    "Найдено модов: $($script:Mods.Count); включено: $($script:Order.Count)"
    $rk = Get-REKenshi
    if ($rk) { "   [зелёная строка] $($rk.Title) $($rk.Problem)" } else { "   RE_Kenshi не найден" }
    $i = 0
    foreach ($n in $script:Order) {
        $i++; $m = $script:ByFile[$n.ToLowerInvariant()]
        "{0,4}  {1,-40} {2,-32} {3,-14} {4,-16} {5}" -f $i, $m.Title, $m.File, (Get-StatusText $m.Key), (Format-Date $m.Downloaded), $m.Problem
    }
    "--- выключенные ---"
    $script:Mods | Where-Object { (Get-OrderIndex $_.File) -lt 0 } | Sort-Object Title |
        ForEach-Object { "      {0,-40} {1,-32} {2}" -f $_.Title, $_.File, $_.Problem }
    "--- превью найдено у: $(@($script:Mods | Where-Object { $_.Preview }).Count) модов"
    "--- в составе $($script:BundleSrc.File):"
    $script:Mods | Where-Object { $_.InGenesis -gt 0 -or $_.GenesisVia } | Sort-Object { -$_.InGenesis } | ForEach-Object {
        $on = 'выкл'; $i = Get-OrderIndex $_.File; if ($i -ge 0) { $on = "№$($i + 1)" }
        "   {0,-42} {1,-28} {2,-6} {3}" -f $_.File, (Get-GenesisText $_), $on, $_.Problem }
    $a = Get-AutoOrder
    $ch = Get-OrderChanges @($script:Order) $a
    "--- авто-порядок: передвинуто $($ch.Count), отброшено правил (циклы): $($a.Skipped.Count)"
    foreach ($c in $ch) { "   {0,-45} {1,4} -> {2,4}   ({3})" -f $c.File, $c.From, $c.To, $c.Why }
    foreach ($s in $a.Skipped) { "   ! $s" }
    return
}

# ---------------------------------------------------------------- окно
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KmmNative {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
}
'@
} catch { }

function Set-DarkTitle($ctl) {
    try { $v = 1; [void][KmmNative]::DwmSetWindowAttribute($ctl.Handle, 20, [ref]$v, 4) } catch { }
}
function Set-DarkScroll($ctl) {
    try { [void][KmmNative]::SetWindowTheme($ctl.Handle, 'DarkMode_Explorer', $null) } catch { }
}

# --- палитра
function RGB($r, $g, $b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Pal = @{
    Bg       = RGB 24 21 19
    Panel    = RGB 33 29 26
    Panel2   = RGB 43 38 33
    Hover    = RGB 58 51 44
    Row      = RGB 30 27 24
    RowAlt   = RGB 35 31 28
    Sel      = RGB 88 62 32
    Line     = RGB 46 41 36
    Border   = RGB 66 58 50
    Text     = RGB 234 226 214
    Muted    = RGB 152 141 128
    Off      = RGB 118 110 101
    Accent   = RGB 232 158 70
    AccentHi = RGB 246 180 96
    AccentDk = RGB 30 20 10
    Ok       = RGB 120 212 132
    Bad      = RGB 242 108 98
    WarnTxt  = RGB 240 200 100
    WarnBg   = RGB 64 52 24
    ErrBg    = RGB 78 34 32
    Genesis  = RGB 128 178 255
    RkBg     = RGB 27 56 33
    RkTxt    = RGB 140 226 155
}
$FontUI    = New-Object System.Drawing.Font('Segoe UI', 9.75)
$FontBold  = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$FontHead  = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$FontNum   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$FontCap   = New-Object System.Drawing.Font('Segoe UI Semibold', 8.25)
$FontBrand = New-Object System.Drawing.Font('Segoe UI Black', 12)
$TF = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
$BrHeader  = New-Object System.Drawing.SolidBrush($Pal.Panel2)
$BrAccent  = New-Object System.Drawing.SolidBrush($Pal.Accent)
$PenLine   = New-Object System.Drawing.Pen($Pal.Line)
$PenBorder = New-Object System.Drawing.Pen($Pal.Border)
$PenMuted  = New-Object System.Drawing.Pen($Pal.Muted, 1.5)
$PenCheck  = New-Object System.Drawing.Pen($Pal.AccentDk, 2.2)
$PenAccent = New-Object System.Drawing.Pen($Pal.Accent, 2)

$ThumbW = 72; $ThumbH = 40

function Load-Bitmap([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    try {
        $img = [System.Drawing.Image]::FromStream($ms)
        try { return (New-Object System.Drawing.Bitmap($img)) } finally { $img.Dispose() }
    } finally { $ms.Dispose() }
}

function New-Fitted([System.Drawing.Image]$src, [int]$w, [int]$h) {
    $b = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($b)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::FromArgb(20, 18, 16))
        $k = [Math]::Min($w / $src.Width, $h / $src.Height)
        $dw = [int]($src.Width * $k); $dh = [int]($src.Height * $k)
        $g.DrawImage($src, [int](($w - $dw) / 2), [int](($h - $dh) / 2), $dw, $dh)
    } finally { $g.Dispose() }
    return $b
}

function Get-Thumb($m) {
    if (-not $m.Preview) { return $null }
    $safe = ($m.Key -replace '[^\w\.\-]', '_') + '_' + $m.Id + '.png'
    $cache = Join-Path $CacheDir $safe
    try {
        $srcTime = (Get-Item -LiteralPath $m.Preview).LastWriteTime
        if ((Test-Path -LiteralPath $cache) -and (Get-Item -LiteralPath $cache).LastWriteTime -ge $srcTime) {
            return (Load-Bitmap $cache)
        }
        $full = Load-Bitmap $m.Preview
        try { $t = New-Fitted $full $ThumbW $ThumbH } finally { $full.Dispose() }
        try {
            if (-not (Test-Path -LiteralPath $CacheDir)) { [void](New-Item -ItemType Directory -Path $CacheDir) }
            $t.Save($cache, [System.Drawing.Imaging.ImageFormat]::Png)
        } catch { }
        return $t
    } catch { return $null }
}

# --- общие «стилизаторы»
function Style-Button($b, [string]$kind = 'normal') {
    $b.FlatStyle = 'Flat'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderSize = 1
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    switch ($kind) {
        'primary' {
            $b.BackColor = $Pal.Accent; $b.ForeColor = $Pal.AccentDk
            $b.FlatAppearance.BorderColor = $Pal.Accent
            $b.FlatAppearance.MouseOverBackColor = $Pal.AccentHi
            $b.FlatAppearance.MouseDownBackColor = $Pal.Accent
            $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
            $b.TextAlign = 'MiddleCenter'; $b.Padding = New-Object System.Windows.Forms.Padding(0)
        }
        default {
            $b.BackColor = $Pal.Panel2; $b.ForeColor = $Pal.Text
            $b.FlatAppearance.BorderColor = $Pal.Border
            $b.FlatAppearance.MouseOverBackColor = $Pal.Hover
            $b.FlatAppearance.MouseDownBackColor = $Pal.Sel
            $b.Font = $FontUI
        }
    }
}

function Style-Dialog($f) {
    $f.BackColor = $Pal.Bg; $f.ForeColor = $Pal.Text; $f.Font = $FontUI
    $f.Add_HandleCreated({ param($s, $e) Set-DarkTitle $s })
    $stack = New-Object System.Collections.Generic.Stack[object]; $stack.Push($f)
    while ($stack.Count) {
        $c = $stack.Pop()
        foreach ($ch in $c.Controls) { $stack.Push($ch) }
        if ($c -is [System.Windows.Forms.Button]) { Style-Button $c; $c.TextAlign = 'MiddleCenter'; $c.Padding = New-Object System.Windows.Forms.Padding(0) }
        elseif ($c -is [System.Windows.Forms.ListView]) { $c.BackColor = $Pal.Row; $c.ForeColor = $Pal.Text; $c.BorderStyle = 'None'; $c.Add_HandleCreated({ param($s, $e) Set-DarkScroll $s }) }
        elseif ($c -is [System.Windows.Forms.NumericUpDown]) { $c.BackColor = $Pal.Panel2; $c.ForeColor = $Pal.Text; $c.BorderStyle = 'FixedSingle' }
        elseif ($c -is [System.Windows.Forms.Panel]) { $c.BackColor = $Pal.Panel }
    }
}

# ---------------------------------------------------------------- форма
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Kenshi Mod Manager'
$form.Size = New-Object System.Drawing.Size(1560, 920)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = $FontUI
$form.BackColor = $Pal.Bg
$form.ForeColor = $Pal.Text
$form.KeyPreview = $true
$form.Add_HandleCreated({ Set-DarkTitle $form })

# --- верхняя панель
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 56; $top.BackColor = $Pal.Panel
$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Text = 'KENSHI  MOD  MANAGER'; $lblBrand.Font = $FontBrand; $lblBrand.ForeColor = $Pal.Accent
$lblBrand.AutoSize = $true; $lblBrand.Location = New-Object System.Drawing.Point(16, 16)
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Поиск'; $lblSearch.ForeColor = $Pal.Muted; $lblSearch.AutoSize = $true
$lblSearch.Location = New-Object System.Drawing.Point(262, 19)
$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(312, 15); $txtSearch.Width = 360
$txtSearch.BackColor = $Pal.Panel2; $txtSearch.ForeColor = $Pal.Text; $txtSearch.BorderStyle = 'FixedSingle'
$txtSearch.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
function New-Combo($x, $w, $items) {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'
    $cb.BackColor = $Pal.Panel2; $cb.ForeColor = $Pal.Text
    $cb.Location = New-Object System.Drawing.Point($x, 16); $cb.Width = $w
    [void]$cb.Items.AddRange($items); $cb.SelectedIndex = 0
    $top.Controls.Add($cb); return $cb
}
$cmbFilter = New-Combo 688 210 @('Все моды', 'Только включённые', 'Только выключенные', 'Только с проблемами', 'Только входящие в Genesis')
$cmbStatus = New-Combo 908 170 @('Любой статус', '✔ Работает', '✖ Не работает', '— Не отмечен')
$top.Controls.AddRange(@($lblBrand, $lblSearch, $txtSearch))

# --- нижняя строка состояния
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 28; $statusBar.BackColor = $Pal.Panel
$lblCount = New-Object System.Windows.Forms.Label
$lblCount.AutoSize = $true; $lblCount.ForeColor = $Pal.Muted; $lblCount.Location = New-Object System.Drawing.Point(14, 6)
$lblDirty = New-Object System.Windows.Forms.Label
$lblDirty.AutoSize = $true; $lblDirty.ForeColor = $Pal.Accent; $lblDirty.Font = $FontBold
$lblDirty.Anchor = 'Top, Right'; $lblDirty.Location = New-Object System.Drawing.Point(900, 5)
$statusBar.Controls.AddRange(@($lblCount, $lblDirty))
$statusBar.Add_Resize({ $lblDirty.Left = $statusBar.Width - $lblDirty.Width - 16 })

# --- правая панель: кнопки
$right = New-Object System.Windows.Forms.FlowLayoutPanel
$right.Dock = 'Right'; $right.Width = 226; $right.FlowDirection = 'TopDown'; $right.WrapContents = $false
$right.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10); $right.BackColor = $Pal.Panel; $right.AutoScroll = $true
function New-Btn($text, $h = 32, $kind = 'normal') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Width = 200; $b.Height = $h
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    Style-Button $b $kind
    $right.Controls.Add($b); return $b
}
function New-Caption($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text.ToUpper(); $l.Width = 200; $l.Height = 22; $l.Font = $FontCap; $l.ForeColor = $Pal.Accent
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 2)
    $right.Controls.Add($l)
}
New-Caption 'Порядок загрузки'
$btnAuto   = New-Btn '⚡  Авто-порядок' 38
$btnAuto.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10); $btnAuto.ForeColor = $Pal.AccentHi
$btnRules  = New-Btn '⚙  Правила авто-порядка'
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Моды можно перетаскивать мышью (при сортировке по №).'; $hint.Width = 200; $hint.Height = 36
$hint.ForeColor = $Pal.Muted; $hint.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4); $right.Controls.Add($hint)
$btnUp     = New-Btn '▲  Выше   (Alt+↑)'
$btnDown   = New-Btn '▼  Ниже   (Alt+↓)'
$btnTop    = New-Btn '⤒  В начало'
$btnBottom = New-Btn '⤓  В конец'
$btnMoveTo = New-Btn '#  На позицию…'
New-Caption 'Моя отметка'
$btnOk     = New-Btn '✔  Работает   (Ctrl+1)'
$btnBad    = New-Btn '✖  Не работает   (Ctrl+2)'
$btnNone   = New-Btn '—  Сбросить   (Ctrl+0)'
$btnOk.ForeColor = $Pal.Ok; $btnBad.ForeColor = $Pal.Bad
New-Caption 'Мод'
$btnSteam  = New-Btn '🌐  Открыть в Steam'
$btnFolder = New-Btn '📁  Открыть папку'
New-Caption 'Список'
$btnReload = New-Btn '↺  Отменить изменения'
$btnSave   = New-Btn '💾  Сохранить   (Ctrl+S)' 36
$spacer = New-Object System.Windows.Forms.Label; $spacer.Height = 6; $spacer.Width = 200; $right.Controls.Add($spacer)
$btnPlay   = New-Btn '▶  Сохранить и играть' 52 'primary'

# --- левая панель: карточка мода
$left = New-Object System.Windows.Forms.Panel
$left.Dock = 'Left'; $left.Width = 430; $left.BackColor = $Pal.Panel
$left.Padding = New-Object System.Windows.Forms.Padding(14, 14, 10, 12)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Top'; $pic.Height = 228; $pic.SizeMode = 'Zoom'; $pic.BackColor = RGB 20 18 16
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Dock = 'Top'; $lblTitle.Height = 64; $lblTitle.Font = $FontTitle; $lblTitle.ForeColor = $Pal.Text
$lblTitle.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0); $lblTitle.AutoEllipsis = $true
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = 'Fill'; $rtb.ReadOnly = $true; $rtb.BorderStyle = 'None'; $rtb.BackColor = $Pal.Panel; $rtb.ForeColor = $Pal.Text
$rtb.Font = $FontUI; $rtb.DetectUrls = $true; $rtb.ScrollBars = 'Vertical'; $rtb.Cursor = [System.Windows.Forms.Cursors]::Arrow
$rtb.Add_HandleCreated({ Set-DarkScroll $rtb })
$rtb.Add_LinkClicked({ param($s, $e) try { Start-Process $e.LinkText } catch { } })
$left.Controls.Add($rtb)
$left.Controls.Add($lblTitle)
$left.Controls.Add($pic)
$splitL = New-Object System.Windows.Forms.Splitter
$splitL.Dock = 'Left'; $splitL.Width = 3; $splitL.BackColor = $Pal.Line

# --- список
$images = New-Object System.Windows.Forms.ImageList
$images.ColorDepth = 'Depth32Bit'
$images.ImageSize = New-Object System.Drawing.Size($ThumbW, $ThumbH)
$blank = New-Object System.Drawing.Bitmap($ThumbW, $ThumbH)
$gb = [System.Drawing.Graphics]::FromImage($blank); $gb.Clear((RGB 40 36 32)); $gb.Dispose()
$images.Images.Add('_none', $blank)

$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
$lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.GridLines = $false
$lv.BorderStyle = 'None'; $lv.BackColor = $Pal.Row; $lv.ForeColor = $Pal.Text; $lv.Font = $FontUI
$lv.SmallImageList = $images
$lv.OwnerDraw = $true
try { $lv.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($lv, $true, $null) } catch { }
$lv.Add_HandleCreated({ Set-DarkScroll $lv })
[void]$lv.Columns.Add('№', 136)
[void]$lv.Columns.Add('Название', 330)
[void]$lv.Columns.Add('Мой статус', 120)
[void]$lv.Columns.Add('Genesis', 170)
[void]$lv.Columns.Add('Скачан', 125)
[void]$lv.Columns.Add('Файл .mod', 230)
[void]$lv.Columns.Add('Источник', 140)
[void]$lv.Columns.Add('Проблемы', 360)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.BackColor = $Pal.Panel2; $menu.ForeColor = $Pal.Text; $menu.ShowImageMargin = $false; $menu.Font = $FontUI
$miOk   = $menu.Items.Add('✔  Работает')
$miBad  = $menu.Items.Add('✖  Не работает')
$miNone = $menu.Items.Add('—  Сбросить отметку')
[void]$menu.Items.Add('-')
$miSteam  = $menu.Items.Add('Открыть в Steam')
$miFolder = $menu.Items.Add('Открыть папку мода')
$miOk.ForeColor = $Pal.Ok; $miBad.ForeColor = $Pal.Bad
$lv.ContextMenuStrip = $menu

$form.Controls.Add($lv)
$form.Controls.Add($splitL)
$form.Controls.Add($left)
$form.Controls.Add($right)
$form.Controls.Add($statusBar)
$form.Controls.Add($top)

# --- отрисовка списка
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $g = $e.Graphics; $b = $e.Bounds
    $g.FillRectangle($BrHeader, $b)
    $txt = $e.Header.Text
    if ($e.ColumnIndex -eq $script:SortCol) {
        if ($e.ColumnIndex -eq 0) { $txt += '  ▲' } elseif ($script:SortDesc) { $txt += '  ▼' } else { $txt += '  ▲' }
    }
    $r = New-Object System.Drawing.Rectangle(($b.X + 8), $b.Y, [Math]::Max(0, $b.Width - 10), $b.Height)
    $col = $Pal.Muted; if ($e.ColumnIndex -eq $script:SortCol) { $col = $Pal.Accent }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $FontHead, $r, $col, $TF)
    $g.DrawLine($PenBorder, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
    $g.DrawLine($PenLine, $b.Right - 1, $b.Top + 6, $b.Right - 1, $b.Bottom - 6)
})
$lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $false })
$lv.Add_DrawSubItem({
    param($s, $e)
    $g = $e.Graphics; $it = $e.Item; $si = $e.SubItem; $b = $e.Bounds
    if ($e.ColumnIndex -eq 0) { $b = New-Object System.Drawing.Rectangle($b.X, $b.Y, $lv.Columns[0].Width, $b.Height) }
    $bg = $si.BackColor; if ($it.Selected) { $bg = $Pal.Sel }
    $br = New-Object System.Drawing.SolidBrush($bg); $g.FillRectangle($br, $b); $br.Dispose()
    if ($e.ColumnIndex -eq 0) {
        if ($it.Selected) { $g.FillRectangle($BrAccent, $b.X, $b.Y, 3, $b.Height) }
        $cy = $b.Y + [int](($b.Height - 15) / 2)
        $cr = New-Object System.Drawing.Rectangle(($b.X + 6), $cy, 15, 15)
        $g.SmoothingMode = 'AntiAlias'
        if ($it.Checked) {
            $g.FillRectangle($BrAccent, $cr)
            $pts = [System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point(($cr.X + 3), ($cr.Y + 8))),
                (New-Object System.Drawing.Point(($cr.X + 6), ($cr.Y + 11))),
                (New-Object System.Drawing.Point(($cr.X + 12), ($cr.Y + 4))))
            $g.DrawLines($PenCheck, $pts)
        } else {
            $g.DrawRectangle($PenMuted, $cr)
        }
        $g.SmoothingMode = 'Default'
        $ii = -1; if ($it.ImageKey) { $ii = $images.Images.IndexOfKey($it.ImageKey) }
        if ($ii -ge 0) { $images.Draw($g, ($b.X + 28), ($b.Y + [int](($b.Height - $ThumbH) / 2)), $ii) }
        $tr = New-Object System.Drawing.Rectangle(($b.X + 28 + $ThumbW + 8), $b.Y, [Math]::Max(0, $b.Width - (36 + $ThumbW)), $b.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $si.Text, $FontNum, $tr, $si.ForeColor, $TF)
    } else {
        $tr = New-Object System.Drawing.Rectangle(($b.X + 8), $b.Y, [Math]::Max(0, $b.Width - 10), $b.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $si.Text, $si.Font, $tr, $si.ForeColor, $TF)
    }
    $g.DrawLine($PenLine, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
})

$script:Filling = $false
$script:RK = $null
$script:SortCol = 0
$script:SortDesc = $false

function Get-SelectedMod {
    if ($lv.SelectedItems.Count -eq 0) { return $null }
    return $lv.SelectedItems[0].Tag
}

function Refresh-List([string]$keepFile) {
    if (-not $keepFile) { $s = Get-SelectedMod; if ($s) { $keepFile = $s.File } }
    Update-Problems
    $q = $txtSearch.Text.Trim().ToLowerInvariant()
    $flt = $cmbFilter.SelectedIndex
    $sflt = $cmbStatus.SelectedIndex
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $script:Order.Count; $i++) {
        $rows.Add([pscustomobject]@{ M = $script:ByFile[$script:Order[$i].ToLowerInvariant()]; N = $i + 1 })
    }
    foreach ($m in ($script:Mods | Where-Object { (Get-OrderIndex $_.File) -lt 0 } | Sort-Object Title)) {
        $rows.Add([pscustomobject]@{ M = $m; N = 0 })
    }
    $vis = @($rows | Where-Object {
        $m = $_.M; $on = ($_.N -gt 0)
        if ($flt -eq 1 -and -not $on) { return $false }
        if ($flt -eq 2 -and $on) { return $false }
        if ($flt -eq 3 -and $m.Level -eq 0) { return $false }
        if ($flt -eq 4 -and $m.InGenesis -eq 0 -and -not $m.GenesisVia) { return $false }
        $st = ''; if ($script:Status.ContainsKey($m.Key)) { $st = $script:Status[$m.Key] }
        if ($sflt -eq 1 -and $st -ne 'ok') { return $false }
        if ($sflt -eq 2 -and $st -ne 'bad') { return $false }
        if ($sflt -eq 3 -and $st -ne '') { return $false }
        if ($q) {
            $hay = ($m.Title + ' ' + $m.File + ' ' + $m.Id + ' ' + $m.Author).ToLowerInvariant()
            if (-not $hay.Contains($q)) { return $false }
        }
        return $true
    })
    if ($script:SortCol -ne 0) {
        switch ($script:SortCol) {
            1 { $key = { $_.M.Title } }
            2 { $key = { $st = 1; if ($script:Status.ContainsKey($_.M.Key)) { if ($script:Status[$_.M.Key] -eq 'ok') { $st = 0 } else { $st = 2 } }; $st } }
            3 { $key = { if ($_.M.InGenesis -gt 0) { -$_.M.InGenesis } elseif ($_.M.GenesisVia) { 0 } else { 1 } } }
            4 { $key = { if ($_.M.Downloaded) { $_.M.Downloaded } else { [datetime]::MinValue } } }
            5 { $key = { $_.M.File } }
            6 { $key = { $_.M.Source + ' ' + $_.M.Id } }
            7 { $key = { -$_.M.Level } }
        }
        $vis = @($vis | Sort-Object -Property @{ Expression = $key; Descending = $script:SortDesc }, @{ Expression = { $_.M.Title } })
    }
    $script:Filling = $true
    $lv.BeginUpdate(); $lv.Items.Clear()
    $sel = $null
    if ($script:RK) {
        $rk = $script:RK
        $it = New-Object System.Windows.Forms.ListViewItem('RE')
        $it.UseItemStyleForSubItems = $false
        foreach ($t in @($rk.Title, 'всегда включён', '', (Format-Date $rk.Downloaded), $rk.File, 'папка игры', $rk.Problem)) { [void]$it.SubItems.Add($t) }
        $it.Checked = $true; $it.Tag = $rk
        $bg = $Pal.RkBg; $fg = $Pal.RkTxt
        if (-not $rk.Active) { $bg = $Pal.ErrBg; $fg = $Pal.Bad }
        foreach ($si in $it.SubItems) { $si.BackColor = $bg; $si.ForeColor = $fg; $si.Font = $FontBold }
        [void]$lv.Items.Add($it)
        if ($keepFile -eq $rk.File) { $sel = $it }
    }
    $row = 0
    foreach ($r in $vis) {
        $m = $r.M; $on = ($r.N -gt 0)
        $num = ''; if ($on) { $num = [string]$r.N }
        $it = New-Object System.Windows.Forms.ListViewItem($num)
        $it.UseItemStyleForSubItems = $false
        $it.ImageKey = $m.ImageKey
        [void]$it.SubItems.Add($m.Title)
        $stItem = $it.SubItems.Add((Get-StatusText $m.Key))
        $gItem = $it.SubItems.Add((Get-GenesisText $m))
        [void]$it.SubItems.Add((Format-Date $m.Downloaded))
        [void]$it.SubItems.Add($m.File)
        $src = $m.Source; if ($m.Id) { $src = "Workshop $($m.Id)" }
        [void]$it.SubItems.Add($src)
        $prItem = $it.SubItems.Add($m.Problem)
        $it.Checked = $on; $it.Tag = $m
        $bg = $Pal.Row; if ($row % 2 -eq 1) { $bg = $Pal.RowAlt }
        if ($m.Level -eq 2) { $bg = $Pal.ErrBg } elseif ($m.Level -eq 1) { $bg = $Pal.WarnBg }
        $fg = $Pal.Text; if (-not $on) { $fg = $Pal.Off }
        foreach ($si in $it.SubItems) { $si.BackColor = $bg; $si.ForeColor = $fg; $si.Font = $FontUI }
        $it.SubItems[1].Font = $FontBold
        if (-not $on) { $it.SubItems[1].Font = $FontUI }
        if ($m.InGenesis -gt 0 -or $m.GenesisVia) { $gItem.ForeColor = $Pal.Genesis }
        if ($m.Level -eq 2) { $prItem.ForeColor = $Pal.Bad } elseif ($m.Level -eq 1) { $prItem.ForeColor = $Pal.WarnTxt }
        if ($script:Status.ContainsKey($m.Key)) {
            if ($script:Status[$m.Key] -eq 'ok') { $stItem.ForeColor = $Pal.Ok } else { $stItem.ForeColor = $Pal.Bad }
            $stItem.Font = $FontBold
        } else { $stItem.ForeColor = $Pal.Off }
        [void]$lv.Items.Add($it)
        if ($keepFile -and $m.File -eq $keepFile) { $sel = $it }
        $row++
    }
    $lv.EndUpdate()
    if ($sel) { $sel.Selected = $true; $sel.EnsureVisible() }
    $script:Filling = $false
    $bad = @($script:Mods | Where-Object { $_.Level -eq 2 }).Count
    $warn = @($script:Mods | Where-Object { $_.Level -eq 1 }).Count
    $okc = @($script:Status.Values | Where-Object { $_ -eq 'ok' }).Count
    $badc = @($script:Status.Values | Where-Object { $_ -eq 'bad' }).Count
    $lblCount.Text = "Показано: $($vis.Count)     Включено: $($script:Order.Count) из $($script:Mods.Count)     Ошибок: $bad     Предупреждений: $warn     ✔ $okc     ✖ $badc"
    if ($script:Dirty) { $lblDirty.Text = '●  Есть несохранённые изменения' } else { $lblDirty.Text = '' }
    $lblDirty.Left = $statusBar.Width - $lblDirty.Width - 16
    $form.Text = 'Kenshi Mod Manager' + $(if ($script:Dirty) { '  •  не сохранено' } else { '' })
    Show-Details
}

function Add-Rtb([string]$text, $color, $font) {
    if (-not $font) { $font = $FontUI }
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $color; $rtb.SelectionFont = $font
    $rtb.AppendText($text)
}
function Add-RtbPair([string]$label, [string]$value, $vcolor) {
    if (-not $vcolor) { $vcolor = $Pal.Text }
    Add-Rtb ($label + '  ') $Pal.Muted $FontUI
    Add-Rtb ($value + "`n") $vcolor $FontUI
}

$script:PicImage = $null
function Show-Details {
    $m = Get-SelectedMod
    if ($script:PicImage) { $pic.Image = $null; $script:PicImage.Dispose(); $script:PicImage = $null }
    $rtb.Clear()
    if (-not $m) {
        $lblTitle.Text = 'Выберите мод'; $lblTitle.ForeColor = $Pal.Muted
        Add-Rtb "Щелчок по строке — карточка мода.`nГалочка — включить или выключить.`nДвойной щелчок — страница в Steam.`nПравый щелчок — отметка «работает / не работает».`nМоды можно перетаскивать мышью." $Pal.Muted
        return
    }
    $lblTitle.ForeColor = $Pal.Text
    if ($m.Special) {
        $lblTitle.Text = 'RE_Kenshi'; $lblTitle.ForeColor = $Pal.RkTxt
        if ($m.Active) { Add-RtbPair 'Состояние' 'подключён — загружается при каждом запуске игры' $Pal.Ok }
        else { Add-RtbPair 'Состояние' 'НЕ подключён в Plugins_x64.cfg — игра его не загрузит' $Pal.Bad }
        if ($m.Version) { Add-RtbPair 'Версия' $m.Version }
        if ($m.Lib) { Add-RtbPair 'KenshiLib' $m.Lib }
        Add-RtbPair 'Установлен' (Format-Date $m.Downloaded)
        Add-Rtb "`nRE_Kenshi — не мод, а отдельный загрузчик, который патчит саму игру. Включить или выключить его здесь нельзя.`n`nОн сам загружает DLL-плагины тех модов из списка, которые включены и у которых есть RE_Kenshi.json." $Pal.Text
        return
    }
    if ($m.Preview) { try { $script:PicImage = Load-Bitmap $m.Preview; $pic.Image = $script:PicImage } catch { } }
    $lblTitle.Text = $m.Title
    $idx = Get-OrderIndex $m.File
    if ($idx -ge 0) { Add-RtbPair 'Состояние' "включён, позиция $($idx + 1)" $Pal.Ok } else { Add-RtbPair 'Состояние' 'выключен' $Pal.Off }
    $stc = $Pal.Off; if ($script:Status.ContainsKey($m.Key)) { if ($script:Status[$m.Key] -eq 'ok') { $stc = $Pal.Ok } else { $stc = $Pal.Bad } }
    Add-RtbPair 'Моя отметка' (Get-StatusText $m.Key) $stc
    Add-RtbPair 'Файл' $m.File
    $src = $m.Source; if ($m.Id) { $src = "Workshop $($m.Id)" }
    Add-RtbPair 'Источник' $src
    if ($m.Author) { Add-RtbPair 'Автор' $m.Author }
    $upd = 'нет данных'; if ($m.AuthorUpdate) { $upd = Format-Date $m.AuthorUpdate }
    Add-RtbPair 'Скачан' "$(Format-Date $m.Downloaded)   (обновлён автором: $upd)"
    $deps = ($m.Deps | Where-Object { $BaseMasters -notcontains $_.ToLowerInvariant() }) -join ', '
    if (-not $deps) { $deps = '— (только игра)' }
    Add-RtbPair 'Зависимости' $deps
    if ($m.InGenesis -gt 0) {
        Add-Rtb "`nGENESIS  " $Pal.Genesis $FontBold
        Add-Rtb "Этот мод уже есть в составе $($script:BundleSrc.File) ($($m.InGenesis) записей). Отдельно его включать обычно не нужно; если он стоит ниже Genesis — перетирает версию Genesis.`n" $Pal.Genesis
    } elseif ($m.GenesisVia) {
        Add-Rtb "`nGENESIS  " $Pal.Genesis $FontBold
        Add-Rtb "Перевод мода $($m.GenesisVia), который есть в составе $($script:BundleSrc.File). Сам перевод может быть нужен, если GenesisRUS его не покрывает.`n" $Pal.Genesis
    }
    if ($m.Problem) {
        $pc = $Pal.WarnTxt; if ($m.Level -eq 2) { $pc = $Pal.Bad }
        Add-Rtb "`nПРОБЛЕМЫ  " $pc $FontBold
        Add-Rtb ($m.Problem + "`n") $pc
    }
    $desc = Get-CleanText $m.Description
    if ($desc) {
        Add-Rtb "`nОПИСАНИЕ`n" $Pal.Accent $FontCap
        Add-Rtb $desc $Pal.Text
    }
    $rtb.SelectionStart = 0; $rtb.ScrollToCaret()
}

function Set-Enabled($m, [bool]$on) {
    $idx = Get-OrderIndex $m.File
    if ($on -and $idx -lt 0) { $script:Order.Add($m.File); $script:Dirty = $true }
    elseif (-not $on -and $idx -ge 0) { $script:Order.RemoveAt($idx); $script:Dirty = $true }
}

function Set-ModStatus([string]$value) {
    $m = Get-SelectedMod
    if (-not $m -or $m.Special) { return }
    if ($value) { $script:Status[$m.Key] = $value } else { [void]$script:Status.Remove($m.Key) }
    try { Save-Status } catch {
        [System.Windows.Forms.MessageBox]::Show("Не удалось сохранить отметки: $($_.Exception.Message)", 'Kenshi Mod Manager', 'OK', 'Error') | Out-Null }
    Refresh-List $m.File
}

function Move-Selected([string]$how, [int]$target = -1) {
    $m = Get-SelectedMod
    if (-not $m -or $m.Special) { return }
    $idx = Get-OrderIndex $m.File
    if ($idx -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Мод выключен. Сначала включите его галочкой — он встанет в конец списка.', 'Kenshi Mod Manager') | Out-Null
        return
    }
    $last = $script:Order.Count - 1
    switch ($how) {
        'up'     { $new = [Math]::Max(0, $idx - 1) }
        'down'   { $new = [Math]::Min($last, $idx + 1) }
        'top'    { $new = 0 }
        'bottom' { $new = $last }
        'to'     { $new = [Math]::Min($last, [Math]::Max(0, $target)) }
    }
    Move-File $m.File $new
}

function Move-File([string]$file, [int]$new) {
    $idx = Get-OrderIndex $file
    if ($idx -lt 0 -or $new -eq $idx) { return }
    $new = [Math]::Min($script:Order.Count - 1, [Math]::Max(0, $new))
    $name = $script:Order[$idx]
    $script:Order.RemoveAt($idx); $script:Order.Insert($new, $name)
    $script:Dirty = $true
    Refresh-List $file
}

function Run-AutoOrder {
    $a = Get-AutoOrder
    $ch = Get-OrderChanges @($script:Order) $a
    if ($ch.Count -eq 0 -and $a.Skipped.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Порядок уже в порядке — ничего двигать не нужно.', 'Авто-порядок') | Out-Null
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Авто-порядок: будет передвинуто модов — $($ch.Count)"
    $f.Size = New-Object System.Drawing.Size(1000, 540); $f.StartPosition = 'CenterParent'
    $grid = New-Object System.Windows.Forms.ListView
    $grid.Dock = 'Fill'; $grid.View = 'Details'; $grid.FullRowSelect = $true
    [void]$grid.Columns.Add('Мод', 340); [void]$grid.Columns.Add('Было', 70); [void]$grid.Columns.Add('Станет', 70); [void]$grid.Columns.Add('Почему', 480)
    foreach ($c in $ch) {
        $t = $c.File; if ($script:ByFile.ContainsKey($c.File.ToLowerInvariant())) { $t = $script:ByFile[$c.File.ToLowerInvariant()].Title }
        $it = New-Object System.Windows.Forms.ListViewItem($t)
        [void]$it.SubItems.Add([string]$c.From); [void]$it.SubItems.Add([string]$c.To); [void]$it.SubItems.Add($c.Why)
        [void]$grid.Items.Add($it)
    }
    foreach ($s in $a.Skipped) {
        $it = New-Object System.Windows.Forms.ListViewItem('⚠ пропущено')
        [void]$it.SubItems.Add(''); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add($s)
        $it.ForeColor = $Pal.WarnTxt; [void]$grid.Items.Add($it)
    }
    $pnl = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnl.Dock = 'Bottom'; $pnl.Height = 52; $pnl.FlowDirection = 'RightToLeft'; $pnl.Padding = New-Object System.Windows.Forms.Padding(8)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Применить'; $ok.Width = 140; $ok.Height = 34; $ok.DialogResult = 'OK'
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Отмена'; $no.Width = 110; $no.Height = 34; $no.DialogResult = 'Cancel'
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Изменения применятся к списку; в игру они попадут после «Сохранить».'; $note.AutoSize = $true
    $note.Margin = New-Object System.Windows.Forms.Padding(0, 10, 20, 0); $note.ForeColor = $Pal.Muted
    $pnl.Controls.AddRange(@($ok, $no, $note))
    $f.Controls.Add($grid); $f.Controls.Add($pnl); $f.AcceptButton = $ok; $f.CancelButton = $no
    Style-Dialog $f
    Style-Button $ok 'primary'; $ok.Font = $FontBold
    if ($ch.Count -eq 0) { $ok.Enabled = $false }
    if ($f.ShowDialog($form) -eq 'OK') {
        $script:Order.Clear(); foreach ($x in $a.Order) { $script:Order.Add($x) }
        $script:Dirty = $true
        $script:SortCol = 0
        Refresh-List
    }
}

function Ask-Number([string]$prompt, [int]$def) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Позиция'; $f.Size = New-Object System.Drawing.Size(420, 160); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $l = New-Object System.Windows.Forms.Label; $l.Text = $prompt; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14, 14)
    $n = New-Object System.Windows.Forms.NumericUpDown; $n.Minimum = 1; $n.Maximum = [Math]::Max(1, $script:Order.Count)
    $n.Value = [Math]::Min($n.Maximum, [Math]::Max(1, $def)); $n.Location = New-Object System.Drawing.Point(14, 46); $n.Width = 110
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.Location = New-Object System.Drawing.Point(140, 44); $ok.Width = 90; $ok.Height = 30
    $f.Controls.AddRange(@($l, $n, $ok)); $f.AcceptButton = $ok
    Style-Dialog $f
    if ($f.ShowDialog($form) -eq 'OK') { return [int]$n.Value }
    return -1
}

function Confirm-KenshiClosed {
    $p = Get-Process -Name 'kenshi_x64', 'Kenshi_x64' -ErrorAction SilentlyContinue
    if ($p) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Kenshi сейчас запущен. Лаунчер игры при выходе может перезаписать список модов.`r`nВсё равно сохранить?",
            'Kenshi Mod Manager', 'YesNo', 'Warning')
        return ($r -eq 'Yes')
    }
    return $true
}

function Confirm-Problems {
    $bad = @($script:Mods | Where-Object { $_.Level -eq 2 -and (Get-OrderIndex $_.File) -ge 0 })
    if ($bad.Count -gt 0) {
        $list = ($bad | Select-Object -First 8 | ForEach-Object { "• $($_.Title): $($_.Problem)" }) -join "`r`n"
        $r = [System.Windows.Forms.MessageBox]::Show(
            "У включённых модов есть ошибки (красные строки):`r`n$list`r`n`r`nСохранить всё равно?",
            'Kenshi Mod Manager', 'YesNo', 'Warning')
        return ($r -eq 'Yes')
    }
    return $true
}

function Open-Steam {
    $m = Get-SelectedMod
    if ($m -and $m.Id) { Start-Process "steam://url/CommunityFilePage/$($m.Id)" }
    elseif ($m -and -not $m.Special) { [System.Windows.Forms.MessageBox]::Show('Это локальный мод, у него нет страницы в Workshop.', 'Kenshi Mod Manager') | Out-Null }
}
function Open-Folder {
    $m = Get-SelectedMod
    if ($m -and $m.Dir -and (Test-Path -LiteralPath $m.Dir)) { Start-Process explorer.exe $m.Dir }
}

function Load-Thumbnails {
    $todo = @($script:Mods | Where-Object { $_.Preview -and $_.ImageKey -eq '_none' })
    $i = 0
    foreach ($m in $todo) {
        $i++
        $key = $m.Key + '|' + $m.Id
        if (-not $images.Images.ContainsKey($key)) {
            $t = Get-Thumb $m
            if ($t) { $images.Images.Add($key, $t) }
        }
        if ($images.Images.ContainsKey($key)) { $m.ImageKey = $key }
        if ($i % 10 -eq 0) {
            $lblCount.Text = "Загружаю картинки: $i из $($todo.Count)…"
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# --- события
$script:LastClicks = 0
$script:PendingFile = $null
$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 1
$refreshTimer.Add_Tick({
    $refreshTimer.Stop()
    Refresh-List $script:PendingFile
})

$txtSearch.Add_TextChanged({ Refresh-List })
$cmbFilter.Add_SelectedIndexChanged({ Refresh-List })
$cmbStatus.Add_SelectedIndexChanged({ Refresh-List })
$lv.Add_SelectedIndexChanged({ if (-not $script:Filling) { Show-Details } })
$lv.Add_ColumnClick({
    param($s, $e)
    if ($e.Column -eq $script:SortCol -and $e.Column -ne 0) { $script:SortDesc = -not $script:SortDesc }
    else { $script:SortCol = $e.Column; $script:SortDesc = ($e.Column -eq 4) }   # дата — сначала новые
    Refresh-List
})
$lv.Add_MouseDown({ param($s, $e) $script:LastClicks = $e.Clicks })
$lv.Add_ItemCheck({
    param($s, $e)
    if ($lv.Items[$e.Index].Tag.Special) { $e.NewValue = $e.CurrentValue; return }
    if (-not $script:Filling -and $script:LastClicks -gt 1) {   # двойной щелчок не переключает галочку
        $e.NewValue = $e.CurrentValue
        $script:LastClicks = 0
    }
})
$lv.Add_ItemChecked({
    param($s, $e)
    if ($script:Filling) { return }
    $m = $e.Item.Tag
    if ($m.Special) { return }
    $before = (Get-OrderIndex $m.File) -ge 0
    if ($before -eq $e.Item.Checked) { return }
    Set-Enabled $m $e.Item.Checked
    $script:PendingFile = $m.File
    $refreshTimer.Start()
})
$lv.Add_DoubleClick({ $script:LastClicks = 0; Open-Steam })

# --- перетаскивание мышью
$lv.AllowDrop = $true
$script:DragFile = $null
$lv.Add_ItemDrag({
    param($s, $e)
    if ($script:SortCol -ne 0) {
        [System.Windows.Forms.MessageBox]::Show('Перетаскивать можно, когда список отсортирован по «№» (щёлкните по заголовку «№»).', 'Kenshi Mod Manager') | Out-Null
        return
    }
    $m = $e.Item.Tag
    if ($m.Special -or (Get-OrderIndex $m.File) -lt 0) { return }
    $script:DragFile = $m.File
    [void]$lv.DoDragDrop($e.Item, [System.Windows.Forms.DragDropEffects]::Move)
    $script:DragFile = $null
})
$lv.Add_DragOver({
    param($s, $e)
    if (-not $script:DragFile) { $e.Effect = 'None'; return }
    $e.Effect = 'Move'
    $pt = $lv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    if ($lv.Items.Count -gt 0 -and $lv.TopItem) {
        if ($pt.Y -lt 50 -and $lv.TopItem.Index -gt 0) { $lv.Items[$lv.TopItem.Index - 1].EnsureVisible() }
        elseif ($pt.Y -gt $lv.ClientSize.Height - 30) {
            $last = $lv.GetItemAt(5, $lv.ClientSize.Height - 5)
            if ($last -and $last.Index -lt $lv.Items.Count - 1) { $lv.Items[$last.Index + 1].EnsureVisible() }
        }
    }
})
$lv.Add_DragDrop({
    param($s, $e)
    $file = $script:DragFile
    if (-not $file) { return }
    $pt = $lv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $it = $lv.GetItemAt(5, $pt.Y)
    $target = $script:Order.Count - 1
    if ($it) {
        if ($it.Tag.Special) { $target = 0 }
        else { $ti = Get-OrderIndex $it.Tag.File; if ($ti -ge 0) { $target = $ti } }
    }
    Move-File $file $target
})
$btnAuto.Add_Click({ Run-AutoOrder })
$btnRules.Add_Click({
    [void](Get-Rules)    # создаст файл с правилами по умолчанию, если его нет
    Start-Process notepad.exe $RulesPath
})
$btnUp.Add_Click({ Move-Selected 'up' })
$btnDown.Add_Click({ Move-Selected 'down' })
$btnTop.Add_Click({ Move-Selected 'top' })
$btnBottom.Add_Click({ Move-Selected 'bottom' })
$btnMoveTo.Add_Click({
    $m = Get-SelectedMod; if (-not $m -or $m.Special) { return }
    $idx = Get-OrderIndex $m.File
    if ($idx -lt 0) { Move-Selected 'up'; return }
    $n = Ask-Number "Новая позиция для «$($m.Title)» (1–$($script:Order.Count)):" ($idx + 1)
    if ($n -gt 0) { Move-Selected 'to' ($n - 1) }
})
$btnOk.Add_Click({ Set-ModStatus 'ok' })
$btnBad.Add_Click({ Set-ModStatus 'bad' })
$btnNone.Add_Click({ Set-ModStatus '' })
$miOk.Add_Click({ Set-ModStatus 'ok' })
$miBad.Add_Click({ Set-ModStatus 'bad' })
$miNone.Add_Click({ Set-ModStatus '' })
$miSteam.Add_Click({ Open-Steam })
$miFolder.Add_Click({ Open-Folder })
$btnSteam.Add_Click({ Open-Steam })
$btnFolder.Add_Click({ Open-Folder })
$btnReload.Add_Click({
    if ($script:Dirty) {
        $r = [System.Windows.Forms.MessageBox]::Show('Отменить все несохранённые изменения порядка и включения модов?', 'Kenshi Mod Manager', 'YesNo')
        if ($r -ne 'Yes') { return }
    }
    Load-All; $script:RK = Get-REKenshi; Update-Bundled; Load-Thumbnails; Refresh-List
})
$btnSave.Add_Click({
    if (-not (Confirm-KenshiClosed)) { return }
    if (-not (Confirm-Problems)) { return }
    try { Save-Cfg; Refresh-List
          [System.Windows.Forms.MessageBox]::Show("Сохранено. Включено модов: $($script:Order.Count).`r`nБэкап прежнего списка лежит рядом с mods.cfg.", 'Kenshi Mod Manager') | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show("Не удалось сохранить: $($_.Exception.Message)", 'Kenshi Mod Manager', 'OK', 'Error') | Out-Null }
})
$btnPlay.Add_Click({
    if (-not (Confirm-KenshiClosed)) { return }
    if (-not (Confirm-Problems)) { return }
    try { Save-Cfg } catch {
        [System.Windows.Forms.MessageBox]::Show("Не удалось сохранить: $($_.Exception.Message)", 'Kenshi Mod Manager', 'OK', 'Error') | Out-Null; return }
    Start-Process 'steam://rungameid/233860'
    $form.Close()
})
$form.Add_KeyDown({
    param($s, $e)
    if ($e.Alt -and $e.KeyCode -eq 'Up')   { Move-Selected 'up';   $e.Handled = $true }
    if ($e.Alt -and $e.KeyCode -eq 'Down') { Move-Selected 'down'; $e.Handled = $true }
    if ($e.Control -and $e.KeyCode -eq 'F') { $txtSearch.Focus(); $txtSearch.SelectAll(); $e.Handled = $true }
    if ($e.Control -and $e.KeyCode -eq 'S') { $btnSave.PerformClick(); $e.Handled = $true }
    if ($e.Control -and ($e.KeyCode -eq 'D1' -or $e.KeyCode -eq 'NumPad1')) { Set-ModStatus 'ok';  $e.Handled = $true }
    if ($e.Control -and ($e.KeyCode -eq 'D2' -or $e.KeyCode -eq 'NumPad2')) { Set-ModStatus 'bad'; $e.Handled = $true }
    if ($e.Control -and ($e.KeyCode -eq 'D0' -or $e.KeyCode -eq 'NumPad0')) { Set-ModStatus '';    $e.Handled = $true }
})
$form.Add_Shown({
    if (-not $script:BundleSrc) {
        $lblCount.Text = 'Разбираю состав Genesis (первый раз — несколько секунд)…'
        [System.Windows.Forms.Application]::DoEvents()
        Update-Bundled
    }
    Load-Thumbnails
    Refresh-List
})
$form.Add_FormClosing({
    param($s, $e)
    if ($script:Dirty) {
        $r = [System.Windows.Forms.MessageBox]::Show('Есть несохранённые изменения. Сохранить перед выходом?', 'Kenshi Mod Manager', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { $e.Cancel = $true; return }
        if ($r -eq 'Yes') {
            if (-not (Confirm-KenshiClosed)) { $e.Cancel = $true; return }
            try { Save-Cfg } catch { $e.Cancel = $true; [System.Windows.Forms.MessageBox]::Show("Не удалось сохранить: $($_.Exception.Message)") | Out-Null }
        }
    }
})

# --- запуск
try {
    if (-not (Test-Path -LiteralPath (Join-Path $KenshiDir 'kenshi_x64.exe'))) {
        throw "Скрипт должен лежать в папке игры (рядом с kenshi_x64.exe). Сейчас: $KenshiDir"
    }
    Load-All
    Load-Status
    $script:RK = Get-REKenshi
    Refresh-List
    [void]$form.ShowDialog()
} catch {
    [System.Windows.Forms.MessageBox]::Show("Ошибка: $($_.Exception.Message)", 'Kenshi Mod Manager', 'OK', 'Error') | Out-Null
}
