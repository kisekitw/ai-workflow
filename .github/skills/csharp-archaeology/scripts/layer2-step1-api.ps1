# layer2-step1-api.ps1
# Phase 0 Layer 2 — 找出指定專案的所有 public 方法與 class
# 用法：.\layer2-step1-api.ps1 -ModuleName "HMIWafermap"
# 輸出：docs/archaeology/tmp/[ModuleName]-api.json

param(
  [Parameter(Mandatory=$true)]
  [string]$ModuleName
)

$ErrorActionPreference = 'Stop'

$moduleProj = Get-ChildItem -Recurse -Filter "$ModuleName.csproj" |
  Where-Object { $_.Name -notmatch 'Ex\.csproj$' } |
  Select-Object -First 1

if (-not $moduleProj) {
  Write-Error "找不到 $ModuleName.csproj，請確認專案名稱是否正確"
  exit 1
}

$moduleFolder = $moduleProj.DirectoryName
Write-Host "分析專案：$ModuleName"
Write-Host "路徑：$moduleFolder"

$csFiles = Get-ChildItem -Path $moduleFolder -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch '\\obj\\' -and $_.FullName -notmatch '\\bin\\' }

$publicApi = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $csFiles) {
  $content = Get-Content $file.FullName -Raw -Encoding UTF8

  # Public class
  [regex]::Matches($content, 'public\s+(?:partial\s+|abstract\s+|sealed\s+)?class\s+(\w+)') |
    ForEach-Object {
      $publicApi.Add([PSCustomObject]@{
        類型   = "class"
        名稱   = $_.Groups[1].Value
        檔案   = $file.Name
      })
    }

  # Public method（排除 override ToString/Equals/GetHashCode 等）
  $skipMethods = '^(ToString|Equals|GetHashCode|GetType|MemberwiseClone|Finalize)$'
  [regex]::Matches($content, 'public\s+(?:static\s+|virtual\s+|override\s+|async\s+|new\s+)*(?:\w+[\[\]?<>, ]*\s+)+(\w+)\s*\(') |
    ForEach-Object {
      $name = $_.Groups[1].Value
      if ($name -notmatch $skipMethods) {
        $publicApi.Add([PSCustomObject]@{
          類型   = "method"
          名稱   = $name
          檔案   = $file.Name
        })
      }
    }
}

New-Item -ItemType Directory -Force -Path "docs/archaeology/tmp" | Out-Null
$publicApi | ConvertTo-Json |
  Out-File "docs/archaeology/tmp/$ModuleName-api.json" -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== $ModuleName-api.json 產出完成 ==="
Write-Host "Public class：$(($publicApi | Where-Object 類型 -eq 'class').Count) 個"
Write-Host "Public method：$(($publicApi | Where-Object 類型 -eq 'method').Count) 個"
