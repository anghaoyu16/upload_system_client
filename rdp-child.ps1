param(
    [int]$Width = 0,
    [int]$Height = 0,
    [string]$Title = ""
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'rdp-child.log'
$cmdPath = Join-Path $PSScriptRoot 'rdp-child.cmd'
$iconPath = Join-Path $PSScriptRoot 'icon_rdp.ico'

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.CSharp

$rdpCode = @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Drawing;
using System.IO;
using System.Diagnostics;
using System.Drawing.Drawing2D;

[ComImport]
[Guid("302D8188-0052-4807-806A-362B628F9AC5")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMsRdpExtendedSettings
{
    void put_Property([MarshalAs(UnmanagedType.BStr)] string name, [MarshalAs(UnmanagedType.Struct)] object value);
    object get_Property([MarshalAs(UnmanagedType.BStr)] string name);
}

[ComImport]
[Guid("2F079C4C-87B2-4AFD-97AB-20CDB43038AE")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMsRdpClientNonScriptable
{
    void put_ClearTextPassword([MarshalAs(UnmanagedType.BStr)] string value);
    void put_PortablePassword([MarshalAs(UnmanagedType.BStr)] string value);
    [return: MarshalAs(UnmanagedType.BStr)] string get_PortablePassword();
    void put_PortableSalt([MarshalAs(UnmanagedType.BStr)] string value);
    [return: MarshalAs(UnmanagedType.BStr)] string get_PortableSalt();
    void put_BinaryPassword([MarshalAs(UnmanagedType.BStr)] string value);
    [return: MarshalAs(UnmanagedType.BStr)] string get_BinaryPassword();
    void put_BinarySalt([MarshalAs(UnmanagedType.BStr)] string value);
    [return: MarshalAs(UnmanagedType.BStr)] string get_BinarySalt();
    void ResetPassword();
    void NotifyRedirectDeviceChange(IntPtr wParam, IntPtr lParam);
    void SendKeys(int numKeys, ref short keyUpStates, ref int keyData);
}

[ComImport]
[Guid("00000114-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IOleWindow
{
    [PreserveSig] int GetWindow(out IntPtr phwnd);
    [PreserveSig] int ContextSensitiveHelp(int fEnterMode);
}

public class AxMsRdpClient10 : AxHost
{
    public AxMsRdpClient10() : base("A0C63C30-F08D-4AB4-907C-34905D770C7D") { }
}

public class RdpForm : Form
{
    const int WM_NCCALCSIZE = 0x0083;
    const int WM_NCHITTEST = 0x0084;
    const int WM_NCPAINT = 0x0085;
    const int WM_NCACTIVATE = 0x0086;
    const int WM_NCUAHDRAWCAPTION = 0x00AE;
    const int WM_NCUAHDRAWFRAME = 0x00AF;
    const int HTCLIENT = 1;
    const int HTCAPTION = 2;
    const int BarH = 34;
    const int HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14;
    const int HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
    const int Grabs = 8;
    const int WM_NCLBUTTONDBLCLK = 0x00A3;
    const int WM_HOTKEY = 0x0312;
    const int MOD_ALT = 0x0001;
    const int MOD_NOREPEAT = 0x4000;
    const int HOTKEY_ID_FULL = 1;

    public static Action HotKeyFullScreen = null;
    public static Action ToggleMaximizeAction = null;
    public static bool IsMaximized = false;

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const int WH_KEYBOARD_LL = 13;
    const uint LLKHF_EXTENDED = 0x01;
    const uint LLKHF_INJECTED = 0x10;
    const uint LLKHF_ALTDOWN = 0x20;
    const uint LLKHF_UP = 0x80;
    const uint VK_F7 = 0x76;
    const uint VK_RETURN = 0x0D;
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP = 0x0101;
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_SCANCODE = 0x0008;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    static IntPtr _hook = IntPtr.Zero;
    static LowLevelKeyboardProc _hookProc;

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        RegisterHotKey(this.Handle, HOTKEY_ID_FULL, MOD_NOREPEAT, 0x76);              // F7
        if (_hook == IntPtr.Zero)
        {
            _hookProc = HookProc;
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, IntPtr.Zero, 0);
            if (_hook != IntPtr.Zero) RdpWindow.Log("KeyboardLL hook installed");
            else RdpWindow.Log("KeyboardLL hook install failed err=" + Marshal.GetLastWin32Error());
        }
    }
    protected override void OnHandleDestroyed(EventArgs e)
    {
        UnregisterHotKey(this.Handle, HOTKEY_ID_FULL);
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
        base.OnHandleDestroyed(e);
    }

    static IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            KBDLLHOOKSTRUCT kbd = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool injected = (kbd.flags & LLKHF_INJECTED) != 0;
            bool isF7 = kbd.vkCode == VK_F7;
            if (isF7 && !injected && (kbd.flags & LLKHF_UP) == 0)
            {
                RdpWindow.Log("F7 hook invoke fullscreen toggle");
                if (HotKeyFullScreen != null) HotKeyFullScreen();
                return new IntPtr(1);
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public static void ReinstallHook()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        _hookProc = HookProc;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, IntPtr.Zero, 0);
        RdpWindow.Log(_hook != IntPtr.Zero
            ? "KeyboardLL hook re-installed to head of chain (after KeyboardHookMode=1)"
            : "KeyboardLL hook re-install failed err=" + Marshal.GetLastWin32Error());
    }

    bool HookActive()
    {
        return this.Visible && (this.ContainsFocus || this.Focused);
    }

    public static object RdpObjectRef = null;

    bool IsSystemComboKey(uint vk, uint flags)
    {
        bool altDown = (flags & LLKHF_ALTDOWN) != 0;
        bool ctrlDown = (GetAsyncKeyState(0x11) & 0x8000) != 0;
        if (vk == 0x5B || vk == 0x5C) { RdpWindow.Log("SystemCombo: Win vk=" + vk); return true; }
        if (vk == 0x09) { return altDown; }
        if (vk == 0x1B) { if (ctrlDown || altDown) { RdpWindow.Log("SystemCombo: Esc vk=" + vk); return true; } return false; }
        if (vk == 0x20 && altDown) return true;
        if (vk == 0x73 && altDown) return true;
        if (vk == 0x5D) { RdpWindow.Log("SystemCombo: Apps"); return true; }
        return false;
    }

    INPUT MakeInput(KBDLLHOOKSTRUCT kbd)
    {
        INPUT inp = new INPUT();
        inp.type = INPUT_KEYBOARD;
        inp.U.ki.wVk = (ushort)kbd.vkCode;
        inp.U.ki.wScan = (ushort)kbd.scanCode;
        inp.U.ki.dwFlags = KEYEVENTF_SCANCODE;
        if ((kbd.flags & LLKHF_EXTENDED) != 0) inp.U.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
        if ((kbd.flags & LLKHF_UP) != 0) inp.U.ki.dwFlags |= KEYEVENTF_KEYUP;
        return inp;
    }

    public static IMsRdpClientNonScriptable NonScriptable = null;
    public static IntPtr RdpHwnd = IntPtr.Zero;

    public static bool SendKeyRaw(KBDLLHOOKSTRUCT kbd)
    {
        if (NonScriptable == null) { RdpWindow.Log("SendKeyRaw: NonScriptable null"); return false; }
        short[] keyUpStates = new short[1];
        int[] keyData = new int[1];
        keyUpStates[0] = ((kbd.flags & LLKHF_UP) != 0) ? (short)-1 : (short)0;
        keyData[0] = (int)kbd.scanCode | (((kbd.flags & LLKHF_EXTENDED) != 0) ? 0x0100 : 0);
        try { NonScriptable.SendKeys(1, ref keyUpStates[0], ref keyData[0]); return true; }
        catch (Exception ex) { RdpWindow.Log("SendKeys vk=" + kbd.vkCode + " ex: " + ex.Message); return false; }
    }

    public static bool SendCtrlAltEnd()
    {
        if (NonScriptable == null) { RdpWindow.Log("SendCtrlAltEnd: NonScriptable null"); return false; }
        short[] keyUpStates = { 0, 0, 0, -1, -1, -1 };
        int[] keyData = { 0x1D, 0x38, 0x4F | 0x0100, 0x4F | 0x0100, 0x38, 0x1D };
        try { NonScriptable.SendKeys(6, ref keyUpStates[0], ref keyData[0]); return true; }
        catch (Exception ex) { RdpWindow.Log("SendCtrlAltEnd ex: " + ex.Message); return false; }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY) { if (HotKeyFullScreen != null) HotKeyFullScreen(); return; }
        if (m.Msg == WM_NCCALCSIZE)
        {
            if (m.WParam != IntPtr.Zero) m.Result = IntPtr.Zero;
            return;
        }
        else if (m.Msg == WM_NCPAINT || m.Msg == WM_NCUAHDRAWCAPTION || m.Msg == WM_NCUAHDRAWFRAME)
        {
            return;
        }
        else if (m.Msg == WM_NCACTIVATE)
        {
            m.Result = new IntPtr(1);
            return;
        }
        else if (m.Msg == WM_NCLBUTTONDBLCLK)
        {
            if (ToggleMaximizeAction != null) ToggleMaximizeAction();
            return;
        }
        else if (m.Msg == WM_NCHITTEST)
        {
            bool maximizedOrFull = this.WindowState == FormWindowState.Maximized ||
                this.Width >= Screen.PrimaryScreen.Bounds.Width || IsMaximized;
            int lp = m.LParam.ToInt32();
            int x = (short)(lp & 0xFFFF);
            int y = (short)((lp >> 16) & 0xFFFF);
            Point c = PointToClient(new Point(x, y));
            int w = ClientSize.Width, h = ClientSize.Height;
            int res = 0;
            if (!maximizedOrFull)
            {
                bool left = c.X < Grabs, right = c.X > w - Grabs;
                bool top = c.Y < Grabs, bottom = c.Y > h - Grabs;
                if (left && top) res = HTTOPLEFT;
                else if (right && top) res = HTTOPRIGHT;
                else if (left && bottom) res = HTBOTTOMLEFT;
                else if (right && bottom) res = HTBOTTOMRIGHT;
                else if (left) res = HTLEFT;
                else if (right) res = HTRIGHT;
                else if (top) res = HTTOP;
                else if (bottom) res = HTBOTTOM;
            }
            if (res != 0) m.Result = new IntPtr(res);
            else if (c.Y < BarH) m.Result = new IntPtr(HTCAPTION);
            else m.Result = new IntPtr(HTCLIENT);
            return;
        }
        base.WndProc(ref m);
    }
}

public class TransparentHost : Panel
{
    const int WM_NCHITTEST = 0x0084;
    const int HTTRANSPARENT = -1;
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCHITTEST) { m.Result = new IntPtr(HTTRANSPARENT); return; }
        base.WndProc(ref m);
    }
}

public class CaptionBar : Label
{
    public Form OwnerForm;
    const int WM_NCHITTEST = 0x0084;
    const int HTTRANSPARENT = -1;
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCHITTEST) { m.Result = new IntPtr(HTTRANSPARENT); return; }
        base.WndProc(ref m);
    }
}

public class RdpWindow
{
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSGetChildSessionId(out uint pSessionId);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSLogoffSession(IntPtr hServer, uint sessionId, bool bWait);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSChangeChildSessionDisplaySettings(IntPtr hServer, uint pSessionId, uint pX, uint pY);
    [DllImport("user32.dll")]
    static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref int pvAttribute, int cbAttribute);
    const int GWL_STYLE = -16;
    const int WS_CAPTION = 0x00C00000;
    const int WS_THICKFRAME = 0x00040000;
    const int WS_MAXIMIZEBOX = 0x00010000;
    const int WM_NCLBUTTONDOWN = 0x00A1;
    const int HTCAPTION = 0x0002;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    const int DWMWCP_ROUND = 2;
    const string DEFAULT_TITLE = "\u4F5C\u4E1A\u4E0A\u4F20\u7CFB\u7EDF-\u684C\u9762\u5206\u8EAB";
    const string UPLOAD_URL = "http://localhost/";
    const string ICON_MIN = "\uE921", ICON_MAX = "\uE922", ICON_RESTORE = "\uE923", ICON_CLOSE = "\uE8BB", ICON_FULL = "\uE740";

    public static string LogPath = "";
    public static string CmdFilePath = "";
    public static string IconPath = "";
    static System.Windows.Forms.Timer CmdTimer = null;
    static System.Windows.Forms.Timer ConnectTimer = null;
    static System.Windows.Forms.Timer DebounceTimer = null;
    static string LastCmd = "";
    static Form MainForm = null;
    static AxMsRdpClient10 Rdp = null;
    static object RdpObject = null;
    static Panel HostPanel = null;
    static Panel TitleBar = null;
    static CaptionBar TitleLabel = null;
    static Button btnMax = null;
    static Button btnFull = null;
    static Button btnTop = null;
    static Form BlackScreen = null;

    static int baseW, baseH;
    static int MinW = 400, MinH = 300;
    static int connectElapsed = 0;
    static bool hookReorderDone = false;
    static bool isFullScreen = false;
    static Rectangle prevBounds;
    static FormWindowState prevState;
    static bool prevTopMost;
    static bool isMaximized = false;
    static Rectangle maxPrevBounds;

    public static void Log(string msg)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg;
        try { System.IO.File.AppendAllText(LogPath, line + "\r\n"); }
        catch { }
    }

    static int ResizeHitTest(Point screenPt)
    {
        if (MainForm == null || MainForm.WindowState == FormWindowState.Maximized || isFullScreen) return 0;
        Point c = MainForm.PointToClient(screenPt);
        int w = MainForm.ClientSize.Width, h = MainForm.ClientSize.Height;
        bool l = c.X < 8, r = c.X > w - 8, t = c.Y < 8, b = c.Y > h - 8;
        if (l && t) return 13; if (r && t) return 14; if (l && b) return 16; if (r && b) return 17;
        if (l) return 10; if (r) return 11; if (t) return 12; if (b) return 15;
        return 0;
    }
    static Cursor CursorForHit(int ht)
    {
        switch (ht)
        {
            case 10: case 11: return Cursors.SizeWE;
            case 12: case 15: return Cursors.SizeNS;
            case 13: case 17: return Cursors.SizeNWSE;
            case 14: case 16: return Cursors.SizeNESW;
        }
        return Cursors.Default;
    }
    static void AttachResize(Control ctrl)
    {
        ctrl.MouseMove += delegate(object s, MouseEventArgs e) { ctrl.Cursor = CursorForHit(ResizeHitTest(ctrl.PointToScreen(e.Location))); };
        ctrl.MouseDown += delegate(object s, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            int ht = ResizeHitTest(ctrl.PointToScreen(e.Location));
            if (ht != 0) { ReleaseCapture(); SendMessage(MainForm.Handle, WM_NCLBUTTONDOWN, ht, 0); }
        };
    }
    static void AttachTitleInteraction(Control ctrl)
    {
        AttachResize(ctrl);
        ctrl.MouseDown += delegate(object s, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left || MainForm.WindowState == FormWindowState.Maximized || isFullScreen) return;
            if (ResizeHitTest(ctrl.PointToScreen(e.Location)) == 0)
            { ReleaseCapture(); SendMessage(MainForm.Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0); }
        };
        ctrl.DoubleClick += delegate(object s, EventArgs e)
        {
            if (isFullScreen) return;
            if (MainForm.WindowState == FormWindowState.Maximized) { MainForm.WindowState = FormWindowState.Normal; btnMax.Text = ICON_MAX; }
            else { MainForm.WindowState = FormWindowState.Maximized; btnMax.Text = ICON_RESTORE; }
        };
    }
    static void UpdateTopButton()
    {
        if (btnTop != null) btnTop.BackColor = MainForm.TopMost ? Color.FromArgb(70, 70, 78) : Color.FromArgb(18, 18, 22);
    }

    static void LayoutRdp()
    {
        if (HostPanel == null || Rdp == null || baseW <= 0 || baseH <= 0) return;
        int m = isFullScreen ? 0 : 4;   // 全屏时铺满整个屏幕，不留4px黑边
        int hw = HostPanel.ClientSize.Width - m * 2;
        int hh = HostPanel.ClientSize.Height - m;
        if (hw <= 0 || hh <= 0) return;
        if (isFullScreen)
        {
            Rdp.Size = new Size(hw, hh);
            Rdp.Location = new Point(0, 0);
            try { Rdp.Refresh(); } catch { }
            return;
        }
        double ratio = (double)baseW / baseH;
        double candW = hw, candH = hw / ratio;
        if (candH > hh) { candH = hh; candW = hh * ratio; }
        int rw = (int)candW, rh = (int)candH;
        Rdp.Size = new Size(rw, rh);
        Rdp.Location = new Point(m + (hw - rw) / 2, (hh - rh) / 2);
        try { Rdp.Refresh(); } catch { }
    }

    static void RefreshRdp()
    {
        try
        {
            Rdp.Visible = false;
            LayoutRdp();
            Rdp.Visible = true;
            Rdp.Invalidate();
            Rdp.Refresh();
        }
        catch { }
    }

    static void ReapplyFrameStyle()
    {
        IntPtr h = MainForm.Handle;
        int style = GetWindowLong(h, GWL_STYLE);
        style &= ~WS_CAPTION;
        style &= ~WS_THICKFRAME;
        style &= ~WS_MAXIMIZEBOX;
        SetWindowLong(h, GWL_STYLE, style);
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    static void ToggleMaximize()
    {
        if (isFullScreen) return;
        if (isMaximized)
        {
            isMaximized = false;
            RdpForm.IsMaximized = false;
            MainForm.Bounds = maxPrevBounds;
            if (btnMax != null) btnMax.Text = ICON_MAX;
        }
        else
        {
            isMaximized = true;
            RdpForm.IsMaximized = true;
            maxPrevBounds = MainForm.Bounds;
            MainForm.Bounds = Screen.PrimaryScreen.WorkingArea;
            if (btnMax != null) btnMax.Text = ICON_RESTORE;
        }
    }

    static int savedW = 0, savedH = 0;

    static void UpdateRemoteResolution(int w, int h)
    {
        try
        {
            if (savedW <= 0 || savedH <= 0)
            {
                try
                {
                    if (RdpObject != null)
                    {
                        dynamic rc = RdpObject;
                        int sw = (int)rc.DesktopWidth, sh = (int)rc.DesktopHeight;
                        if (sw > 0 && sh > 0) { savedW = sw; savedH = sh; }
                    }
                }
                catch { }
                if (savedW <= 0 || savedH <= 0) { savedW = baseW; savedH = baseH; }
            }
            bool ok = false;
            try
            {
                if (RdpObject != null)
                {
                    dynamic ctl = RdpObject;
                    ctl.UpdateSessionDisplaySettings((uint)w, (uint)h);
                    ok = true;
                    Log("RemoteResolution: UpdateSessionDisplaySettings -> " + w + "x" + h);
                }
            }
            catch (Exception ex) { Log("RemoteResolution: UpdateSessionDisplaySettings failed: " + ex.Message); }
            if (!ok)
            {
                try
                {
                    uint sessionId = 0;
                    if (WTSGetChildSessionId(out sessionId) && sessionId != 0)
                    {
                        if (WTSChangeChildSessionDisplaySettings(IntPtr.Zero, sessionId, (uint)w, (uint)h))
                        {
                            ok = true;
                            Log("RemoteResolution: WTSChangeChildSessionDisplaySettings -> " + w + "x" + h);
                        }
                        else Log("RemoteResolution: WTS failed, LastError=" + Marshal.GetLastWin32Error());
                    }
                    else Log("RemoteResolution: WTS skip, no child session");
                }
                catch (Exception ex2) { Log("RemoteResolution: WTS exception: " + ex2.Message); }
            }
            if (!ok) Log("RemoteResolution: all methods failed (" + w + "x" + h + ")");
        }
        catch (Exception ex) { Log("RemoteResolution failed: " + ex.Message); }
    }

    static void ToggleFullScreen()
    {
        if (!isFullScreen)
        {
            prevBounds = MainForm.Bounds;
            prevState = MainForm.WindowState;
            prevTopMost = MainForm.TopMost;
            isFullScreen = true;
            btnFull.Text = ICON_RESTORE;
            MainForm.FormBorderStyle = FormBorderStyle.None;
            MainForm.WindowState = FormWindowState.Normal;
            MainForm.Bounds = Screen.PrimaryScreen.Bounds;
            MainForm.TopMost = true;
            UpdateTopButton();
            if (TitleBar != null) TitleBar.Visible = false;
            if (HostPanel != null) HostPanel.Padding = new Padding(0);
            LayoutRdp();
            UpdateRemoteResolution(Screen.PrimaryScreen.Bounds.Width, Screen.PrimaryScreen.Bounds.Height);
            SyncOverlayBounds();
            ShowToast();
            Log("Fullscreen ON");
        }
        else
        {
            isFullScreen = false;
            btnFull.Text = ICON_FULL;
            MainForm.TopMost = prevTopMost;
            UpdateTopButton();
            MainForm.FormBorderStyle = FormBorderStyle.None;
            MainForm.Bounds = prevBounds;
            MainForm.WindowState = prevState;
            if (TitleBar != null) TitleBar.Visible = true;
            if (HostPanel != null) HostPanel.Padding = new Padding(8, 0, 8, 8);
            LayoutRdp();
            UpdateRemoteResolution(savedW, savedH);
            SyncOverlayBounds();
            ReapplyFrameStyle();
            Log("Fullscreen OFF");
        }
    }

    static Button MakeTitleBtn(string icon, Color hover)
    {
        Button b = new Button();
        b.Text = icon;
        b.Size = new Size(36, 0);
        b.Dock = DockStyle.Right;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.BackColor = Color.FromArgb(18, 18, 22);
        b.ForeColor = Color.White;
        b.Font = new Font("Segoe MDL2 Assets", 9f);
        b.MouseEnter += delegate { b.BackColor = hover; };
        b.MouseLeave += delegate { b.BackColor = Color.FromArgb(18, 18, 22); };
        return b;
    }

    static Button MakeTextTitleBtn(string text, int width)
    {
        Button b = new Button();
        b.Text = text;
        b.Size = new Size(width, 0);
        b.Dock = DockStyle.Right;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.BackColor = Color.FromArgb(18, 18, 22);
        b.ForeColor = Color.White;
        b.Font = new Font("Microsoft YaHei UI", 9f);
        b.MouseEnter += delegate { b.BackColor = Color.FromArgb(40, 40, 46); };
        b.MouseLeave += delegate { b.BackColor = Color.FromArgb(18, 18, 22); };
        return b;
    }

    public static void Start(int w, int h, string title)
    {
        try { SetProcessDPIAware(); } catch {}
        Log("Starting standalone RDP window w=" + w + " h=" + h + " title='" + title + "'");

        MainForm = new RdpForm();
        MainForm.FormBorderStyle = FormBorderStyle.None; // borderless + custom edge resize via WM_NCHITTEST
        MainForm.Text = string.IsNullOrEmpty(title) ? DEFAULT_TITLE : title;
        MainForm.StartPosition = FormStartPosition.CenterScreen;
        MainForm.BackColor = Color.FromArgb(18, 18, 22);
        if (!string.IsNullOrEmpty(IconPath) && File.Exists(IconPath))
        {
            try { using (FileStream fs = new FileStream(IconPath, FileMode.Open, FileAccess.Read)) { MainForm.Icon = new Icon(fs); } }
            catch (Exception ex) { Log("Set icon failed: " + ex.Message); }
        }
        RdpForm.HotKeyFullScreen = delegate { if (MainForm != null && MainForm.Visible) ToggleFullScreen(); };
        RdpForm.ToggleMaximizeAction = delegate { ToggleMaximize(); };

        // custom resolution: use provided w/h when set, otherwise primary screen bounds
        baseW = w > 0 ? w : Screen.PrimaryScreen.Bounds.Width;
        baseH = h > 0 ? h : Screen.PrimaryScreen.Bounds.Height;
        MainForm.Size = new Size(baseW / 2, (int)Math.Round(baseH / 2.0) + 34);
        MinW = Math.Max(320, Math.Min(560, baseW / 3));
        MinH = (int)Math.Round(MinW * ((double)baseH / baseW)) + 34;
        MainForm.MinimumSize = new Size(MinW, MinH);
        Log("Aspect=" + (((double)baseW / baseH)).ToString("0.000") + " Min=" + MinW + "x" + MinH);

        // ---- single custom black title bar ----
        const int barH = 34;
        TitleBar = new TransparentHost();
        TitleBar.Dock = DockStyle.Top;
        TitleBar.Height = barH;
        TitleBar.BackColor = Color.FromArgb(18, 18, 22);
        TitleBar.Cursor = Cursors.Default;

        TitleLabel = new CaptionBar();
        TitleLabel.Text = MainForm.Text;
        TitleLabel.OwnerForm = MainForm;
        TitleLabel.ForeColor = Color.White;
        TitleLabel.Font = new Font("Microsoft YaHei UI", 9.5f);
        TitleLabel.BackColor = Color.Transparent;
        TitleLabel.Dock = DockStyle.Fill;
        TitleLabel.TextAlign = ContentAlignment.MiddleLeft;
        TitleLabel.Padding = new Padding(12, 0, 0, 0);
        TitleLabel.Cursor = Cursors.Default;

        Button btnMin = MakeTitleBtn(ICON_MIN, Color.FromArgb(60, 60, 66));
        btnMin.Click += delegate { MainForm.WindowState = FormWindowState.Minimized; };

        btnFull = MakeTitleBtn(ICON_FULL, Color.FromArgb(60, 60, 66));
        btnFull.Click += delegate { ToggleFullScreen(); };

        btnMax = MakeTitleBtn(ICON_MAX, Color.FromArgb(60, 60, 66));
        btnMax.Click += delegate { ToggleMaximize(); };

        Button btnClose = MakeTitleBtn(ICON_CLOSE, Color.FromArgb(196, 43, 28));
        btnClose.Click += delegate { Log("Hide via custom close"); MainForm.Hide(); };

        Button btnUpload = MakeTextTitleBtn("\u6253\u5F00\u5BA2\u6237\u7AEF", 100);
        btnUpload.Click += delegate {
            try { Process.Start("anghaoyu16://"); Log("Open client via private protocol ang1"); }
            catch (Exception ex) { Log("Open client failed: " + ex.Message); }
        };

        Button btnSecurity = MakeTextTitleBtn("\u6253\u5F00\u5B89\u5168\u9009\u9879", 120);
        btnSecurity.Click += delegate {
            if (RdpObject != null) { if (RdpForm.SendCtrlAltEnd()) Log("Open security options"); }
        };

        btnTop = MakeTextTitleBtn("\u7F6E\u9876", 64);
        btnTop.Click += delegate { MainForm.TopMost = !MainForm.TopMost; UpdateTopButton(); };
        btnTop.MouseEnter += delegate { btnTop.BackColor = MainForm.TopMost ? Color.FromArgb(70, 70, 78) : Color.FromArgb(40, 40, 46); };
        btnTop.MouseLeave += delegate { UpdateTopButton(); };

        // desktop layout left-to-right: [打开客户端][打开安全选项][置顶][full][16px][min][max][close]
        btnMin.Margin = new Padding(16, 0, 0, 0);
        TitleBar.Controls.Add(TitleLabel);
        Button btnReconnect = MakeTextTitleBtn("\u91CD\u65B0\u8FDE\u63A5", 90);
        btnReconnect.Click += delegate {
            try {
                if (RdpObject != null) {
                    dynamic r2 = RdpObject;
                    try { r2.Disconnect(); } catch {}
                    r2.Connect();
                    Log("Reconnect clicked");
                }
            } catch (Exception ex) { Log("Reconnect failed: " + ex.Message); }
        };
        TitleBar.Controls.Add(btnReconnect);
        TitleBar.Controls.Add(btnUpload);
        TitleBar.Controls.Add(btnSecurity);
        TitleBar.Controls.Add(btnTop);
        TitleBar.Controls.Add(btnFull);
        TitleBar.Controls.Add(btnMin);
        TitleBar.Controls.Add(btnMax);
        TitleBar.Controls.Add(btnClose);
        TitleBar.Height = barH;



        // hide native title bar but keep resizable frame + rounded corners
        MainForm.HandleCreated += delegate {
            ReapplyFrameStyle();
            IntPtr hnd = MainForm.Handle;
            int pref = DWMWCP_ROUND;
            DwmSetWindowAttribute(hnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, 4);
        };

        MainForm.KeyPreview = true;
        MainForm.PreviewKeyDown += delegate(object s, PreviewKeyDownEventArgs e) {
            if (e.KeyCode == Keys.F7)
            { e.IsInputKey = true; ToggleFullScreen(); }
        };

        // debounce layout to avoid image loss on rapid resize/min/max
        DebounceTimer = new System.Windows.Forms.Timer();
        DebounceTimer.Interval = 120;
        DebounceTimer.Tick += delegate { DebounceTimer.Stop(); RefreshRdp(); };
        MainForm.Resize += delegate { DebounceTimer.Stop(); DebounceTimer.Start(); SyncOverlayBounds(); };
        MainForm.ResizeEnd += delegate { DebounceTimer.Stop(); RefreshRdp(); SyncOverlayBounds(); };
        MainForm.Move += delegate { SyncOverlayBounds(); };
        MainForm.VisibleChanged += delegate { if (!MainForm.Visible && BlackScreen != null && BlackScreen.Visible) BlackScreen.Hide(); };
        MainForm.SizeChanged += delegate { if (btnMax != null) btnMax.Text = isMaximized ? ICON_RESTORE : ICON_MAX; };

        HostPanel = new TransparentHost();
        HostPanel.Dock = DockStyle.Fill;
        HostPanel.BackColor = Color.Black;
        HostPanel.Padding = new Padding(8, 0, 8, 8);

        Rdp = new AxMsRdpClient10();
        Rdp.BackColor = Color.Black;
        HostPanel.Controls.Add(Rdp);

        BlackScreen = new Form();
        BlackScreen.FormBorderStyle = FormBorderStyle.None;
        BlackScreen.ShowInTaskbar = false;
        BlackScreen.StartPosition = FormStartPosition.Manual;
        BlackScreen.BackColor = Color.Black;
        BlackScreen.Visible = false;
        Label noSignalLabel = new Label();
        noSignalLabel.Text = "RDP\u65E0\u4FE1\u53F7\u8F93\u51FA\n\u8BF7\u68C0\u67E5\u662F\u5426\u5DF2\u7ECF\u65AD\u5F00\u8FDE\u63A5\uFF0C\u5E76\u5C1D\u8BD5\u5728\u5BA2\u6237\u7AEF\u91CD\u65B0\u8FDE\u63A5";
        noSignalLabel.ForeColor = Color.White;
        noSignalLabel.BackColor = Color.Black;
        noSignalLabel.TextAlign = ContentAlignment.MiddleCenter;
        noSignalLabel.Dock = DockStyle.Fill;
        noSignalLabel.Font = new Font("Microsoft YaHei", 14f);
        BlackScreen.Controls.Add(noSignalLabel);
        MainForm.Controls.Add(HostPanel);
        MainForm.Controls.Add(TitleBar);

        MainForm.FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (!isFullScreen && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; MainForm.Hide(); Log("Window hidden"); }
        };

        MainForm.Shown += delegate {
            try
            {
                Rdp.CreateControl();
                object ocx = Rdp.GetOcx();
                IMsRdpExtendedSettings ext = ocx as IMsRdpExtendedSettings;
                if (ext == null) { Log("Get IMsRdpExtendedSettings failed"); return; }
                RdpObject = ocx;
                RdpForm.RdpObjectRef = ocx;
                RdpForm.NonScriptable = ocx as IMsRdpClientNonScriptable;
                if (RdpForm.NonScriptable == null) Log("Get IMsRdpClientNonScriptable failed");
                else Log("Got IMsRdpClientNonScriptable");
                try
                {
                    IOleWindow ow = ocx as IOleWindow;
                    IntPtr ocxHwnd;
                    if (ow != null && ow.GetWindow(out ocxHwnd) == 0 && ocxHwnd != IntPtr.Zero)
                    {
                        RdpForm.RdpHwnd = ocxHwnd;
                        Log("Got Rdp Ocx hwnd=" + ocxHwnd.ToString("X8"));
                    }
                    else Log("Get Rdp Ocx window failed");
                }
                catch (Exception owEx) { Log("Get Rdp Ocx window exception: " + owEx.Message); }
                dynamic r = ocx;
                r.AdvancedSettings7.EnableCredSspSupport = true;
                try
                {
                    object secured = r.SecuredSettings2;
                    secured.GetType().InvokeMember("KeyboardHookMode", System.Reflection.BindingFlags.SetProperty, null, secured, new object[] { 1 });
                    Log("KeyboardHookMode=1 set via SecuredSettings2");
                }
                catch (Exception hookEx) { Log("Set KeyboardHookMode via SecuredSettings2 failed: " + hookEx.Message); }
                try
                {
                    r.AdvancedSettings7.EnableWindowsKey = 1;
                    Log("EnableWindowsKey=1 set");
                }
                catch (Exception wnEx) { Log("Set EnableWindowsKey failed: " + wnEx.Message); }
                r.Server = "localhost";
                r.UserName = Environment.UserName;
                r.AdvancedSettings9.AuthenticationLevel = 2;
                r.AdvancedSettings9.SmartSizing = true;
                r.DesktopWidth = baseW;
                r.DesktopHeight = baseH;
                ext.put_Property("ConnectToChildSession", true);
                r.Connect();
                Log("Connect() called");

                // force-remove native title bar after show (HandleCreated may be too early)
                ReapplyFrameStyle();
                MainForm.Refresh();
                RefreshRdp();
                ShowToast();
            }
            catch (Exception ex) { Log("Connect failed: " + ex.Message); }
        };

        StartCmdListener();
        StartConnectMonitor();
        LayoutRdp();
        Application.Run(MainForm);
    }

    static void ShowToast()
    {
        try
        {
            Form t = new Form();
            t.FormBorderStyle = FormBorderStyle.None;
            t.ShowInTaskbar = false;
            t.TopMost = true;
            t.StartPosition = FormStartPosition.Manual;
            int tw = 300, th = 44;
            t.Size = new Size(tw, th);
            int tx, ty;
            if (MainForm != null)
            {
                tx = MainForm.Left + (MainForm.Width - tw) / 2;
                ty = MainForm.Top + (MainForm.Height - th) / 2;
            }
            else
            {
                Rectangle wa = Screen.PrimaryScreen.WorkingArea;
                tx = wa.Left + (wa.Width - tw) / 2;
                ty = wa.Top + (wa.Height - th) / 2;
            }
            t.Location = new Point(tx, ty);
            t.BackColor = Color.FromArgb(18, 18, 22);
            Label l = new Label();
            l.Text = "\u6309\u4e0b F7 \u8fdb\u5165/\u9000\u51fa\u5168\u5c4f";
            l.ForeColor = Color.White;
            l.Font = new Font("Microsoft YaHei UI", 9.5f);
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.MiddleCenter;
            t.Controls.Add(l);
            using (GraphicsPath gp = new GraphicsPath())
            {
                gp.AddArc(0, 0, 12, 12, 180, 90);
                gp.AddArc(tw - 12, 0, 12, 12, 270, 90);
                gp.AddArc(tw - 12, th - 12, 12, 12, 0, 90);
                gp.AddArc(0, th - 12, 12, 12, 90, 90);
                gp.CloseAllFigures();
                t.Region = new Region(gp);
            }
            t.Show();
            double elapsedMs = 0;
            System.Windows.Forms.Timer fade = new System.Windows.Forms.Timer();
            fade.Interval = 40;
            fade.Tick += delegate
            {
                elapsedMs += 40;
                if (elapsedMs >= 2500 && t.Opacity > 0)
                {
                    t.Opacity -= 0.06;
                    if (t.Opacity <= 0) { fade.Stop(); try { t.Close(); } catch {} }
                }
            };
            fade.Start();
            Log("Toast shown");
        }
        catch (Exception ex) { Log("Toast failed: " + ex.Message); }
    }

    static void SetOverlayBounds()
    {
        if (BlackScreen == null || !BlackScreen.Visible) return;
        if (HostPanel == null) return;
        if (BlackScreen.Owner != MainForm) BlackScreen.Owner = MainForm;
        Rectangle rc = HostPanel.RectangleToScreen(HostPanel.ClientRectangle);
        if (rc.Width > 8 && rc.Height > 4) { rc.X += 4; rc.Width -= 8; rc.Height -= 4; }
        BlackScreen.DesktopBounds = rc;
    }

    static void SyncOverlayBounds()
    {
        if (BlackScreen == null || !BlackScreen.Visible) return;
        SetOverlayBounds();
    }

    static void StartConnectMonitor()
    {
        ConnectTimer = new System.Windows.Forms.Timer();
        ConnectTimer.Interval = 1000;
        ConnectTimer.Tick += delegate
        {
            try
            {
                if (RdpObject == null) { connectElapsed = 0; return; }
                dynamic r = RdpObject;
                int conn = r.Connected;
                if (conn == 0)
                {
                    hookReorderDone = false;
                    connectElapsed++;
                    if (connectElapsed >= 1 && MainForm.Visible && BlackScreen != null && !BlackScreen.Visible)
                {
                    if (BlackScreen.Owner != MainForm) BlackScreen.Owner = MainForm;
                    Rectangle rc = HostPanel.RectangleToScreen(HostPanel.ClientRectangle);
                    if (rc.Width > 8 && rc.Height > 4) { rc.X += 4; rc.Width -= 8; rc.Height -= 4; }
                    BlackScreen.DesktopBounds = rc;
                    BlackScreen.Show();
                    BlackScreen.BringToFront();
                    Log("No signal 5s, overlay");
                }
                    if (connectElapsed > 60) { Log("Lost connection (60s), disconnecting"); try { r.Disconnect(); } catch {} connectElapsed = 0; }
                }
                else
                {
                    connectElapsed = 0;
                    if (BlackScreen != null && BlackScreen.Visible) BlackScreen.Hide();
                    if (conn == 1 && !hookReorderDone)
                    {
                        hookReorderDone = true;
                        RdpForm.ReinstallHook();
                    }
                }
            }
            catch { }
        };
        ConnectTimer.Start();
    }

    static void StartCmdListener()
    {
        CmdTimer = new System.Windows.Forms.Timer();
        CmdTimer.Interval = 200;
        CmdTimer.Tick += delegate
        {
            try
            {
                string cmd = "";
                if (!string.IsNullOrEmpty(CmdFilePath) && System.IO.File.Exists(CmdFilePath))
                {
                    cmd = (System.IO.File.ReadAllText(CmdFilePath) ?? "").Trim().ToLowerInvariant();
                }
                if (cmd != LastCmd)
                {
                    LastCmd = cmd;
                    Log("Cmd received: " + cmd);
                    try { System.IO.File.WriteAllText(CmdFilePath, ""); } catch {}
                    if (cmd == "show")
                    {
                        if (isFullScreen) ToggleFullScreen();
                        MainForm.Invoke((MethodInvoker)delegate {
                            MainForm.Show(); MainForm.Activate(); MainForm.BringToFront();
                            MainForm.WindowState = FormWindowState.Normal;
                        });
                    }
                    else if (cmd == "hide") MainForm.Invoke((MethodInvoker)delegate { MainForm.Hide(); });
                    else if (cmd == "logoff")
                    {
                        uint sessionId = 0;
                        if (WTSGetChildSessionId(out sessionId) && sessionId != 0) WTSLogoffSession(IntPtr.Zero, sessionId, false);
                        Application.Exit();
                    }
                    else if (cmd == "close") Application.Exit();
                }
            }
            catch {}
        };
        CmdTimer.Start();
    }
}
"@

try {
    Add-Type -TypeDefinition $rdpCode -ReferencedAssemblies System.Windows.Forms, System.Drawing, Microsoft.CSharp
} catch {
    Write-Log ("Add-Type failed: " + $_.Exception.Message)
    exit 1
}

[RdpWindow]::LogPath = $logPath
[RdpWindow]::CmdFilePath = $cmdPath
[RdpWindow]::IconPath = $iconPath

try {
    [RdpWindow]::Start($Width, $Height, $Title)
} catch {
    Write-Log ("Start threw: " + $_.Exception.Message)
    exit 1
}