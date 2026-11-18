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
    $makeCmd = "export PATH='/clang64/bin:/usr/bin' && cd '$srcFwd' && rm -f '$buildFwd/obj/tools/gamelib_entry.o' '$buildFwd/rt/gamelib.o' '$buildFwd/rt/gamebuild.o' && make -j$jobs GEN='$genFwd' B='$buildFwd' GENARCH=-march=x86-64-v3 GENOPT=-O0 RELEASE=1"
    & $bashExe -lc $makeCmd
    if ($LASTEXITCODE -ne 0) { Say "make build failed"; exit 1 }

    Copy-Item -LiteralPath (Join-Path $buildDir "lasrecomp.exe") -Destination $lasrecompExe -Force
    Copy-Item -LiteralPath (Join-Path $buildDir "lasgame.dll") -Destination $lasgameDll -Force
    $lasgameIdSrc = Join-Path $buildDir "lasgame.dll.id"
    if (Test-Path -LiteralPath $lasgameIdSrc) {
        Copy-Item -LiteralPath $lasgameIdSrc -Destination "$lasgameDll.id" -Force
    }

    # Copy required MSYS2 Clang64 runtime DLLs next to lasrecomp.exe (zero MSYS2 dependency at runtime)
    # Static PE import-table BFS (both normal & delay imports) avoids ldd misses on deep transitive DLLs like libffi-8.dll.
    $dllCopyPy = Join-Path $workRoot "copy_clang64_dlls.py"
    $pyCode = @'
import os, shutil, struct, sys

def pe_imports(path):
    with open(path, 'rb') as f:
        data = f.read(4096)
        if data[:2] != b'MZ': return []
        pe_off = struct.unpack_from('<I', data, 0x3c)[0]
        f.seek(pe_off)
        hdr = f.read(256)
        if hdr[:4] != b'PE\0\0': return []
        n_sec, = struct.unpack_from('<H', hdr, 6)
        opt_sz, = struct.unpack_from('<H', hdr, 20)
        opt_off = pe_off + 24
        f.seek(opt_off)
        opt = f.read(opt_sz)
        magic, = struct.unpack_from('<H', opt, 0)
        dd_off = 112 if magic == 0x20b else 96
        n_dd, = struct.unpack_from('<I', opt, dd_off - 4)
        f.seek(opt_off + opt_sz)
        secs = []
        for _ in range(n_sec):
            s = f.read(40)
            vsz, va, rsz, rptr = struct.unpack_from('<4I', s, 8)
            secs.append((va, max(vsz, rsz), rptr))
        def r2o(rva):
            for va, sz, rp in secs:
                if va <= rva < va + sz:
                    return rp + (rva - va)
            return None
        def read_cstr(off):
            if off is None: return ''
            f.seek(off)
            buf = f.read(260)
            end = buf.find(b'\0')
            return (buf[:end] if end != -1 else buf).decode('ascii', 'ignore')
        out = []
        if n_dd > 1:
            imp_rva, _ = struct.unpack_from('<2I', opt, dd_off + 8)
            if imp_rva:
                off = r2o(imp_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(20)
                    if len(desc) < 20 or desc == b'\0' * 20: break
                    name_rva, = struct.unpack_from('<I', desc, 12)
                    if not name_rva: break
                    n = read_cstr(r2o(name_rva))
                    if n: out.append(n)
                    off += 20
        if n_dd > 13:
            dly_rva, _ = struct.unpack_from('<2I', opt, dd_off + 13 * 8)
            if dly_rva:
                off = r2o(dly_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(32)
                    if len(desc) < 32 or desc == b'\0' * 32: break
                    attrs, name_rva = struct.unpack_from('<2I', desc, 0)
                    if not name_rva: break
                    if attrs & 1:
                        n = read_cstr(r2o(name_rva))
                        if n: out.append(n)
                    off += 32
        return out

clang_bin, dst_dir, *roots = sys.argv[1:]
avail = {n.lower(): os.path.join(clang_bin, n) for n in os.listdir(clang_bin) if n.lower().endswith('.dll') and n.lower() != 'vulkan-1.dll'}
seen, queue = set(), list(roots)
while queue:
    cur = queue.pop(0)
    if not os.path.isfile(cur): continue
    for imp in pe_imports(cur):
        key = imp.lower()
        if key in avail and key not in seen:
            seen.add(key)
            src = avail[key]
            shutil.copy2(src, os.path.join(dst_dir, os.path.basename(src)))
            queue.append(src)
'@
    [System.IO.File]::WriteAllText($dllCopyPy, $pyCode, (New-Object System.Text.UTF8Encoding($false)))
    & $pyExe $dllCopyPy $clang64Bin $Dir $lasrecompExe $lasgameDll
    if ($LASTEXITCODE -ne 0) { Say "failed to copy runtime DLLs"; exit 1 }
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
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0game_launcher.exe" --config "%~dp0launch_options.json" %*
"@
} else {
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "LARECOMP_SAVE_DIR=$globalSaveDir"
set "LARECOMP_WINDOW=1280x720"
"%~dp0lasrecomp.exe" --play %*
"@
}
[System.IO.File]::WriteAllText($runner, $cmdText, $utf8NoBom)

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
