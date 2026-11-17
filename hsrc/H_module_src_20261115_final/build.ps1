$ErrorActionPreference = "Continue"

# 路径全部相对脚本所在目录，换台机器只要改下面四个工具路径即可
$root = $PSScriptRoot
if (-not $root) { $root = "C:\Users\Administrator\Doubao\chats\2026-11-11\new-chat\wxh-apk-build" }
$proj = Split-Path -Parent $root
$log  = Join-Path $root "log"
$out  = Join-Path $root "out"
$classes = Join-Path $out "classes"
$apkName = if ($env:WXH_APKNAME) { $env:WXH_APKNAME } else { "H_module_v6.3.apk" }
$verCode = 47
$verName = "6.3"

$jbr     = "C:\Users\Administrator\Doubao\jdk17\jdk-17.0.21.0.2+1"
if (-not (Test-Path (Join-Path $jbr "bin\javac.exe"))) {
    $jbr = "C:\Program Files\Android\Android Studio\jbr"
}
$javac   = Join-Path $jbr "bin\javac.exe"
$jar     = Join-Path $jbr "bin\jar.exe"
$keytool = Join-Path $jbr "bin\keytool.exe"
$env:JAVA_HOME = $jbr
$env:PATH = (Join-Path $jbr "bin") + ";" + $env:PATH

$sdk        = "C:\Users\Administrator\AppData\Local\Android\Sdk"
$bt         = Join-Path $sdk "build-tools\36.1.0"
$androidJar = Join-Path $sdk "platforms\android-36\android.jar"

New-Item -ItemType Directory -Force -Path $log, $classes | Out-Null
Get-ChildItem -LiteralPath $classes -Force | Remove-Item -Recurse -Force

# ---------- 1. javac：壳 + 入口 + 界面 + 主功能，全部编译 ----------
Write-Output "[1/6] javac ..."
$sources = @(
    (Join-Path $root "src\wxh\Entry.java"),
    (Join-Path $root "src\wxh\EmojiProvider.java"),
    (Join-Path $root "src\wxh\Probe.java"),
    (Join-Path $root "src\wxh\SettingsActivity.java"),
    (Join-Path $root "src\wxh\License.java"),
    (Join-Path $root "src\wxh\AiReaderService.java"),
    (Join-Path $root "plugin\Plugin.java")
)
& $javac -nowarn -encoding UTF-8 -source 8 -target 8 -Xlint:-options `
    -bootclasspath $androidJar -cp (Join-Path $root "api-82.jar") `
    -d $classes $sources 2> "$log\javac.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\javac.err" -Tail 30; throw "javac failed" }
$n = (Get-ChildItem -LiteralPath $classes -Recurse -Filter *.class).Count
Write-Output "      ok, $n class files"

# Xposed API 桩类不能进包，否则运行时会用空实现盖掉真框架
$stray = Get-ChildItem -LiteralPath $classes -Recurse -Filter *.class | Where-Object { $_.FullName -match 'robv|xposed' }
if ($stray) { throw ("stub leaked: " + ($stray[0].FullName)) }

# ---------- 2. d8 ----------
Write-Output "[2/6] d8 ..."
$classesJar = Join-Path $out "classes.jar"
if (Test-Path -LiteralPath $classesJar) { Remove-Item -LiteralPath $classesJar -Force }
& $jar cf $classesJar -C $classes .
$dexOut = Join-Path $out "dex"
New-Item -ItemType Directory -Force -Path $dexOut | Out-Null
Get-ChildItem -LiteralPath $dexOut -Force | Remove-Item -Recurse -Force
# 先出一份未混淆 dex 做兜底，再用 R8 混淆覆盖
& (Join-Path $bt "d8.bat") --release --min-api 26 --lib $androidJar --output $dexOut $classesJar 2> "$log\d8.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\d8.err" -Tail 30; throw "d8 failed" }
$dexRaw = Join-Path $out "classes_raw.dex"
Copy-Item -LiteralPath (Join-Path $dexOut "classes.dex") -Destination $dexRaw -Force

if ($env:WXH_NO_OBF -ne "1") {
    Write-Output "[2b/6] R8 obfuscate ..."
    # 实测：改名本身不影响加载，但 Probe 反射调用的 wxh.Plugin.install() 必须保留（见 wxh-r8.pro）
    $r8Pro = if ($env:WXH_R8PRO) { $env:WXH_R8PRO } else { "wxh-r8.pro" }
    $obfOut = Join-Path $out "dex_obf"
    New-Item -ItemType Directory -Force -Path $obfOut | Out-Null
    Get-ChildItem -LiteralPath $obfOut -Force | Remove-Item -Recurse -Force
    & (Join-Path $jbr "bin\java.exe") -cp (Join-Path $bt "lib\d8.jar") com.android.tools.r8.R8 `
        --release --min-api 26 `
        --lib $androidJar --lib (Join-Path $root "api-82.jar") `
        --pg-conf (Join-Path $root $r8Pro) `
        --output $obfOut $classesJar 2> "$log\r8.err"
    if ($LASTEXITCODE -ne 0) { Get-Content "$log\r8.err" -Tail 30; throw "r8 failed" }
    Copy-Item -LiteralPath (Join-Path $obfOut "classes.dex") -Destination (Join-Path $dexOut "classes.dex") -Force
}$dex = Join-Path $dexOut "classes.dex"
Write-Output ("      ok, " + (Get-Item -LiteralPath $dex).Length + " B")

# ---------- 3. aapt2 ----------
Write-Output "[3/6] aapt2 ..."
$resZip = Join-Path $out "res.zip"
$baseApk = Join-Path $out "base.apk"
foreach ($f in @($resZip, $baseApk)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
& (Join-Path $bt "aapt2.exe") compile --dir (Join-Path $root "res") -o $resZip 2> "$log\aapt2c.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\aapt2c.err" -Tail 20; throw "aapt2 compile failed" }
& (Join-Path $bt "aapt2.exe") link -o $baseApk -I $androidJar `
    --manifest (Join-Path $root "AndroidManifest.xml") `
    -A (Join-Path $root "assets") `
    --min-sdk-version 26 --target-sdk-version 34 `
    --version-code $verCode --version-name $verName `
    $resZip 2> "$log\aapt2l.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\aapt2l.err" -Tail 20; throw "aapt2 link failed" }
Write-Output ("      ok, " + (Get-Item -LiteralPath $baseApk).Length + " B")

# ---------- 4. 塞入 classes.dex ----------
Write-Output "[4/6] inject dex ..."
$packApk = Join-Path $out "packed.apk"
if (Test-Path -LiteralPath $packApk) { Remove-Item -LiteralPath $packApk -Force }
python (Join-Path $root "inject_dex.py") $baseApk $dex $packApk
if ($LASTEXITCODE -ne 0) { throw "inject failed" }

# ---------- 5. zipalign ----------
Write-Output "[5/6] zipalign ..."
$alignedApk = Join-Path $out "aligned.apk"
if (Test-Path -LiteralPath $alignedApk) { Remove-Item -LiteralPath $alignedApk -Force }
& (Join-Path $bt "zipalign.exe") -f -p 4 $packApk $alignedApk
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

# ---------- 6. sign ----------
Write-Output "[6/6] sign ..."
$ks = Join-Path $proj "wxh-release.jks"
$storePass = "wxhmodule2026"
if (-not (Test-Path -LiteralPath $ks)) {
    Write-Output "      creating keystore ..."
    & $keytool -genkeypair -v -keystore $ks -alias wxh -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass $storePass -keypass $storePass `
        -dname "CN=WXH Module, OU=WXH, O=WXH, L=Shaoguan, ST=Guangdong, C=CN" 2> "$log\keytool.err"
    if ($LASTEXITCODE -ne 0) { Get-Content "$log\keytool.err" -Tail 20; throw "keytool failed" }
}
$final = Join-Path $proj $apkName
if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force }
& (Join-Path $bt "apksigner.bat") sign --ks $ks --ks-key-alias wxh `
    --ks-pass "pass:$storePass" --key-pass "pass:$storePass" `
    --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true `
    --out $final $alignedApk 2> "$log\apksigner.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\apksigner.err" -Tail 30; throw "apksigner failed" }

& (Join-Path $bt "apksigner.bat") verify $final 2> "$log\verify.err"
if ($LASTEXITCODE -ne 0) { Get-Content "$log\verify.err" -Tail 20; throw "verify failed" }
Write-Output "      signature verified"
Write-Output ("DONE -> " + $final + "  (" + (Get-Item -LiteralPath $final).Length + " B)")
