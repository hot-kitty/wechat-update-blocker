#cs
============================================================
  微信更新屏蔽工具 v1.3.0  (WeChat Update Blocker)

  用途：屏蔽微信自动更新。
        微信可能安装在非 C 盘，故自动探测安装目录，
        也支持「浏览...」手动指定。

  屏蔽动作：
    1. taskkill 结束正在运行的更新进程
    2. icacls 拒绝 Users 组执行更新程序（Read & eXecute）
    3. 锁定 xwechat 更新目录，阻止释放和替换更新器
    4. schtasks 禁用微信更新计划任务

  恢复动作：
    1. icacls /remove:d 撤销文件及目录的拒绝权限
    2. schtasks 启用微信更新计划任务

  与参考 bat 脚本的差异：
    · 计划任务用"禁用"而非"删除"，以便恢复功能可真正撤销
    · 更新程序路径由扫描得出，不硬编码 C 盘
============================================================
#ce

#RequireAdmin
#NoTrayIcon

#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <ButtonConstants.au3>
#include <EditConstants.au3>
#include <StaticConstants.au3>
#include <MsgBoxConstants.au3>
#include <Misc.au3>

; ─── 配置 ──────────────────────────────────────────────────
Global Const $APP_NAME    = "微信更新屏蔽工具"
Global Const $APP_VERSION = "1.3.0"

; 程序图标：编译后从自身 exe 资源取，开发运行时从脚本目录取
Global $g_sAppIcon = @Compiled ? @AutoItExe : @ScriptDir & "\wechat-update-blocker.ico"

; 状态图标：编译时嵌入 exe，运行时释放到临时目录（保证单文件交付）
Global Const $ICON_BLOCK = @TempDir & "\wechat-update-blocker\state-blocked.ico"
Global Const $ICON_ALLOW = @TempDir & "\wechat-update-blocker\state-allowed.ico"

DirCreate(@TempDir & "\wechat-update-blocker")
FileInstall("state-blocked.ico", $ICON_BLOCK, 1)
FileInstall("state-allowed.ico", $ICON_ALLOW, 1)

; 注意：不可命名为 $SID_USERS —— 该名字已被 SecurityConstants.au3 占用
Global Const $ACL_SID_USERS = "*S-1-5-32-545"  ; Users 组 SID（icacls 需 * 前缀）
Global Const $SCAN_DEPTH    = 2                ; 更新程序扫描递归深度

; 微信 4.x/xwechat 在此处释放插件更新器，并通过 update 目录替换程序。
Global $g_aXWeChatProtectRel[2] = [ _
        "XPlugin\Plugins\WeixinUpdate", _
        "update" ]

; 微信更新计划任务候选名
Global $g_aTasks[4] = [ _
        "\Tencent\WeChatUpdate", _
        "\Tencent\WeixinUpdate", _
        "\WeChatUpdate", _
        "\WeixinUpdate" ]

; 常见安装位置（拼接在盘符之后）
Global $g_aRelPaths[8] = [ _
        "Tencent\WeChat", _
        "Tencent\Weixin", _
        "Program Files\Tencent\WeChat", _
        "Program Files (x86)\Tencent\WeChat", _
        "Program Files\Tencent\Weixin", _
        "Program Files (x86)\Tencent\Weixin", _
        "Software\Tencent\WeChat", _
        "Apps\Tencent\WeChat" ]

; 每用户安装位置（拼接在 %LOCALAPPDATA% 之后）
Global $g_aUserPaths[2] = [ _
        "Tencent\WeChat", _
        "Programs\Tencent\WeChat" ]

; ─── 浅色主题 ──────────────────────────────────────────────
Global Const $CLR_BG     = 0xF0F0F0
Global Const $CLR_ACCENT = 0x005A9E
Global Const $CLR_HEADER = 0x0067B1
Global Const $CLR_PANEL  = 0xFFFFFF
Global Const $CLR_LINE   = 0xD9E2EA
Global Const $CLR_GREEN  = 0x107C10
Global Const $CLR_RED    = 0xC42B1C
Global Const $CLR_TEXT   = 0x202020
Global Const $CLR_GRAY   = 0x707070
Global Const $CLR_FONT   = "Microsoft YaHei UI"

; ─── GUI 控件 ──────────────────────────────────────────────
Global $hGUI = 0
Global $idRadioAllow, $idRadioBlock, $idChkTask
Global $idInpDir, $idBtnBrowse
Global $idLblUpdater, $idIconState, $idLblState
Global $idBtnApply, $idBtnRescan

; ─── 运行时状态 ────────────────────────────────────────────
Global $g_aUpdaters[0]   ; 扫描到的更新程序完整路径
Global $g_aProtectedDirs[0] ; 已存在、需锁定的 xwechat 更新目录

; ─── 单实例 ────────────────────────────────────────────────
If _Singleton("WeChatUpdateBlocker_Singleton", 1) = 0 Then Exit

_CreateGUI()
_Rescan()

While 1
    Local $nMsg = GUIGetMsg()
    Switch $nMsg
        Case $GUI_EVENT_CLOSE
            GUIDelete($hGUI)
            Exit

        Case $idBtnBrowse
            Local $sDir = FileSelectFolder("选择微信安装目录（含 WeChat.exe / Weixin.exe 的目录）", "", 1)
            If Not @error And $sDir <> "" Then
                GUICtrlSetData($idInpDir, $sDir)
                _Rescan($sDir)
            EndIf

        Case $idBtnRescan
            _Rescan()

        Case $idBtnApply
            _DoApply()
    EndSwitch
WEnd

; ============================================================
;  GUI
; ============================================================
Func _CreateGUI()
    ; 440 × 440 的正方形窗口：信息区、操作区和底部按钮形成稳定的三段布局。
    $hGUI = GUICreate($APP_NAME & " v" & $APP_VERSION, 440, 440, -1, -1)
    GUISetBkColor($CLR_BG)
    GUISetFont(9, 400, 0, $CLR_FONT)
    If FileExists($g_sAppIcon) Then GUISetIcon($g_sAppIcon)

    ; ── 顶部品牌与状态 ──
    GUICtrlCreateLabel("", 0, 0, 440, 94)
    GUICtrlSetBkColor(-1, $CLR_HEADER)
    $idIconState = GUICtrlCreateIcon($ICON_ALLOW, -1, 24, 24, 40, 40)

    GUICtrlCreateLabel($APP_NAME, 80, 20, 290, 24)
    GUICtrlSetFont(-1, 14, 700, 0, $CLR_FONT)
    GUICtrlSetColor(-1, 0xFFFFFF)
    GUICtrlSetBkColor(-1, $CLR_HEADER)

    $idLblState = GUICtrlCreateLabel("检测中...", 82, 49, 310, 20)
    GUICtrlSetFont($idLblState, 9, 400, 0, $CLR_FONT)
    GUICtrlSetColor($idLblState, 0xDCEEFF)
    GUICtrlSetBkColor($idLblState, $CLR_HEADER)

    ; ── 更新策略卡片 ──
    GUICtrlCreateLabel("更新策略", 20, 112, 160, 18)
    GUICtrlSetFont(-1, 9, 700, 0, $CLR_FONT)
    GUICtrlSetColor(-1, $CLR_ACCENT)
    GUICtrlCreateLabel("", 20, 136, 400, 54)
    GUICtrlSetBkColor(-1, $CLR_PANEL)

    $idRadioAllow = GUICtrlCreateRadio("允许更新", 40, 153, 88, 20)
    GUICtrlSetColor($idRadioAllow, $CLR_TEXT)
    GUICtrlSetBkColor($idRadioAllow, $CLR_PANEL)

    $idRadioBlock = GUICtrlCreateRadio("屏蔽更新", 145, 153, 88, 20)
    GUICtrlSetColor($idRadioBlock, $CLR_TEXT)
    GUICtrlSetBkColor($idRadioBlock, $CLR_PANEL)
    GUICtrlSetState($idRadioBlock, $GUI_CHECKED)

    $idChkTask = GUICtrlCreateCheckbox("禁用更新计划任务", 250, 153, 144, 20)
    GUICtrlSetColor($idChkTask, $CLR_TEXT)
    GUICtrlSetBkColor($idChkTask, $CLR_PANEL)
    GUICtrlSetState($idChkTask, $GUI_CHECKED)

    ; ── 安装目录 ──
    GUICtrlCreateLabel("微信安装目录", 20, 210, 200, 18)
    GUICtrlSetFont(-1, 9, 700, 0, $CLR_FONT)
    GUICtrlSetColor(-1, $CLR_ACCENT)

    $idInpDir = GUICtrlCreateInput("", 20, 235, 302, 28)
    GUICtrlSetFont($idInpDir, 9, 400, 0, $CLR_FONT)
    GUICtrlSetBkColor($idInpDir, $CLR_PANEL)

    $idBtnBrowse = GUICtrlCreateButton("浏览...", 332, 235, 88, 28)

    ; ── 防护对象 ──
    GUICtrlCreateLabel("已检测到的防护对象", 20, 284, 240, 18)
    GUICtrlSetFont(-1, 9, 700, 0, $CLR_FONT)
    GUICtrlSetColor(-1, $CLR_ACCENT)

    $idLblUpdater = GUICtrlCreateLabel("", 20, 309, 400, 68)
    GUICtrlSetFont($idLblUpdater, 8, 400, 0, $CLR_FONT)
    GUICtrlSetColor($idLblUpdater, $CLR_TEXT)
    GUICtrlSetBkColor($idLblUpdater, $CLR_PANEL)

    ; ── 底部操作（整体居中） ──
    $idBtnApply = GUICtrlCreateButton("应用设置", 84, 396, 130, 30)
    GUICtrlSetFont($idBtnApply, 9, 700, 0, $CLR_FONT)

    $idBtnRescan = GUICtrlCreateButton("重新检测", 226, 396, 130, 30)

    GUISetState(@SW_SHOW, $hGUI)
EndFunc

; ============================================================
;  扫描
; ============================================================
; 扫描指定目录；未指定时用输入框内容，仍为空则自动探测
Func _Rescan($sDirExplicit = "")
    Local $sInput = ($sDirExplicit <> "") ? $sDirExplicit : GUICtrlRead($idInpDir)

    Local $aScanDirs[0]
    If $sInput <> "" And FileExists($sInput) Then
        _AddUnique($aScanDirs, $sInput)
    EndIf

    If UBound($aScanDirs) = 0 Then
        Local $aDirs = _DetectDirs()
        For $i = 0 To UBound($aDirs) - 1
            _AddUnique($aScanDirs, $aDirs[$i])
        Next
        If UBound($aScanDirs) > 0 Then GUICtrlSetData($idInpDir, $aScanDirs[0])
    EndIf

    ReDim $g_aUpdaters[0]
    ReDim $g_aProtectedDirs[0]
    For $i = 0 To UBound($aScanDirs) - 1
        Local $aHits[0]
        _FindUpdaters($aScanDirs[$i], 0, $aHits)
        For $j = 0 To UBound($aHits) - 1
            _AddUnique($g_aUpdaters, $aHits[$j])
        Next
    Next

    ; 此路径位于 %APPDATA%（Roaming），不会由安装目录扫描覆盖。
    Local $sXWeChatRoot = @AppDataDir & "\Tencent\xwechat"
    For $i = 0 To UBound($g_aXWeChatProtectRel) - 1
        Local $sProtectDir = $sXWeChatRoot & "\" & $g_aXWeChatProtectRel[$i]
        If FileExists($sProtectDir) Then
            _AddUnique($g_aProtectedDirs, $sProtectDir)
            Local $aXHits[0]
            _FindUpdaters($sProtectDir, 0, $aXHits)
            For $j = 0 To UBound($aXHits) - 1
                _AddUnique($g_aUpdaters, $aXHits[$j])
            Next
        EndIf
    Next

    _RefreshUI()
EndFunc

; 返回候选微信安装目录（去重，仅保留含主程序的）
Func _DetectDirs()
    Local $aFound[0]

    ; 1) 注册表
    Local $aKeys[6][2] = [ _
            ["HKLM\SOFTWARE\WOW6432Node\Tencent\WeChat", "InstallPath"], _
            ["HKLM\SOFTWARE\WOW6432Node\Tencent\WeChat", "InstallDir"], _
            ["HKLM\SOFTWARE\Tencent\WeChat", "InstallPath"], _
            ["HKLM\SOFTWARE\Tencent\WeChat", "InstallDir"], _
            ["HKCU\Software\Tencent\WeChat", "InstallPath"], _
            ["HKCU\Software\Tencent\Weixin", "InstallPath"] ]

    For $i = 0 To UBound($aKeys) - 1
        Local $sVal = RegRead($aKeys[$i][0], $aKeys[$i][1])
        If Not @error And $sVal <> "" Then
            $sVal = StringReplace($sVal, '"', '')
            If StringRight($sVal, 1) = "\" Then $sVal = StringLeft($sVal, StringLen($sVal) - 1)
            _AddUnique($aFound, $sVal)
        EndIf
    Next

    ; 2) 各固定盘符下的常见路径
    Local $aDrives = DriveGetDrive("FIXED")
    If Not @error Then
        For $d = 1 To $aDrives[0]
            For $p = 0 To UBound($g_aRelPaths) - 1
                _AddUnique($aFound, $aDrives[$d] & "\" & $g_aRelPaths[$p])
            Next
        Next
    EndIf

    ; 3) 每用户安装
    For $i = 0 To UBound($g_aUserPaths) - 1
        _AddUnique($aFound, @LocalAppDataDir & "\" & $g_aUserPaths[$i])
    Next

    ; 4) 只保留存在微信主程序的目录
    Local $aRet[0]
    For $i = 0 To UBound($aFound) - 1
        If FileExists($aFound[$i] & "\WeChat.exe") Or FileExists($aFound[$i] & "\Weixin.exe") Then
            _AddUnique($aRet, $aFound[$i])
        EndIf
    Next

    Return $aRet
EndFunc

; 递归查找文件名含 "update" 的 exe
Func _FindUpdaters($sDir, $iDepth, ByRef $aHits)
    Local $hSearch = FileFindFirstFile($sDir & "\*")
    If $hSearch = -1 Then Return

    While 1
        Local $sName = FileFindNextFile($hSearch)
        If @error Then ExitLoop
        Local $sFull = $sDir & "\" & $sName

        If @extended Then
            ; 子目录
            If $iDepth < $SCAN_DEPTH Then _FindUpdaters($sFull, $iDepth + 1, $aHits)
        Else
            If StringRight(StringLower($sName), 4) = ".exe" _
                    And StringInStr(StringLower($sName), "update") > 0 Then
                Local $n = UBound($aHits)
                ReDim $aHits[$n + 1]
                $aHits[$n] = $sFull
            EndIf
        EndIf
    WEnd
    FileClose($hSearch)
EndFunc

; ============================================================
;  界面刷新
; ============================================================
Func _RefreshUI()
    ; 更新程序路径文字
    If UBound($g_aUpdaters) = 0 And UBound($g_aProtectedDirs) = 0 Then
        GUICtrlSetData($idLblUpdater, "未扫描到更新程序" & @CRLF & _
                "请点「浏览...」指定微信安装目录")
        GUICtrlSetColor($idLblUpdater, $CLR_GRAY)
    Else
        Local $sText = ""
        For $i = 0 To UBound($g_aUpdaters) - 1
            $sText &= $g_aUpdaters[$i] & @CRLF
        Next
        For $i = 0 To UBound($g_aProtectedDirs) - 1
            $sText &= "锁定目录: " & $g_aProtectedDirs[$i] & @CRLF
        Next
        GUICtrlSetData($idLblUpdater, StringTrimRight($sText, 2))
        GUICtrlSetColor($idLblUpdater, $CLR_TEXT)
    EndIf

    _RefreshState()
EndFunc

Func _RefreshState()
    If UBound($g_aUpdaters) = 0 And UBound($g_aProtectedDirs) = 0 Then
        GUICtrlSetImage($idIconState, $ICON_ALLOW, -1)
        GUICtrlSetData($idLblState, "未找到微信更新程序")
        GUICtrlSetColor($idLblState, 0xDCEEFF)
        Return
    EndIf

    Local $bBlocked = False
    For $i = 0 To UBound($g_aUpdaters) - 1
        If _IsBlocked($g_aUpdaters[$i]) Then
            $bBlocked = True
            ExitLoop
        EndIf
    Next
    If Not $bBlocked Then
        For $i = 0 To UBound($g_aProtectedDirs) - 1
            If _IsBlocked($g_aProtectedDirs[$i]) Then
                $bBlocked = True
                ExitLoop
            EndIf
        Next
    EndIf

    If $bBlocked Then
        GUICtrlSetImage($idIconState, $ICON_BLOCK, -1)
        GUICtrlSetData($idLblState, "自动更新已屏蔽")
        GUICtrlSetColor($idLblState, 0xFFE2E2)
        GUICtrlSetState($idRadioBlock, $GUI_CHECKED)
    Else
        GUICtrlSetImage($idIconState, $ICON_ALLOW, -1)
        GUICtrlSetData($idLblState, "自动更新已启用")
        GUICtrlSetColor($idLblState, 0xD8F5D8)
        GUICtrlSetState($idRadioAllow, $GUI_CHECKED)
    EndIf
EndFunc

; 读取 ACL 判断该文件是否已被拒绝执行
Func _IsBlocked($sPath)
    If Not FileExists($sPath) Then Return False
    Local $sOut = _RunCapture('icacls "' & $sPath & '"')
    Return StringInStr($sOut, "(DENY)") > 0
EndFunc

; ============================================================
;  应用（屏蔽 / 恢复）
; ============================================================
Func _DoApply()
    Local $bBlock = (GUICtrlRead($idRadioBlock) = $GUI_CHECKED)
    Local $bTask = (GUICtrlRead($idChkTask) = $GUI_CHECKED)

    ; 即使更新目录尚未被微信创建，也预先建立并锁定它，避免首次释放绕过防护。
    If $bBlock Then _PrepareXWeChatDirs()

    If UBound($g_aUpdaters) = 0 And UBound($g_aProtectedDirs) = 0 Then
        MsgBox($MB_ICONWARNING, $APP_NAME, _
                "未找到微信更新程序。" & @CRLF & @CRLF & _
                "请点「浏览...」指定微信安装目录后重试。")
        Return
    EndIf

    Local $sList = ""
    For $i = 0 To UBound($g_aUpdaters) - 1
        $sList &= "  " & $g_aUpdaters[$i] & @CRLF
    Next
    For $i = 0 To UBound($g_aProtectedDirs) - 1
        $sList &= "  [锁定目录] " & $g_aProtectedDirs[$i] & @CRLF
    Next

    Local $sMsg
    If $bBlock Then
        $sMsg = "即将屏蔽更新程序及更新目录：" & @CRLF & @CRLF & $sList & @CRLF & _
                "执行内容：" & @CRLF & _
                "  1. 结束正在运行的更新进程" & @CRLF & _
                "  2. 拒绝 Users 组执行上述文件" & @CRLF & _
                "  3. 锁定 xwechat 更新目录，阻止释放和替换" & @CRLF & _
                ($bTask ? "  4. 禁用微信更新计划任务" : "  4. （计划任务保持不变）") & @CRLF & @CRLF & _
                "此操作会阻止微信自动更新，之后可用「允许更新」还原。" & @CRLF & @CRLF & "确认继续？"
    Else
        $sMsg = "即将恢复以下 " & UBound($g_aUpdaters) & " 个更新程序：" & @CRLF & @CRLF & $sList & @CRLF & _
                "执行内容：" & @CRLF & _
                "  1. 撤销文件及目录的拒绝权限" & @CRLF & _
                ($bTask ? "  2. 启用微信更新计划任务" : "  2. （计划任务保持不变）") & @CRLF & @CRLF & _
                "确认继续？"
    EndIf

    Local $sTitle = $bBlock ? "确认屏蔽" : "确认恢复"
    If MsgBox($MB_ICONWARNING + $MB_YESNO, $sTitle, $sMsg) <> $IDYES Then Return

    GUICtrlSetState($idBtnApply, $GUI_DISABLE)
    GUICtrlSetState($idBtnRescan, $GUI_DISABLE)

    Local $iOk = 0, $iFail = 0, $sDetail = ""

    If $bBlock Then
        ; 1) 结束进程
        Local $aNames[0]
        For $i = 0 To UBound($g_aUpdaters) - 1
            _AddUnique($aNames, _BaseName($g_aUpdaters[$i]))
        Next
        For $i = 0 To UBound($aNames) - 1
            Local $aProc = ProcessList($aNames[$i])
            If $aProc[0][0] > 0 Then
                RunWait(@ComSpec & ' /c taskkill /f /im "' & $aNames[$i] & '" >nul 2>&1', "", @SW_HIDE)
                $sDetail &= "已结束进程: " & $aNames[$i] & @CRLF
            EndIf
        Next

        ; 2) 拒绝执行权限
        For $i = 0 To UBound($g_aUpdaters) - 1
            If _SetAclDeny($g_aUpdaters[$i], True) Then
                $iOk += 1
            Else
                $iFail += 1
                $sDetail &= "失败: " & $g_aUpdaters[$i] & @CRLF
            EndIf
        Next

        ; 可继承目录 ACL 会覆盖今后新释放的 WeixinUpdate.exe。
        For $i = 0 To UBound($g_aProtectedDirs) - 1
            If _SetDirAclDeny($g_aProtectedDirs[$i], True) Then
                $iOk += 1
            Else
                $iFail += 1
                $sDetail &= "目录锁定失败: " & $g_aProtectedDirs[$i] & @CRLF
            EndIf
        Next

        ; 3) 计划任务
        If $bTask Then $sDetail &= _TaskDetail(False)
    Else
        For $i = 0 To UBound($g_aUpdaters) - 1
            If _SetAclDeny($g_aUpdaters[$i], False) Then
                $iOk += 1
            Else
                $iFail += 1
                $sDetail &= "失败: " & $g_aUpdaters[$i] & @CRLF
            EndIf
        Next

        For $i = 0 To UBound($g_aProtectedDirs) - 1
            If _SetDirAclDeny($g_aProtectedDirs[$i], False) Then
                $iOk += 1
            Else
                $iFail += 1
                $sDetail &= "目录恢复失败: " & $g_aProtectedDirs[$i] & @CRLF
            EndIf
        Next

        If $bTask Then $sDetail &= _TaskDetail(True)
    EndIf

    GUICtrlSetState($idBtnApply, $GUI_ENABLE)
    GUICtrlSetState($idBtnRescan, $GUI_ENABLE)

    Local $sResult = ($bBlock ? "屏蔽" : "恢复") & "完成：" & $iOk & " 个成功"
    If $iFail > 0 Then $sResult &= "，" & $iFail & " 个失败"

    MsgBox($iFail > 0 ? $MB_ICONWARNING : $MB_ICONINFORMATION, $APP_NAME, _
            $sResult & @CRLF & @CRLF & $sDetail)

    _RefreshUI()
EndFunc

; 屏蔽时预创建微信将使用的目录。仅在 xwechat 已存在时操作，不会创建 Tencent/xwechat 根目录。
Func _PrepareXWeChatDirs()
    Local $sXWeChatRoot = @AppDataDir & "\Tencent\xwechat"
    If Not FileExists($sXWeChatRoot) Then Return

    For $i = 0 To UBound($g_aXWeChatProtectRel) - 1
        Local $sProtectDir = $sXWeChatRoot & "\" & $g_aXWeChatProtectRel[$i]
        If Not FileExists($sProtectDir) Then DirCreate($sProtectDir)
        If FileExists($sProtectDir) Then _AddUnique($g_aProtectedDirs, $sProtectDir)
    Next
EndFunc

; ============================================================
;  系统操作
; ============================================================
; 设置 / 撤销 Users 组对指定文件的拒绝执行权限
Func _SetAclDeny($sPath, $bDeny)
    If $bDeny Then
        ; 先清掉同 SID 的既有拒绝项，保证重复执行幂等
        RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /remove:d ' & $ACL_SID_USERS & ' >nul 2>&1', "", @SW_HIDE)
        Local $iRet = RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /deny ' & $ACL_SID_USERS & ':(RX) >nul 2>&1', _
                "", @SW_HIDE)
        Return $iRet = 0
    Else
        Local $iRet = RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /remove:d ' & $ACL_SID_USERS & ' >nul 2>&1', _
                "", @SW_HIDE)
        Return $iRet = 0
    EndIf
EndFunc

; 锁定目录及子项：RX 阻止执行，WD/AD/DC/WA/WEA 阻止写入、新建、删除、覆盖。
; OI/CI 使规则自动继承到未来由微信释放的新文件。
Func _SetDirAclDeny($sPath, $bDeny)
    If $bDeny Then
        RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /remove:d ' & $ACL_SID_USERS & ' /t /c >nul 2>&1', "", @SW_HIDE)
        Local $iRet = RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /deny ' & $ACL_SID_USERS & _
                ':(OI)(CI)(RX,WD,AD,DC,WA,WEA) /c >nul 2>&1', "", @SW_HIDE)
        Return $iRet = 0
    Else
        Local $iRet = RunWait(@ComSpec & ' /c icacls "' & $sPath & '" /remove:d ' & $ACL_SID_USERS & ' /t /c >nul 2>&1', _
                "", @SW_HIDE)
        Return $iRet = 0
    EndIf
EndFunc

; 启用 / 禁用微信更新计划任务，返回可读的结果说明
Func _TaskDetail($bEnable)
    Local $sFlag = $bEnable ? "/enable" : "/disable"
    Local $sVerb = $bEnable ? "启用" : "禁用"
    Local $sRet = ""

    For $i = 0 To UBound($g_aTasks) - 1
        If _TaskExists($g_aTasks[$i]) Then
            Local $iRet = RunWait(@ComSpec & ' /c schtasks /change /tn "' & $g_aTasks[$i] & '" ' & _
                    $sFlag & ' >nul 2>&1', "", @SW_HIDE)
            If $iRet = 0 Then
                $sRet &= "已" & $sVerb & "任务: " & $g_aTasks[$i] & @CRLF
            Else
                $sRet &= "任务操作失败: " & $g_aTasks[$i] & @CRLF
            EndIf
        EndIf
    Next

    If $sRet = "" Then $sRet = "未发现微信更新计划任务（已跳过）" & @CRLF
    Return $sRet
EndFunc

Func _TaskExists($sTask)
    Return RunWait(@ComSpec & ' /c schtasks /query /tn "' & $sTask & '" >nul 2>&1', "", @SW_HIDE) = 0
EndFunc

; ============================================================
;  工具函数
; ============================================================
Func _RunCapture($sCmd)
    Local $iPID = Run(@ComSpec & " /c " & $sCmd, "", @SW_HIDE, $STDOUT_CHILD + $STDERR_CHILD)
    If $iPID = 0 Then Return ""

    Local $sOut = ""
    While 1
        Local $sChunk = StdoutRead($iPID)
        If @error Then ExitLoop
        $sOut &= $sChunk
    WEnd
    Return $sOut
EndFunc

Func _AddUnique(ByRef $aArr, $sVal)
    If $sVal = "" Then Return
    For $i = 0 To UBound($aArr) - 1
        If $aArr[$i] = $sVal Then Return
    Next
    Local $n = UBound($aArr)
    ReDim $aArr[$n + 1]
    $aArr[$n] = $sVal
EndFunc

Func _BaseName($sPath)
    Local $i = StringInStr($sPath, "\", 0, -1)
    Return $i ? StringMid($sPath, $i + 1) : $sPath
EndFunc
