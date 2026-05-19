# layer2-step1-api.ps1
# Phase 0 Layer 2 Step 1 — 找出指定專案或子資料夾的所有 public class 與 method
#
# 兩種執行模式：
#   Project 模式：-ModuleName "HMIWaferMap"
#     → 尋找 HMIWaferMap.csproj，掃整個 project 資料夾
#     → 輸出至 .analysis/HMIWaferMap/HMIWaferMap-api.json
#
#   Subfolder 模式：-ModulePath "HMIWaferMap/HMIWaferMapPane"
#     → 解析相對路徑，只掃該子資料夾
#     → 輸出至 .analysis/HMIWaferMap/HMIWaferMapPane/HMIWaferMapPane-api.json
#
# api.json 欄位（class）：Type, Name, File, Namespace, IsPartial, BaseClass, Interfaces
# api.json 欄位（method）：Type, Name, File, LOC

param(
  [string]$ModuleName = "",
  [string]$ModulePath = ""
)

$ErrorActionPreference = 'Stop'

if (-not $ModuleName -and -not $ModulePath) {
  Write-Error "請提供 -ModuleName 或 -ModulePath 參數"
  exit 1
}

# ── 決定掃描資料夾與輸出路徑 ────────────────────────────────────────────────

if ($ModulePath) {
  # Subfolder 模式
  $normalizedPath = $ModulePath.TrimEnd('/').TrimEnd('\')
  $scanFolder     = $normalizedPath.Replace('/', '\').Replace('\\', '\')
  $targetName     = Split-Path $scanFolder -Leaf
  $outputFolder   = ".analysis\$($scanFolder)"

  if (-not (Test-Path $scanFolder)) {
    Write-Error "找不到資料夾：$scanFolder，請確認 -ModulePath 是否正確"
    exit 1
  }
} else {
  # Project 模式
  $targetName = $ModuleName
  $proj = Get-ChildItem -Recurse -Filter "$ModuleName.csproj" |
    Where-Object { $_.Name -notmatch 'Ex\.csproj$' } |
    Select-Object -First 1

  if (-not $proj) {
    Write-Error "找不到 $ModuleName.csproj，請確認專案名稱是否正確（注意大小寫）"
    exit 1
  }

  $scanFolder   = $proj.DirectoryName
  $outputFolder = ".analysis\$ModuleName"
}

New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
Write-Host "目標名稱：$targetName"
Write-Host "掃描路徑：$scanFolder"
Write-Host "輸出資料夾：$outputFolder"

# ── 掃描 .cs 檔案 ────────────────────────────────────────────────────────────

$csFiles = Get-ChildItem -Path $scanFolder -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch '\\obj\\' -and $_.FullName -notmatch '\\bin\\' }

$skipMethods = '^(ToString|Equals|GetHashCode|GetType|MemberwiseClone|Finalize)$'

$publicApi = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $csFiles) {
  $content = Get-Content $file.FullName -Raw -Encoding UTF8

  # 提取 namespace
  $nsMatch   = [regex]::Match($content, '(?m)^\s*namespace\s+([\w.]+)')
  $namespace = if ($nsMatch.Success) { $nsMatch.Groups[1].Value } else { "" }

  # Public class
  foreach ($m in [regex]::Matches($content, 'public\s+(?:partial\s+|abstract\s+|sealed\s+|static\s+)*class\s+(\w+)(?:\s*:\s*([\w\s,<>]+))?')) {
    $className  = $m.Groups[1].Value
    $isPartial  = $m.Value -match '\bpartial\b'
    $inheritance = $m.Groups[2].Value.Trim()

    $baseClass  = ""
    $interfaces = ""
    if ($inheritance) {
      $parts = $inheritance -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
      # 第一個若不是介面（不以 I 開頭，或明確是 Form/Control 等）視為 BaseClass
      if ($parts.Count -gt 0 -and $parts[0] -notmatch '^I[A-Z]') {
        $baseClass  = $parts[0]
        $interfaces = ($parts[1..($parts.Count-1)] -join ", ")
      } else {
        $interfaces = ($parts -join ", ")
      }
    }

    $publicApi.Add([PSCustomObject]@{
      Type       = "class"
      Name       = $className
      File       = $file.Name
      Namespace  = $namespace
      IsPartial  = $isPartial
      BaseClass  = $baseClass
      Interfaces = $interfaces
      LOC        = $null
    })
  }

  # Public method（排除常見 override 方法）
  foreach ($m in [regex]::Matches($content, 'public\s+(?:static\s+|virtual\s+|override\s+|async\s+|new\s+)*(?:\w+[\[\]?<>, ]*\s+)+(\w+)\s*\(')) {
    $name = $m.Groups[1].Value
    if ($name -match $skipMethods) { continue }

    # 計算 LOC（方法本體行數：從宣告到對應的 } 結尾）
    $afterDecl = $content.IndexOf('{', $m.Index + $m.Length - 1)
    $loc = $null
    if ($afterDecl -ge 0) {
      $depth = 0
      $endIdx = $afterDecl
      for ($i = $afterDecl; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') {
          $depth--
          if ($depth -eq 0) { $endIdx = $i; break }
        }
      }
      $loc = ($content.Substring($afterDecl, $endIdx - $afterDecl + 1) -split "`n").Count
    }

    $publicApi.Add([PSCustomObject]@{
      Type       = "method"
      Name       = $name
      File       = $file.Name
      Namespace  = $namespace
      IsPartial  = $false
      BaseClass  = $null
      Interfaces = $null
      LOC        = $loc
    })
  }
}

$outputFile = "$outputFolder\$targetName-api.json"
$publicApi | ConvertTo-Json -Depth 3 |
  Out-File $outputFile -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== $targetName-api.json 產出完成 ==="
Write-Host "Public class ：$(($publicApi | Where-Object Type -eq 'class').Count) 個"
Write-Host "Public method：$(($publicApi | Where-Object Type -eq 'method').Count) 個"

$formClasses = $publicApi | Where-Object { $_.Type -eq "class" -and $_.BaseClass -match 'Form|UserControl|Panel' }
if ($formClasses.Count -gt 0) {
  Write-Host "Form/Control 類別：$($formClasses.Count) 個 → $($formClasses.Name -join ', ')"
}
