# Pokémon Legends: Z-A (PokeZ-ARecomp) installer for Windows (driven by NUP Studio)
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Pokemon Legends Z-A",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
function Say($msg) { Write-Host "[PokeZ-A] $msg" -ForegroundColor Cyan }

if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) {
    Say "error: missing .nup file: $Nup"
    exit 1
}
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Pokemon Legends Z-A"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
$msysRoot = "C:\msys64"
$clang64Prefix = Join-Path $msysRoot "clang64"
$clang64Bin = Join-Path $clang64Prefix "bin"
$msysUsrBin = Join-Path $msysRoot "usr\bin"
$makeExe = Join-Path $msysUsrBin "make.exe"
$bashExe = Join-Path $msysUsrBin "bash.exe"

if (-not (Test-Path -LiteralPath $makeExe) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang++.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "python.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\SDL3\SDL.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vma\vk_mem_alloc.h"))) {
    if (-not (Test-Path -LiteralPath $globalMsysInstaller)) {
        Say "error: MSYS2 missing and global installer not found: $globalMsysInstaller"
        exit 1
    }
    & $globalMsysInstaller -Msys $msysRoot
    if ($LASTEXITCODE -ne 0) {
        Say "MSYS2 installation cancelled or failed; stopping recompilation."
        exit 1
    }
}

$pyExe = Join-Path $clang64Bin "python.exe"
$lasgenExe = Join-Path $source "bin\lasgen\lasgen.exe"
foreach ($req in @($pyExe, $makeExe, $lasgenExe, (Join-Path $clang64Bin "clang.exe"))) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;$msysUsrBin;" + $env:PATH
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHON_JIT = "0"

# Pin to E-cores on Intel 13th/14th-gen to avoid P-core boost instability during heavy codegen
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 16))
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    if ($cpuName -match 'Intel.*1[34]\d{3}' -and [Environment]::ProcessorCount -gt 16) {
        $eCoreMask = [int64]0
        for ($c = 16; $c -lt [Math]::Min(63, [Environment]::ProcessorCount); $c++) {
            $eCoreMask = $eCoreMask -bor ([int64]1 -shl $c)
        }
        if ($eCoreMask -gt 0) {
            Say "detected ${cpuName}: pinning codegen & build to E-cores for stability"
            $proc.ProcessorAffinity = [IntPtr]$eCoreMask
            $jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount - 16, 12))
        }
    }
} catch {}

# ---- Global Saves folder (<ParentDir>\Saves\<GameFolderName>) ----
$parentInstallDir = Split-Path -Parent $Dir
$globalSavesRoot = Join-Path $parentInstallDir "Saves"
$globalSaveDir = Join-Path $globalSavesRoot (Split-Path -Leaf $Dir)
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null

$legacySaveDir = Join-Path $Dir "save"
if ((Test-Path -LiteralPath $legacySaveDir) -and -not (Get-ChildItem -LiteralPath $globalSaveDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Say "migrating existing saves into global folder: $globalSaveDir"
    Copy-Item -Path (Join-Path $legacySaveDir "*") -Destination $globalSaveDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 1. Extract ExeFS & RomFS from .nup ----
$extractedDir = Join-Path $Dir "extracted"
$exefsDir = Join-Path $extractedDir "exefs"
$romfsDir = Join-Path $extractedDir "romfs"
if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath $romfsDir)) {
    Say "extracting ExeFS and RomFS from .nup..."
    & $pyExe (Join-Path $source "tools\extract_nup.py") $Nup --select latest --out $extractedDir
    if ($LASTEXITCODE -ne 0) { Say "extract_nup.py failed"; exit 1 }
}

# ---- 2. Lift ARM64 ExeFS (sdk, main) to C using standalone lasgen.exe ----
# GNU Make cannot handle spaces or accents in GEN/B paths: keep workRoot ASCII & space-free.
$workRoot = Join-Path $parentInstallDir "_pokeza_work"
if ($workRoot -match '[\s\x80-\xFF]') {
    $workRoot = Join-Path $env:TEMP "pokeza_work"
}
$genDir = Join-Path $workRoot "generated"
New-Item -ItemType Directory -Force -Path $genDir | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $genDir "sdk\main_build_id.txt")) -and -not (Test-Path -LiteralPath (Join-Path $genDir "sdk\sdk_0000.c"))) {
    $sdkFiles = Get-ChildItem -LiteralPath (Join-Path $genDir "sdk") -Filter "*.c" -ErrorAction SilentlyContinue
    if (-not $sdkFiles) {
        Say "lifting sdk to C..."
        & $lasgenExe sdk (Join-Path $exefsDir "sdk") 0x7008000000 (Join-Path $genDir "sdk") --hle (Join-Path $source "runtime\hle\hle_symbols.txt") --simd c
        if ($LASTEXITCODE -ne 0) { Say "lasgen sdk failed"; exit 1 }
    }
}
$mainFiles = Get-ChildItem -LiteralPath (Join-Path $genDir "main") -Filter "*.c" -ErrorAction SilentlyContinue
if (-not $mainFiles) {
    Say "lifting main to C..."
    & $lasgenExe main (Join-Path $exefsDir "main") 0x7000000000 (Join-Path $genDir "main") --simd c
    if ($LASTEXITCODE -ne 0) { Say "lasgen main failed"; exit 1 }
}

# ---- 3. Compile lasrecomp.exe + lasgame.dll via MSYS2 Make + Clang64 ----
$buildDir = Join-Path $workRoot "build"
$lasrecompExe = Join-Path $Dir "lasrecomp.exe"
$lasgameDll = Join-Path $Dir "lasgame.dll"
if (-not (Test-Path -LiteralPath $lasrecompExe) -or -not (Test-Path -LiteralPath $lasgameDll)) {
    Say "compiling lasrecomp.exe and lasgame.dll with Clang64 + Make..."
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    $genFwd = $genDir -replace "\\", "/"
    $buildFwd = $buildDir -replace "\\", "/"
    $srcFwd = $source -replace "\\", "/"
    $makeCmd = "cd '$srcFwd' && rm -f '$buildFwd/obj/tools/gamelib_entry.o' '$buildFwd/rt/gamelib.o' '$buildFwd/rt/gamebuild.o' && make -j$jobs GEN='$genFwd' B='$buildFwd' GENARCH=-march=x86-64-v3 GENOPT=-O0 RELEASE=1"
    & $bashExe -lc $makeCmd
    if ($LASTEXITCODE -ne 0) { Say "make build failed"; exit 1 }

    Copy-Item -LiteralPath (Join-Path $buildDir "lasrecomp.exe") -Destination $lasrecompExe -Force
    Copy-Item -LiteralPath (Join-Path $buildDir "lasgame.dll") -Destination $lasgameDll -Force

    # Copy required MSYS2 Clang64 runtime DLLs next to lasrecomp.exe (zero MSYS2 dependency at runtime)
    $exeFwd = $lasrecompExe -replace "\\", "/"
    $dllList = & $bashExe -lc "PATH='/clang64/bin:/usr/bin' ldd '$exeFwd' | awk '/\/clang64\// && !/vulkan-1/ {print `$3}'"
    foreach ($dllPosix in $dllList) {
        $dllPosix = $dllPosix.Trim()
        if ($dllPosix) {
            $dllWin = & $bashExe -lc "cygpath -w '$dllPosix'"
            if ($dllWin -and (Test-Path -LiteralPath $dllWin.Trim())) {
                Copy-Item -LiteralPath $dllWin.Trim() -Destination $Dir -Force
            }
        }
    }
}

# Copy fonts and icon.png next to lasrecomp.exe
$fontsDst = Join-Path $Dir "fonts"
if ((Test-Path -LiteralPath (Join-Path $source "fonts")) -and -not (Test-Path -LiteralPath $fontsDst)) {
    Copy-Item -LiteralPath (Join-Path $source "fonts") -Destination $fontsDst -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $source "game_icon.png")) {
    Copy-Item -LiteralPath (Join-Path $source "game_icon.png") -Destination (Join-Path $Dir "icon.png") -Force
}

# ---- 4. Pre-launch UI, config, shortcuts & Windows uninstaller ----
$repoRoot = Resolve-Path (Join-Path $source "..\..\..")
$launcherUiSrc = $LauncherUiPath
if (-not $launcherUiSrc -or -not (Test-Path -LiteralPath $launcherUiSrc)) {
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}
$isLauncherExe = $launcherUiSrc -match "\.exe$"
$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$launchConfigPath = Join-Path $Dir "launch_options.json"
$tplPath = Join-Path $source "launch_options_template.json"
if (Test-Path -LiteralPath $tplPath) {
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl | Add-Member -NotePropertyName "working_dir" -NotePropertyValue $Dir -Force
    $tpl | Add-Member -NotePropertyName "command" -NotePropertyValue @($lasrecompExe, "--play") -Force
    if (-not $tpl.env) {
        $tpl | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $tpl.env | Add-Member -NotePropertyName "LARECOMP_SAVE_DIR" -NotePropertyValue $globalSaveDir -Force
    $tpl.env | Add-Member -NotePropertyName "LARECOMP_WINDOW" -NotePropertyValue "1280x720" -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($launchConfigPath, ($tpl | ConvertTo-Json -Depth 10), $utf8NoBom)
}

$iconSrc = $IconPath
if (-not $iconSrc -or -not (Test-Path -LiteralPath $iconSrc)) {
    $iconSrc = Join-Path $source "game_icon.ico"
}
$iconDst = Join-Path $Dir "game_icon.ico"
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
}
$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$runner = Join-Path $Dir "za.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} else {
@"
@echo off
cd /d "$Dir"
set "LARECOMP_SAVE_DIR=$globalSaveDir"
set "LARECOMP_WINDOW=1280x720"
"$lasrecompExe" --play %*
"@ | Set-Content -Encoding ASCII $runner
}

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Pokemon Legends Z-A" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 5. Clean up temporary build files ----
Say "cleaning up temporary build files in $Dir..."
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# ---- 6. Register in Windows Installed Apps + create uninstaller (never deletes ROM or saves) ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous désinstaller $safeShortcutName ?`n`nLe dossier d'installation et les raccourcis seront supprimés.`nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprimés.",
    "Désinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
if (Test-Path -LiteralPath "$desktopLnk") { Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$startMenuDir") { Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$uninstRegPath") {
    Remove-Item -LiteralPath "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Location `$env:TEMP
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 /nobreak >nul & rmdir /s /q ``"$Dir``"" -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

$sizeKb = [int](((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
New-Item -Path $uninstRegPath -Force | Out-Null
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp (NUP Studio)"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value "$iconDst,0" }
$uninstCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $sizeKb -Type DWord

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed 720p by default, F11 for fullscreen)."
