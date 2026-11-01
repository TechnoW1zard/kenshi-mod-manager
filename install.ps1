# Kenshi Mod Manager — установщик.
# Находит папку Kenshi в Steam, копирует туда менеджер и создаёт ярлык на рабочем столе.
param([string]$Target)

Add-Type -AssemblyName System.Windows.Forms
$Title = 'Kenshi Mod Manager — установка'
$Src = $PSScriptRoot
$Files = @('KenshiModManager.ps1', 'Kenshi Mod Manager.bat')

function Say($text, $icon = 'Information', $buttons = 'OK') {
    return [System.Windows.Forms.MessageBox]::Show($text, $Title, $buttons, $icon)
}

function Test-Kenshi([string]$dir) {
    return ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'kenshi_x64.exe')))
}

function Find-Kenshi {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $roots.Add(($v -replace '/', '\')) } }
        } catch { }
    }
    $roots.Add("${env:ProgramFiles(x86)}\Steam"); $roots.Add("$env:ProgramFiles\Steam")

    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($r in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $libs.Add($r)
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = [System.IO.File]::ReadAllText($vdf)
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) { $libs.Add(($m.Groups[1].Value -replace '\\\\', '\')) }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $d = Join-Path $l 'steamapps\common\Kenshi'
        if (Test-Kenshi $d) { return (Resolve-Path -LiteralPath $d).Path }
    }
    return $null
}

function Ask-Folder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Не нашёл Kenshi сам. Укажите папку игры (ту, где лежит kenshi_x64.exe).'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

try {
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $Src $f))) {
            throw "Рядом с установщиком нет файла «$f». Распакуйте архив целиком и запустите установщик из распакованной папки."
        }
    }

    $dir = $Target
    if (-not (Test-Kenshi $dir)) { $dir = Find-Kenshi }
    if (-not $dir) {
        $dir = Ask-Folder
        if (-not $dir) { exit 1 }
        if (-not (Test-Kenshi $dir)) { throw "В папке «$dir» нет kenshi_x64.exe — это не папка Kenshi." }
    }

    try {
        foreach ($f in $Files) { Copy-Item -LiteralPath (Join-Path $Src $f) -Destination (Join-Path $dir $f) -Force -ErrorAction Stop }
    } catch [System.UnauthorizedAccessException] {
        # нет прав на запись (игра в Program Files) — перезапуск с правами администратора
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Target `"$dir`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
        exit 0
    }
    foreach ($f in $Files) { try { Unblock-File -LiteralPath (Join-Path $dir $f) } catch { } }

    $bat = Join-Path $dir 'Kenshi Mod Manager.bat'
    $lnkMade = $false
    try {
        $desk = [Environment]::GetFolderPath('Desktop')
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut((Join-Path $desk 'Kenshi Mod Manager.lnk'))
        $lnk.TargetPath = $bat
        $lnk.WorkingDirectory = $dir
        $lnk.IconLocation = (Join-Path $dir 'kenshi_x64.exe') + ',0'
        $lnk.WindowStyle = 7
        $lnk.Description = 'Менеджер модов Kenshi'
        $lnk.Save()
        $lnkMade = $true
    } catch { }

    $msg = "Готово! Менеджер установлен в папку игры:`n$dir"
    if ($lnkMade) { $msg += "`n`nНа рабочем столе появился ярлык «Kenshi Mod Manager»." }
    $msg += "`n`nЗапустить его сейчас?"
    if ((Say $msg 'Information' 'YesNo') -eq 'Yes') { Start-Process -FilePath $bat -WorkingDirectory $dir -WindowStyle Minimized }
} catch {
    Say ("Установка не удалась:`n" + $_.Exception.Message) 'Error' | Out-Null
    exit 1
}
