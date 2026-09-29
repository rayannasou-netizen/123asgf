# ============================================================
#  ArabTweaks - اداة تحسين ويندوز بالعربي (على طريقة Chris Titus)
#  تشغيل: كليك يمين > Run with PowerShell  او  شغّل ملف Run.bat
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# ---------- تشغيل كمسؤول ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- حفظ الحالة ----------
$StateDir  = Join-Path $env:ProgramData 'ArabTweaks'
$StateFile = Join-Path $StateDir 'state.json'
$script:State = @{ applied = @(); services = @{} }
$script:RPDone = $false

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $j = Get-Content $StateFile -Raw | ConvertFrom-Json
            $script:State.applied = @($j.applied)
            $script:State.services = @{}
            if ($j.services) {
                foreach ($p in $j.services.PSObject.Properties) {
                    $h = @{}
                    if ($p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value } }
                    $script:State.services[$p.Name] = $h
                }
            }
        } catch {}
    }
}
function Save-State {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    ($script:State | ConvertTo-Json -Depth 5) | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------- ادوات مساعدة ----------
function Log($m) { $script:LogBox.AppendText("$m`r`n"); [System.Windows.Forms.Application]::DoEvents() }
function Get-RegVal($P, $N) { try { (Get-ItemProperty -LiteralPath $P -Name $N -ErrorAction Stop).$N } catch { $null } }
function Set-RegVal($P, $N, $V, $T = 'DWord') {
    if (-not (Test-Path -LiteralPath $P)) { New-Item -Path $P -Force | Out-Null }
    New-ItemProperty -LiteralPath $P -Name $N -Value $V -PropertyType $T -Force | Out-Null
}
function Del-RegVal($P, $N) { Remove-ItemProperty -LiteralPath $P -Name $N -ErrorAction SilentlyContinue }
function Test-Same($a, $b) {
    if (($a -is [array]) -or ($b -is [array])) { return ((@($a) -join ',') -eq (@($b) -join ',')) }
    return ("$a" -eq "$b")
}
function R($p, $n, $on, $off, $t = 'DWord') { @{ P = $p; N = $n; On = $on; Off = $off; T = $t } }

function Svc-Backup($key, $names) {
    if (-not $script:State.services.ContainsKey($key)) {
        $o = @{}
        foreach ($n in $names) {
            $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
            if ($s) { $o[$n] = $s.StartMode }
        }
        $script:State.services[$key] = $o
    }
}
function Svc-Restore($key) {
    $o = $script:State.services[$key]
    if ($o) {
        foreach ($n in @($o.Keys)) {
            $type = switch ($o[$n]) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Manual' } }
            Set-Service -Name $n -StartupType $type -ErrorAction SilentlyContinue
        }
        $script:State.services.Remove($key)
    }
}
function Svc-Set($names, $type, $stop = $false) {
    foreach ($n in $names) {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) {
            if ($stop) { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $n -StartupType $type -ErrorAction SilentlyContinue
        }
    }
}

# ---------- بيانات ثابتة ----------
$TelemetryTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
)
$ManualServices = @('ALG','AJRouter','MapsBroker','lfsvc','RemoteRegistry','RetailDemo','Fax','PhoneSvc',
    'WMPNetworkSvc','WpcMonSvc','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','SEMgrSvc',
    'icssvc','SharedRealitySvc','TrkWks','SCardSvr','ScDeviceEnum')
$AdobeServices = @('AdobeARMservice','AGSService','AGMService','AdobeUpdateService')
$AdobeHosts = @('activate.adobe.com','practivate.adobe.com','ereg.adobe.com','wip3.adobe.com','activate-sea.adobe.com',
    'activate-sjc0.adobe.com','3dns-2.adobe.com','3dns-3.adobe.com','adobe-dns.adobe.com','adobe-dns-2.adobe.com',
    'adobe-dns-3.adobe.com','lm.licenses.adobe.com','na2m-pr.licenses.adobe.com','lmlicenses.wip4.adobe.com','hl2rcv.adobe.com')
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$WTSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
$Tcpip6 = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$ExpAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$SysProf = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

# ============================================================
#  تعريف التويكات
#  Group: perf = اداء الالعاب | ess = اساسية | adv = متقدمة | pref = شكلية
#  On/Off: القيمة عند التشغيل / الاطفاء ($null = حذف القيمة)
# ============================================================
$script:Tweaks = New-Object System.Collections.ArrayList
function Add-Tweak([hashtable]$t) { [void]$script:Tweaks.Add([pscustomobject]$t) }

# ---------------- اداء الالعاب والنظام ----------------
Add-Tweak @{ Id='gamemode'; Group='perf'; Name='وضع اللعب (Game Mode)'
    Desc='يعطي اللعبة اولوية ويمنع ويندوز يشغّل مهام وتحديثات بالخلفية وقت اللعب.'
    Reg=@( (R 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 0), (R 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 0) ) }

Add-Tweak @{ Id='windowed'; Group='perf'; Name='تحسين الالعاب بوضع النافذة (Optimizations for windowed games)'
    Desc='يحسّن اداء الالعاب اللي تشتغل Windowed او Borderless ويقلل التأخير (Latency).'
    Reg=@( (R 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;' 'SwapEffectUpgradeEnable=0;' 'String') ) }

Add-Tweak @{ Id='hags'; Group='perf'; Name='جدولة الـ GPU بالهاردوير (Hardware-accelerated GPU scheduling)'
    Desc='يخلي كرت الشاشة يدير ذاكرته بنفسه، يقلل الحمل على المعالج. يحتاج كرت ودرايفر حديث + ريستارت.'
    Restart='reboot'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 1) ) }

Add-Tweak @{ Id='memint'; Group='perf'; Name='ايقاف عزل النواة - سلامة الذاكرة (Core Isolation > Memory Integrity)'
    Desc='ايقافها يرفع الاداء بالالعاب شوي. الاطفاء هنا = ترجع سلامة الذاكرة تشتغل.'
    Warn='تحذير: يقلل حماية النظام من البرامج الخبيثة. ريستارت مطلوب.'; Restart='reboot'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0 1) ) }

Add-Tweak @{ Id='powerplan'; Group='perf'; Name='خطة طاقة: اداء عالي (High Performance)'
    Desc='يمنع المعالج من تقليل السرعة لتوفير الطاقة. الاطفاء = يرجع لخطة Balanced. (على اللابتوب يستهلك بطارية اكثر)'
    Apply={ $g='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; if (-not ((powercfg /list) -match $g)) { powercfg -duplicatescheme $g $g | Out-Null }; powercfg -setactive $g | Out-Null }
    Undo={ powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null }
    Test={ [bool]((powercfg /getactivescheme) -match '8c5e7fda') } }

Add-Tweak @{ Id='gamesprio'; Group='perf'; Name='اولوية المعالج والكرت للالعاب (Tasks\Games)'
    Desc='يضبط Scheduling Category = High مع GPU Priority 8 و Priority 6 عشان اللعبة تاخذ اولوية اعلى بالمعالج والكرت.'
    Reg=@( (R "$SysProf\Tasks\Games" 'Scheduling Category' 'High' 'Medium' 'String'),
           (R "$SysProf\Tasks\Games" 'SFIO Priority' 'High' 'Normal' 'String'),
           (R "$SysProf\Tasks\Games" 'GPU Priority' 8 8),
           (R "$SysProf\Tasks\Games" 'Priority' 6 2) ) }

Add-Tweak @{ Id='win32prio'; Group='perf'; Name='Win32PrioritySeparation = 26 (Hex)'
    Desc='يعطي البرنامج اللي قدامك (الفورقراوند) اولوية اعلى بالمعالج، احساس اسرع وثبات اكثر بالالعاب.'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 0x26 2) ) }

Add-Tweak @{ Id='nettthrottle'; Group='perf'; Name='NetworkThrottlingIndex و SystemResponsiveness'
    Desc='يلغي تحديد سرعة الشبكة (ffffffff) ويخلي SystemResponsiveness = 10 لتخصيص موارد اكثر للالعاب.'
    Reg=@( (R $SysProf 'NetworkThrottlingIndex' -1 10), (R $SysProf 'SystemResponsiveness' 10 20) ) }

# ---------------- التعديلات الاساسية ----------------
Add-Tweak @{ Id='tempfiles'; Group='ess'; Name='حذف الملفات المؤقتة'; Action=$true
    Desc='يمسح محتوى مجلدات Temp لتوفير مساحة. (عملية تنفيذ مرة وحدة وما تنعكس)'
    Apply={ foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp")) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } } }

Add-Tweak @{ Id='consumer'; Group='ess'; Name='ايقاف ConsumerFeatures'
    Desc='يمنع ويندوز يثبّت تطبيقات ودعايات تلقائيا (مثل Candy Crush وغيره).'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 $null) ) }

Add-Tweak @{ Id='telemetry'; Group='ess'; Name='ايقاف التلمتري (Telemetry)'
    Desc='يوقف ارسال بيانات الاستخدام لمايكروسوفت ويعطّل خدمة DiagTrack ومهام التجميع.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 $null),
           (R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 $null) )
    Apply={ Svc-Set @('DiagTrack','dmwappushservice') 'Disabled' $true; foreach ($tk in $TelemetryTasks) { schtasks /Change /TN $tk /DISABLE 2>$null | Out-Null } }
    Undo={ Svc-Set @('DiagTrack') 'Automatic'; Svc-Set @('dmwappushservice') 'Manual'; foreach ($tk in $TelemetryTasks) { schtasks /Change /TN $tk /ENABLE 2>$null | Out-Null } } }

Add-Tweak @{ Id='activity'; Group='ess'; Name='ايقاف سجل النشاط (Activity History)'
    Desc='يمنع ويندوز يسجّل نشاطك ويرفعه لحسابك.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 $null) ) }

Add-Tweak @{ Id='folderdisc'; Group='ess'; Name='ايقاف اكتشاف نوع المجلد التلقائي (Explorer Folder Discovery)'
    Desc='يمنع الاكسبلورر يبطّئ فتح المجلدات بمحاولة تخمين نوعها (صور/فيديو...).'; Restart='explorer'
    Apply={ $b='HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
            Remove-Item -LiteralPath "$b\Bags" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$b\BagMRU" -Recurse -Force -ErrorAction SilentlyContinue
            Set-RegVal "$b\Bags\AllFolders\Shell" 'FolderType' 'NotSpecified' 'String' }
    Undo={ Remove-Item -LiteralPath 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders' -Recurse -Force -ErrorAction SilentlyContinue }
    Test={ (Get-RegVal 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType') -eq 'NotSpecified' } }

Add-Tweak @{ Id='gamedvr'; Group='ess'; Name='ايقاف GameDVR (تسجيل الالعاب بالخلفية)'
    Desc='يوقف تسجيل الكليبات بالخلفية اللي ياكل من الفريمات.'
    Reg=@( (R 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 1),
           (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 1),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 $null) ) }

Add-Tweak @{ Id='hiberoff'; Group='ess'; Name='ايقاف السبات (Hibernation)'
    Desc='يحذف ملف hiberfil.sys ويوفر مساحة بحجم جزء من الرام. يعطّل ايضا التشغيل السريع (Fast Startup).'
    Warn='يتعارض مع خيار "اظهار السبات" بالتعديلات المتقدمة.'
    Apply={ powercfg /hibernate off | Out-Null }
    Undo={ powercfg /hibernate on | Out-Null }
    Test={ (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0 } }

Add-Tweak @{ Id='location'; Group='ess'; Name='ايقاف تتبع الموقع (Location Tracking)'
    Desc='يمنع التطبيقات والنظام من معرفة موقعك.'
    Reg=@( (R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'Allow' 'String'),
           (R 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0 1) ) }

Add-Tweak @{ Id='storagesense'; Group='ess'; Name='ايقاف Storage Sense'
    Desc='يوقف التنظيف التلقائي للملفات المؤقتة وسلة المحذوفات.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0 1) ) }

Add-Tweak @{ Id='wifisense'; Group='ess'; Name='ايقاف Wi-Fi Sense'
    Desc='يمنع الاتصال التلقائي بنقاط وايفاي مفتوحة وارسال تقارير عنها.'
    Reg=@( (R 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'Value' 0 1),
           (R 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'Value' 0 1) ) }

Add-Tweak @{ Id='endtask'; Group='ess'; Name='زر "انهاء المهمة" بكليك يمين على شريط المهام'
    Desc='تقدر تقفل اي برنامج عالق بكليك يمين على ايقونته بشريط المهام (ويندوز 11).'
    Reg=@( (R "$ExpAdv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1 0) ) }

Add-Tweak @{ Id='diskcleanup'; Group='ess'; Name='تشغيل تنظيف القرص (Disk Cleanup)'; Action=$true
    Desc='يفتح اداة تنظيف القرص وينظّف ملفات النظام القديمة. (تنفيذ مرة وحدة)'
    Apply={ Start-Process cleanmgr.exe -ArgumentList "/d $env:SystemDrive /VERYLOWDISK" } }

Add-Tweak @{ Id='ps7tele'; Group='ess'; Name='ايقاف تلمتري PowerShell 7'
    Desc='يضيف متغير POWERSHELL_TELEMETRY_OPTOUT لايقاف ارسال بيانات PowerShell 7.'
    Apply={ [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine') }
    Undo={ [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', $null, 'Machine') }
    Test={ [Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', 'Machine') -eq '1' } }

Add-Tweak @{ Id='svcmanual'; Group='ess'; Name='تحويل خدمات غير ضرورية الى Manual'
    Desc='يحوّل عشرين خدمة قليلة الاستخدام (Xbox, الفاكس, Remote Registry...) لتشتغل عند الطلب فقط. الاطفاء يرجعها لوضعها الاصلي.'
    Apply={ Svc-Backup 'svcmanual' $ManualServices; Svc-Set $ManualServices 'Manual' }
    Undo={ Svc-Restore 'svcmanual' } }

# ---------------- تعديلات متقدمة (حذر) ----------------
Add-Tweak @{ Id='adobenet'; Group='adv'; Name='حظر شبكة Adobe (Adobe Network Block)'
    Desc='يضيف نطاقات Adobe لملف hosts لمنع الاتصال بسيرفرات التفعيل والتلمتري.'
    Warn='تحذير: قد يوقف برامج Adobe الاصلية المرخّصة لانها تحتاج التحقق من الترخيص. قد يمنعه مضاد الفيروسات.'
    Apply={ $c = Get-Content $HostsFile -Raw
            if ($c -notmatch '# ArabTweaks-Adobe-Start') {
                $lines = @('', '# ArabTweaks-Adobe-Start') + ($AdobeHosts | ForEach-Object { "0.0.0.0 $_" }) + '# ArabTweaks-Adobe-End'
                Add-Content -Path $HostsFile -Value $lines -Encoding ASCII } }
    Undo={ $c = Get-Content $HostsFile -Raw
           $c = [regex]::Replace($c, '(?s)\r?\n# ArabTweaks-Adobe-Start.*?# ArabTweaks-Adobe-End\r?\n?', "`r`n")
           Set-Content -Path $HostsFile -Value $c -NoNewline -Encoding ASCII }
    Test={ (Get-Content $HostsFile -Raw) -match '# ArabTweaks-Adobe-Start' } }

Add-Tweak @{ Id='adobedebloat'; Group='adv'; Name='تخفيف Adobe (Adobe Debloat)'
    Desc='يوقف خدمات Adobe اللي تشتغل بالخلفية (Update, Genuine Monitor...). الاطفاء يرجعها.'
    Apply={ Svc-Backup 'adobedebloat' $AdobeServices; Svc-Set $AdobeServices 'Disabled' $true }
    Undo={ Svc-Restore 'adobedebloat' } }

Add-Tweak @{ Id='razer'; Group='adv'; Name='منع تثبيت برامج Razer تلقائيا'
    Desc='يمنع ويندوز يثبّت Razer Synapse تلقائيا اذا وصلت جهاز Razer.'
    Apply={ Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' 'DisableCoInstallers' 1
            $d = "$env:SystemRoot\Installer\Razer"; New-Item -ItemType Directory -Path $d -Force | Out-Null
            icacls $d /deny 'Everyone:(W)' | Out-Null }
    Undo={ $d = "$env:SystemRoot\Installer\Razer"; icacls $d /remove:d Everyone | Out-Null
           Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
           Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' 'DisableCoInstallers' 0 }
    Test={ (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' 'DisableCoInstallers') -eq 1 } }

Add-Tweak @{ Id='brave'; Group='adv'; Name='تخفيف متصفح Brave (Brave Debloat)'
    Desc='يعطّل المحفظة و Rewards و VPN و AI Chat والتلمتري بمتصفح Brave.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveRewardsDisabled' 1 $null),
           (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveWalletDisabled' 1 $null),
           (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveVPNDisabled' 1 $null),
           (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveAIChatEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveNewsDisabled' 1 $null),
           (R 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'MetricsReportingEnabled' 0 $null) ) }

Add-Tweak @{ Id='edgedebloat'; Group='adv'; Name='تخفيف متصفح Edge (Edge Debloat)'
    Desc='يعطّل الشريط الجانبي والتسوق والتوصيات والتشغيل بالخلفية وبيانات التشخيص بـ Edge.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'EdgeShoppingAssistantEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'PersonalizationReportingEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'ShowRecommendationsEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'MetricsReportingEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DiagnosticData' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'EdgeFollowEnabled' 0 $null) ) }

Add-Tweak @{ Id='wtps7'; Group='adv'; Name='جعل PowerShell 7 الافتراضي بـ Windows Terminal'
    Desc='يغيّر البروفايل الافتراضي بالترمنال من PowerShell 5 الى PowerShell 7 (لازم يكون PowerShell 7 منزّل).'
    Apply={ if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { throw 'PowerShell 7 غير مثبّت' }
            if (Test-Path $WTSettings) { (Get-Content $WTSettings -Raw) -replace '"defaultProfile"\s*:\s*"\{[^}]*\}"', '"defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"' | Set-Content $WTSettings -Encoding UTF8 } }
    Undo={ if (Test-Path $WTSettings) { (Get-Content $WTSettings -Raw) -replace '"defaultProfile"\s*:\s*"\{[^}]*\}"', '"defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"' | Set-Content $WTSettings -Encoding UTF8 } }
    Test={ (Test-Path $WTSettings) -and ((Get-Content $WTSettings -Raw) -match '574e775e-4f2a-5b96-ac1e-a2962a402336"') } }

Add-Tweak @{ Id='disableedge'; Group='adv'; Name='تعطيل Edge (منع التحديث والتثبيت والتشغيل التلقائي)'
    Desc='يوقف خدمات وتحديثات Edge ومهامه المجدولة. ما يحذف المتصفح لان ويندوز وبعض البرامج (WebView2) تعتمد عليه.'
    Warn='تأكد ان عندك متصفح ثاني قبل التفعيل.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 $null) )
    Apply={ Svc-Backup 'disableedge' @('edgeupdate','edgeupdatem'); Svc-Set @('edgeupdate','edgeupdatem') 'Disabled' $true
            Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
    Undo={ Svc-Restore 'disableedge'
           Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
    Test={ $script:State.applied -contains 'disableedge' } }

Add-Tweak @{ Id='bgapps'; Group='adv'; Name='ايقاف تطبيقات الخلفية (Background Apps)'
    Desc='يمنع تطبيقات المتجر تشتغل بالخلفية وتاكل رام ومعالج.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 0),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 $null) ) }

Add-Tweak @{ Id='fso'; Group='adv'; Name='ايقاف تحسينات ملء الشاشة (Fullscreen Optimizations)'
    Desc='يرجع الالعاب لوضع Fullscreen الحقيقي، وبعض الالعاب تتحسن فيها الفريمات وتقل المشاكل.'
    Reg=@( (R 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1 0),
           (R 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 0),
           (R 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1 0),
           (R 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2 0) ) }

Add-Tweak @{ Id='prefip4'; Group='adv'; Name='تفضيل IPv4 على IPv6 (Prefer IPv4)'
    Desc='يخلي ويندوز يستخدم IPv4 اولا بدون ايقاف IPv6 بالكامل.'; Restart='reboot'
    Apply={ if ((Get-RegVal $Tcpip6 'DisabledComponents') -ne 255) { Set-RegVal $Tcpip6 'DisabledComponents' 32 } }
    Undo={ if ((Get-RegVal $Tcpip6 'DisabledComponents') -eq 32) { Del-RegVal $Tcpip6 'DisabledComponents' } }
    Test={ (Get-RegVal $Tcpip6 'DisabledComponents') -eq 32 } }

Add-Tweak @{ Id='noip6'; Group='adv'; Name='ايقاف IPv6'
    Desc='يعطّل IPv6 بالكامل على كل كروت الشبكة.'; Restart='reboot'
    Warn='بعض الخدمات (مثل بعض شبكات Xbox / الشبكات المنزلية) قد تتأثر.'
    Apply={ Set-RegVal $Tcpip6 'DisabledComponents' 255; Disable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue }
    Undo={ Del-RegVal $Tcpip6 'DisabledComponents'; Enable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue }
    Test={ (Get-RegVal $Tcpip6 'DisabledComponents') -eq 255 } }

Add-Tweak @{ Id='teredo'; Group='adv'; Name='ايقاف Teredo'
    Desc='يوقف نفق Teredo (IPv6 عبر IPv4) اللي ممكن يسبب بنق مرتفع بشبكات الالعاب.'
    Apply={ netsh interface teredo set state disabled | Out-Null }
    Undo={ netsh interface teredo set state default | Out-Null } }

Add-Tweak @{ Id='recall'; Group='adv'; Name='ايقاف Recall'
    Desc='يعطّل ميزة Recall (لقطات الشاشة الذكية) على اجهزة Copilot+ / ويندوز 11 24H2.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 $null) )
    Apply={ dism /online /Disable-Feature /FeatureName:Recall /NoRestart | Out-Null }
    Undo={ dism /online /Enable-Feature /FeatureName:Recall /NoRestart | Out-Null } }

Add-Tweak @{ Id='copilot'; Group='adv'; Name='ايقاف Microsoft Copilot'
    Desc='يخفي زر Copilot ويعطّله بالنظام.'; Restart='explorer'
    Reg=@( (R 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 $null),
           (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 $null),
           (R $ExpAdv 'ShowCopilotButton' 0 1) ) }

Add-Tweak @{ Id='intellms'; Group='adv'; Name='ايقاف Intel MM (vPro LMS)'
    Desc='يوقف خدمة Intel Local Management Service (تظهر على اجهزة Intel vPro وغالبا ما تحتاجها).'
    Apply={ Svc-Backup 'intellms' @('LMS'); Svc-Set @('LMS') 'Disabled' $true }
    Undo={ Svc-Restore 'intellms' } }

Add-Tweak @{ Id='notiftray'; Group='adv'; Name='ايقاف لوحة الاشعارات والتقويم'
    Desc='يعطّل مركز الاشعارات (والتقويم المنبثق) نهائيا.'; Restart='explorer'
    Reg=@( (R 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1 $null),
           (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 1) ) }

Add-Tweak @{ Id='wpbt'; Group='adv'; Name='ايقاف Windows Platform Binary Table (WPBT)'
    Desc='يمنع البايوس من زرع برامج داخل ويندوز عند الاقلاع (تستخدمها بعض الشركات لتثبيت برامج تلقائيا).'; Restart='reboot'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1 $null) ) }

Add-Tweak @{ Id='visualfx'; Group='adv'; Name='ضبط العرض للاداء (Display for Performance)'
    Desc='يقلل الانيميشن والظلال والتأثيرات البصرية لسرعة اكبر. يحتاج تسجيل خروج ودخول.'; Restart='signout'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 0),
           (R 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) ([byte[]](0x9E,0x1E,0x07,0x80,0x12,0x00,0x00,0x00)) 'Binary'),
           (R 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' '1' 'String'),
           (R $ExpAdv 'TaskbarAnimations' 0 1),
           (R $ExpAdv 'ListviewAlphaSelect' 0 1),
           (R $ExpAdv 'ListviewShadow' 0 1) ) }

Add-Tweak @{ Id='hiberdef'; Group='adv'; Name='اظهار السبات (Hibernate) بقائمة الايقاف (مناسب للابتوب)'
    Desc='يفعّل السبات ويضيفه لقائمة الايقاف.'
    Warn='يتعارض مع "ايقاف السبات" - لهذا ما يدخل بزر تشغيل الكل.'; NoAll=$true
    Apply={ powercfg /hibernate on | Out-Null; Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 1 }
    Undo={ Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 0 }
    Test={ (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption') -eq 1 } }

Add-Tweak @{ Id='classicmenu'; Group='adv'; Name='قائمة كليك يمين الكلاسيكية (ويندوز 10)'
    Desc='يرجع قائمة كليك يمين القديمة الكاملة بدون الضغط على "Show more options".'; Restart='explorer'
    Apply={ New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Force -Value '' | Out-Null }
    Undo={ Remove-Item -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue }
    Test={ Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' } }

Add-Tweak @{ Id='utc'; Group='adv'; Name='ضبط الوقت على UTC (للجهاز المزدوج Dual Boot)'
    Desc='يخلي ويندوز يقرأ ساعة الجهاز كـ UTC مثل لينكس.'
    Warn='لا تفعّله الا اذا عندك لينكس بجانب ويندوز، وإلا ممكن تتغير ساعتك. لهذا ما يدخل بزر تشغيل الكل.'; NoAll=$true
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1 $null) ) }

Add-Tweak @{ Id='nohome'; Group='adv'; Name='ازالة "Home" من مستكشف الملفات'
    Desc='يشيل صفحة Home ويفتح المستكشف على "هذا الكمبيوتر" مباشرة.'; Restart='explorer'
    Apply={ $k='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue; Set-RegVal $ExpAdv 'LaunchTo' 1 }
    Undo={ $p='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489'
           if (Test-Path -LiteralPath $p) { New-Item -Path "$p\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}" -Force -Value 'CLSID_MSGraphHomeFolder' | Out-Null }
           Set-RegVal $ExpAdv 'LaunchTo' 0 }
    Test={ (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489') -and -not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}') } }

Add-Tweak @{ Id='nogallery'; Group='adv'; Name='ازالة "Gallery" من مستكشف الملفات'
    Desc='يخفي المعرض من الشريط الجانبي.'; Restart='explorer'; DefOn=$true
    Reg=@( (R 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree' 0 1) )
    Test={ (Get-RegVal 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree') -eq 0 } }

Add-Tweak @{ Id='onedrive'; Group='adv'; Name='ازالة OneDrive'
    Desc='يقفل OneDrive ويحذفه من النظام ويمنع المزامنة. الاطفاء يعيد تثبيته.'
    Warn='تحذير: خذ نسخة من ملفاتك اللي على OneDrive قبل الحذف.'
    Apply={ Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            $x = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"; if (-not (Test-Path $x)) { $x = "$env:SystemRoot\System32\OneDriveSetup.exe" }
            if (Test-Path $x) { Start-Process $x -ArgumentList '/uninstall' -Wait }
            Set-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 }
    Undo={ Del-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'
           $x = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"; if (-not (Test-Path $x)) { $x = "$env:SystemRoot\System32\OneDriveSetup.exe" }
           if (Test-Path $x) { Start-Process $x -Wait } } }

# ---------------- تفضيلات شكلية (ما تدخل بزر تشغيل الكل) ----------------
Add-Tweak @{ Id='dark'; Group='pref'; Name='الثيم الداكن (Dark Theme)'
    Desc='يفعّل الوضع الداكن للنظام والتطبيقات.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0 1),
           (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0 1) ) }

Add-Tweak @{ Id='bing'; Group='pref'; Name='بحث Bing بقائمة ابدأ'; DefOn=$true
    Desc='مفعّل = البحث بقائمة ابدأ يعرض نتائج انترنت من Bing. اطفئه اذا تبي بحث محلي فقط.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1 0),
           (R 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' $null 1) ) }

Add-Tweak @{ Id='numlock'; Group='pref'; Name='تشغيل NumLock عند الاقلاع'
    Desc='يفعّل زر NumLock تلقائيا بعد تشغيل الجهاز.'
    Reg=@( (R 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' '0' 'String'),
           (R 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' '0' 'String') ) }

Add-Tweak @{ Id='verbose'; Group='pref'; Name='رسائل مفصّلة اثناء تسجيل الدخول'
    Desc='يعرض تفاصيل ما يسويه ويندوز اثناء الدخول والخروج (مفيد للتشخيص).'
    Reg=@( (R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1 0) ) }

Add-Tweak @{ Id='recstart'; Group='pref'; Name='التوصيات بقائمة ابدأ'; DefOn=$true
    Desc='مفعّل = تظهر الملفات والتطبيقات المقترحة بقائمة ابدأ.'
    Reg=@( (R $ExpAdv 'Start_IrisRecommendations' 1 0) ) }

Add-Tweak @{ Id='settingshome'; Group='pref'; Name='صفحة Home في الاعدادات'
    Desc='مفعّل = تظهر الصفحة الرئيسية بتطبيق الاعدادات. اطفئه لاخفائها.'
    Reg=@( (R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' $null 'hide:home' 'String') ) }

Add-Tweak @{ Id='snapwin'; Group='pref'; Name='تثبيت النوافذ (Snap Window)'; DefOn=$true
    Desc='سحب النافذة لحافة الشاشة لتثبيتها بنصف او ربع الشاشة.'
    Reg=@( (R 'HKCU:\Control Panel\Desktop' 'WindowArrangementActive' '1' '0' 'String') ) }

Add-Tweak @{ Id='snapflyout'; Group='pref'; Name='قائمة Snap Assist عند زر التكبير'; DefOn=$true; Restart='explorer'
    Desc='تظهر خيارات التقسيم لما تمرر الماوس على زر التكبير (ويندوز 11).'
    Reg=@( (R $ExpAdv 'EnableSnapAssistFlyout' 1 0) ) }

Add-Tweak @{ Id='snapsugg'; Group='pref'; Name='اقتراحات Snap Assist'; DefOn=$true
    Desc='بعد تثبيت نافذة، يقترح عليك نوافذ ثانية تملأ الباقي.'
    Reg=@( (R $ExpAdv 'SnapAssist' 1 0) ) }

Add-Tweak @{ Id='mouseaccel'; Group='pref'; Name='تسريع الماوس (Mouse Acceleration)'; DefOn=$true; Restart='signout'
    Desc='مفعّل = دقة الماوس تتغير حسب سرعة تحريكه. اللاعبين غالبا يطفئونه لدقة ثابتة.'
    Reg=@( (R 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1' '0' 'String'),
           (R 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6' '0' 'String'),
           (R 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10' '0' 'String') ) }

Add-Tweak @{ Id='sticky'; Group='pref'; Name='مفاتيح Sticky Keys'; DefOn=$true
    Desc='مفعّل = ضغط Shift خمس مرات يفتح نافذة Sticky Keys المزعجة. اطفئه لتعطيلها.'
    Reg=@( (R 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '510' '58' 'String') ) }

Add-Tweak @{ Id='mpo'; Group='pref'; Name='Multiplane Overlay (MPO)'; DefOn=$true; Restart='reboot'
    Desc='مفعّل = وضع ويندوز الافتراضي. اطفاؤه (تعطيل MPO) يحل مشاكل الوميض والتقطيع مع بعض كروت Nvidia/AMD.'
    Reg=@( (R 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' $null 5) ) }

Add-Tweak @{ Id='newoutlook'; Group='pref'; Name='Outlook الجديد (New Outlook)'
    Desc='مفعّل = يستخدم Outlook الجديد بدل الكلاسيكي.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences' 'UseNewOutlook' 1 0) ) }

Add-Tweak @{ Id='hidden'; Group='pref'; Name='اظهار الملفات المخفية'; Restart='explorer'
    Desc='يعرض الملفات والمجلدات المخفية بالمستكشف.'
    Reg=@( (R $ExpAdv 'Hidden' 1 2) ) }

Add-Tweak @{ Id='fileext'; Group='pref'; Name='اظهار امتدادات الملفات (.exe .txt ...)'; Restart='explorer'
    Desc='يعرض امتداد الملف بعد اسمه، مهم للامان.'
    Reg=@( (R $ExpAdv 'HideFileExt' 0 1) ) }

Add-Tweak @{ Id='tbsearch'; Group='pref'; Name='زر البحث بشريط المهام'; Restart='explorer'
    Desc='يظهر مربع/ايقونة البحث بشريط المهام.'
    Reg=@( (R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1 0) )
    Test={ (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode') -ne 0 } }

Add-Tweak @{ Id='tbtask'; Group='pref'; Name='زر Task View بشريط المهام'; DefOn=$true; Restart='explorer'
    Desc='زر عرض المهام وسطح المكتب الافتراضي.'
    Reg=@( (R $ExpAdv 'ShowTaskViewButton' 1 0) ) }

Add-Tweak @{ Id='tbcenter'; Group='pref'; Name='ايقونات شريط المهام بالوسط'; DefOn=$true; Restart='explorer'
    Desc='مفعّل = بالوسط (ويندوز 11). مطفأ = على اليسار مثل ويندوز 10.'
    Reg=@( (R $ExpAdv 'TaskbarAl' 1 0) ) }

Add-Tweak @{ Id='tbwidgets'; Group='pref'; Name='زر الودجت (Widgets) بشريط المهام'; DefOn=$true; Restart='explorer'
    Desc='يظهر زر الاخبار والطقس. (قد يمنع ويندوز تغييره على بعض الاصدارات)'
    Reg=@( (R $ExpAdv 'TaskbarDa' 1 0) ) }

Add-Tweak @{ Id='bsod'; Group='pref'; Name='الشاشة الزرقاء المفصّلة (Detailed BSoD)'
    Desc='تعرض تفاصيل الخطأ بدل الوجه الحزين، افضل للتشخيص.'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisplayParameters' 1 0),
           (R 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisableEmoticon' 1 0) ) }

Add-Tweak @{ Id='s3sleep'; Group='pref'; Name='نوم S3 (بدل Modern Standby)'; Restart='reboot'
    Desc='يرجع نمط النوم التقليدي S3 اللي يستهلك بطارية اقل (اذا كان جهازك يدعمه).'
    Warn='بعض الاجهزة ما تدعمه وقد تفشل بالنوم.'
    Reg=@( (R 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'PlatformAoAcOverride' 0 $null) ) }

Add-Tweak @{ Id='crossdev'; Group='pref'; Name='الاستئناف بين الاجهزة (Cross-Device Resume)'; Restart='reboot'
    Desc='مفعّل = تكمل انشطتك من جوالك/اجهزتك الثانية. اطفئه لتعطيل الميزة.'
    Reg=@( (R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableCdp' $null 0) ) }

# ============================================================
#  منطق التشغيل / الاطفاء
# ============================================================
function Invoke-On($t) {
    if ($t.Reg) { foreach ($r in $t.Reg) { if ($null -eq $r.On) { Del-RegVal $r.P $r.N } else { Set-RegVal $r.P $r.N $r.On $r.T } } }
    if ($t.Apply) { & $t.Apply }
}
function Invoke-Off($t) {
    if ($t.Reg) { foreach ($r in $t.Reg) { if ($null -eq $r.Off) { Del-RegVal $r.P $r.N } else { Set-RegVal $r.P $r.N $r.Off $r.T } } }
    if ($t.Undo) { & $t.Undo }
}
function Get-On($t) {
    if ($t.Action) { return $false }
    if ($t.Test) { return [bool](& $t.Test) }
    if ($t.Reg) {
        foreach ($r in $t.Reg) {
            $cur = Get-RegVal $r.P $r.N
            if ($null -eq $r.On) { if ($null -ne $cur) { return $false } }
            else {
                if ($null -eq $cur -and $t.DefOn) { continue }
                if (-not (Test-Same $cur $r.On)) { return $false }
            }
        }
        return $true
    }
    return ($script:State.applied -contains $t.Id)
}

function New-RestorePoint {
    Log '... جاري انشاء نقطة الاستعادة: before tweaks'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'before tweaks' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Del-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency'
        $script:RPDone = $true
        Log '✔ تم انشاء نقطة الاستعادة: before tweaks'
    } catch {
        Log "✖ تعذّر انشاء نقطة الاستعادة: $($_.Exception.Message)"
    }
}

function Refresh-Checks {
    foreach ($r in $script:Rows) { $r.CB.Checked = (Get-On $r.T) }
}

function Ask($msg) {
    $res = [System.Windows.Forms.MessageBox]::Show($msg, 'ArabTweaks', 'YesNo', 'Warning', 'Button2', ([System.Windows.Forms.MessageBoxOptions]'RtlReading,RightAlign'))
    return ($res -eq 'Yes')
}

function Do-Sync {
    $todo = New-Object System.Collections.ArrayList
    foreach ($r in $script:Rows) {
        $t = $r.T; $want = $r.CB.Checked
        if ($t.Action) { if ($want) { [void]$todo.Add(@($t, 'on')) }; continue }
        $cur = Get-On $t
        if ($want -and -not $cur) { [void]$todo.Add(@($t, 'on')) }
        elseif ((-not $want) -and $cur) { [void]$todo.Add(@($t, 'off')) }
    }
    if ($todo.Count -eq 0) { Log 'ما في تغييرات جديدة للتطبيق.'; return }

    $form.UseWaitCursor = $true
    foreach ($b in $script:Buttons) { $b.Enabled = $false }
    $needExp = $false; $needReboot = $false; $needSign = $false

    $anyOn = $false; foreach ($i in $todo) { if ($i[1] -eq 'on' -and -not $i[0].Action) { $anyOn = $true } }
    if ($anyOn -and -not $script:RPDone) { New-RestorePoint }

    foreach ($item in $todo) {
        $t = $item[0]; $mode = $item[1]
        try {
            if ($mode -eq 'on') {
                Invoke-On $t
                if (-not $t.Action -and ($script:State.applied -notcontains $t.Id)) { $script:State.applied = @($script:State.applied) + $t.Id }
                Log "✔ تم التشغيل: $($t.Name)"
            } else {
                Invoke-Off $t
                $script:State.applied = @($script:State.applied | Where-Object { $_ -ne $t.Id })
                Log "✔ تم الاطفاء: $($t.Name)"
            }
            switch ($t.Restart) { 'explorer' { $needExp = $true } 'reboot' { $needReboot = $true } 'signout' { $needSign = $true } }
        } catch {
            Log "✖ فشل: $($t.Name) - $($_.Exception.Message)"
        }
    }
    Save-State
    if ($needExp) { Log '... اعادة تشغيل مستكشف الملفات'; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }
    Refresh-Checks
    foreach ($b in $script:Buttons) { $b.Enabled = $true }
    $form.UseWaitCursor = $false
    Log '=== انتهى ==='

    if ($needReboot) {
        if (Ask 'بعض التغييرات تحتاج ريستارت عشان تشتغل. تبي تعيد التشغيل الحين؟') { Restart-Computer -Force }
    } elseif ($needSign) {
        [void][System.Windows.Forms.MessageBox]::Show('بعض التغييرات تحتاج تسجيل خروج ودخول عشان تظهر.', 'ArabTweaks', 'OK', 'Information', 'Button1', ([System.Windows.Forms.MessageBoxOptions]'RtlReading,RightAlign'))
    }
}

# ============================================================
#  الواجهة
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'ArabTweaks - اداة تحسين ويندوز'
$form.ClientSize = New-Object System.Drawing.Size(1000, 760)
$form.StartPosition = 'CenterScreen'
$form.RightToLeft = 'Yes'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 100
$title = New-Object System.Windows.Forms.Label
$title.Text = 'ArabTweaks - اداة تحسين ويندوز بالعربي'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $false; $title.Location = New-Object System.Drawing.Point(10, 8); $title.Size = New-Object System.Drawing.Size(980, 30)
$top.Controls.Add($title)

function New-Btn($text, $x, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, 46); $b.Size = New-Object System.Drawing.Size(230, 44)
    $b.FlatStyle = 'Flat'; $b.BackColor = $color; $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $top.Controls.Add($b); return $b
}
$btnAll   = New-Btn 'تشغيل الكل (بدون الشكلية)' 760 ([System.Drawing.Color]::SeaGreen)
$btnNone  = New-Btn 'اطفاء الكل' 520 ([System.Drawing.Color]::Firebrick)
$btnApply = New-Btn 'تطبيق المحدد' 280 ([System.Drawing.Color]::RoyalBlue)
$btnRP    = New-Btn 'نقطة استعادة (before tweaks)' 40 ([System.Drawing.Color]::DimGray)
$script:Buttons = @($btnAll, $btnNone, $btnApply, $btnRP)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true; $script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Dock = 'Bottom'; $script:LogBox.Height = 140; $script:LogBox.RightToLeft = 'Yes'

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.RightToLeft = 'Yes'
$groups = @(
    @{ Id='perf'; Title='اداء الالعاب' },
    @{ Id='ess';  Title='التعديلات الاساسية' },
    @{ Id='adv';  Title='تعديلات متقدمة (حذر)' },
    @{ Id='pref'; Title='تفضيلات شكلية' }
)
$script:Rows = @()
$descFont = New-Object System.Drawing.Font('Segoe UI', 9)
$nameFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

foreach ($g in $groups) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $g.Title; $page.RightToLeft = 'Yes'
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.AutoScroll = $true
    $y = 8
    foreach ($t in ($script:Tweaks | Where-Object { $_.Group -eq $g.Id })) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $t.Name; $cb.Font = $nameFont; $cb.AutoSize = $false
        $cb.Location = New-Object System.Drawing.Point(20, $y); $cb.Size = New-Object System.Drawing.Size(900, 26)
        $cb.RightToLeft = 'Yes'
        $panel.Controls.Add($cb)
        $text = $t.Desc
        if ($t.Warn) { $text += "`r`n" + $t.Warn }
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $descFont, (New-Object System.Drawing.Size(860, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text; $lbl.Font = $descFont; $lbl.AutoSize = $false
        $lbl.ForeColor = [System.Drawing.Color]::DimGray
        if ($t.Warn) { $lbl.ForeColor = [System.Drawing.Color]::DarkOrange }
        $lbl.RightToLeft = 'Yes'
        $lbl.Location = New-Object System.Drawing.Point(20, ($y + 26)); $lbl.Size = New-Object System.Drawing.Size(860, ($sz.Height + 6))
        $panel.Controls.Add($lbl)
        $y = $y + 26 + $sz.Height + 22
        $script:Rows += @{ T = $t; CB = $cb }
    }
    $page.Controls.Add($panel)
    [void]$tabs.TabPages.Add($page)
}

$form.Controls.Add($tabs)
$form.Controls.Add($script:LogBox)
$form.Controls.Add($top)

$btnAll.Add_Click({
    if (Ask "راح يتم تشغيل كل التعديلات (الاداء + الاساسية + المتقدمة) ما عدا التفضيلات الشكلية، ومعها انشاء نقطة استعادة.`r`nبعض المتقدمة فيها حذف (مثل OneDrive) او تعطيل (Edge / IPv6).`r`nتكمل؟") {
        foreach ($r in $script:Rows) { if ($r.T.Group -ne 'pref' -and -not $r.T.NoAll -and -not $r.T.Action) { $r.CB.Checked = $true } }
        Do-Sync
    }
})
$btnNone.Add_Click({
    if (Ask "راح يتم اطفاء كل الخيارات (بما فيها الشكلية) وارجاعها للوضع الافتراضي.`r`nتكمل؟") {
        foreach ($r in $script:Rows) { $r.CB.Checked = $false }
        Do-Sync
    }
})
$btnApply.Add_Click({ Do-Sync })
$btnRP.Add_Click({ New-RestorePoint })

$form.Add_Shown({
    $form.UseWaitCursor = $true
    Load-State
    Refresh-Checks
    $form.UseWaitCursor = $false
    Log 'جاهز. علّم على الخيارات اللي تبيها ثم اضغط "تطبيق المحدد".'
    Log 'الخيارات المعلَّمة بالبداية = مفعّلة فعلا على جهازك. قبل اول تطبيق ينشئ البرنامج نقطة استعادة باسم: before tweaks'
})
[void]$form.ShowDialog()
