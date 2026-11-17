// PenCast (Surface): reads the pen digitizer through raw HID input (works in the background, also while Moonlight is
// fullscreen) and streams "x y pressure tiltX tiltY flags" over UDP to PenRelay on the Mac.
// usage: PenCast.exe <mac-host>[+<fallback-host>...] [port]   (first host that resolves wins; e.g. mymac.local+100.64.0.2)
using System; using System.IO; using System.Net.Sockets; using System.Text; using System.Collections.Generic;
using System.Runtime.InteropServices; using System.Windows.Forms; using System.Globalization;
class PenCast : NativeWindow {
  [StructLayout(LayoutKind.Sequential)] struct RID { public ushort page, usage; public uint flags; public IntPtr hwnd; }
  [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RID[] d, uint n, uint sz);
  [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint sz, uint hsz);
  [DllImport("user32.dll")] static extern uint GetRawInputDeviceInfo(IntPtr dev, uint cmd, IntPtr data, ref uint sz);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr ppd, byte[] caps);
  [DllImport("hid.dll")] static extern int HidP_GetValueCaps(int type, byte[] caps, ref ushort len, IntPtr ppd);
  [DllImport("hid.dll")] static extern int HidP_GetUsageValue(int type, ushort page, ushort link, ushort usage, out uint val, IntPtr ppd, byte[] rpt, uint len);
  [DllImport("hid.dll")] static extern int HidP_GetUsages(int type, ushort page, ushort link, ushort[] usages, ref uint n, IntPtr ppd, byte[] rpt, uint len);
  const ushort DIG = 0x0D, GEN = 0x01;
  class Dev { public IntPtr ppd; public ushort link; public double xmax = 1, ymax = 1, pmax = 1, tmax = 0; public List<ushort> fingers = new List<ushort>(); }
  Dictionary<uint, double[]> touch = new Dictionary<uint, double[]>(); int lastN;
  Dictionary<IntPtr, Dev> devs = new Dictionary<IntPtr, Dev>();
  UdpClient udp; static StreamWriter log; long n;
  // only drive the Mac while Moonlight is the window in front; elsewhere the pen and touch stay with Windows
  DateTime fgAt = DateTime.MinValue; bool fgOk = true, wasOk = true;
  bool MoonlightInFront() {
    if ((DateTime.Now - fgAt).TotalMilliseconds < 150) return fgOk;
    fgAt = DateTime.Now;
    try { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
      fgOk = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.IndexOf("moonlight", StringComparison.OrdinalIgnoreCase) >= 0;
    } catch { fgOk = false; }
    if (!fgOk && wasOk) { var up = Encoding.ASCII.GetBytes("0 0 0 0 0 0"); udp.Send(up, up.Length); var t = Encoding.ASCII.GetBytes("T 0 0 0 0"); udp.Send(t, t.Length); }   // lift pen and fingers
    wasOk = fgOk; return fgOk;
  }
  static void L(string s) { log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff ") + s); log.Flush(); }
  PenCast(string host, int port) {
    udp = new UdpClient(System.Net.Sockets.AddressFamily.InterNetwork);
    System.Net.IPAddress ip = null;
    // host may be a comma list (name.local, LAN IP, Tailscale IP): first one that gives an IPv4 address wins
    for (int tries = 0; ip == null && tries < 10; tries++) {
      foreach (var hn in host.Split('+')) {
        System.Net.IPAddress lit; if (System.Net.IPAddress.TryParse(hn.Trim(), out lit) && tries > 0) { ip = lit; break; }   // literal IPs only after one name attempt
        try { foreach (var a in System.Net.Dns.GetHostAddresses(hn.Trim())) if (a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork) { ip = a; break; } } catch { }
        if (ip != null) break; }
      if (ip == null) System.Threading.Thread.Sleep(500); }
    if (ip == null) { L("cannot resolve " + host); Environment.Exit(1); }
    udp.Connect(ip, port); host = host + " (" + ip + ")";
    var cp = new CreateParams(); cp.ExStyle = 0x80 | 0x08000000; cp.Style = unchecked((int)0x80000000); CreateHandle(cp);
    var r = new RID[] { new RID { page = DIG, usage = 0x02, flags = 0x100, hwnd = Handle }, new RID { page = DIG, usage = 0x04, flags = 0x100, hwnd = Handle } };   // pen + touchscreen, RIDEV_INPUTSINK
    L(RegisterRawInputDevices(r, 2, (uint)Marshal.SizeOf(typeof(RID))) ? "registered, sending to " + host + ":" + port : "register failed " + Marshal.GetLastWin32Error());
  }
  Dev Get(IntPtr h) {
    Dev d; if (devs.TryGetValue(h, out d)) return d;
    d = new Dev(); uint sz = 0; GetRawInputDeviceInfo(h, 0x20000005, IntPtr.Zero, ref sz);
    d.ppd = Marshal.AllocHGlobal((int)sz); GetRawInputDeviceInfo(h, 0x20000005, d.ppd, ref sz);
    var caps = new byte[64]; HidP_GetCaps(d.ppd, caps); ushort nv = BitConverter.ToUInt16(caps, 48);
    var vc = new byte[72 * Math.Max(nv, (ushort)1)]; ushort cnt = nv; HidP_GetValueCaps(0, vc, ref cnt, d.ppd);
    var sb = new StringBuilder();
    for (int i = 0; i < cnt; i++) {
      int o = i * 72; ushort page = BitConverter.ToUInt16(vc, o), link = BitConverter.ToUInt16(vc, o + 6), usage = BitConverter.ToUInt16(vc, o + 56);
      int lmax = BitConverter.ToInt32(vc, o + 44); sb.AppendFormat("[p{0:X} u{1:X} l{2} max{3}] ", page, usage, link, lmax);
      if (page == DIG && usage == 0x51 && !d.fingers.Contains(link)) d.fingers.Add(link);
      if (page == GEN && usage == 0x30) { d.xmax = lmax; if (d.link == 0) d.link = link; }
      if (page == GEN && usage == 0x31) d.ymax = lmax;
      if (page == DIG && usage == 0x30) d.pmax = lmax;
      if (page == DIG && usage == 0x3D) d.tmax = lmax;
    }
    L("device " + h + " " + sb); devs[h] = d; return d;
  }
  protected override void WndProc(ref Message m) { if (m.Msg == 0xFF) try { Raw(m.LParam); } catch (Exception e) { L("ERR " + e.Message); } base.WndProc(ref m); }
  void Raw(IntPtr h) {
    int hs = IntPtr.Size == 8 ? 24 : 16; uint sz = 0; GetRawInputData(h, 0x10000003, IntPtr.Zero, ref sz, (uint)hs);
    IntPtr buf = Marshal.AllocHGlobal((int)sz);
    try {
      GetRawInputData(h, 0x10000003, buf, ref sz, (uint)hs);
      if (Marshal.ReadInt32(buf) != 2) return;
      if (!MoonlightInFront()) return;
      IntPtr hdev = Marshal.ReadIntPtr(buf, 8); var d = Get(hdev);
      int size = Marshal.ReadInt32(buf, hs), count = Marshal.ReadInt32(buf, hs + 4);
      for (int k = 0; k < count; k++) {
        var rpt = new byte[size]; Marshal.Copy(buf + hs + 8 + k * size, rpt, 0, size);
        if (d.fingers.Count > 0) { Touch(d, rpt); continue; }
        uint x = V(d, GEN, 0x30, rpt), y = V(d, GEN, 0x31, rpt), p = V(d, DIG, 0x30, rpt);
        if (x == uint.MaxValue || y == uint.MaxValue) continue;
        var us = new ushort[16]; uint nu = 16; int flags = 0;
        if (HidP_GetUsages(0, DIG, d.link, us, ref nu, d.ppd, rpt, (uint)rpt.Length) == 0x110000)
          for (int i = 0; i < nu; i++) { if (us[i] == 0x32) flags |= 1; if (us[i] == 0x42) flags |= 2; if (us[i] == 0x44) flags |= 4; if (us[i] == 0x45 || us[i] == 0x3C) flags |= 8; }
        double tx = 0, ty = 0;
        if (d.tmax > 0) { uint a = V(d, DIG, 0x3D, rpt), b = V(d, DIG, 0x3E, rpt); if (a != uint.MaxValue) tx = (int)a / d.tmax; if (b != uint.MaxValue) ty = (int)b / d.tmax; }
        string s = string.Format(CultureInfo.InvariantCulture, "{0:F5} {1:F5} {2:F4} {3:F3} {4:F3} {5}", x / d.xmax, y / d.ymax, p == uint.MaxValue ? 0 : p / d.pmax, tx, ty, flags);
        var bytes = Encoding.ASCII.GetBytes(s); udp.Send(bytes, bytes.Length);
        if (++n % 1000 == 1) L("sent " + n + " last " + s);
      }
    } finally { Marshal.FreeHGlobal(buf); }
  }
  // touchscreen: contacts -> "T n cx cy dist" (normalized), sent on every change; the Mac turns 2 fingers into pan/zoom
  void Touch(Dev d, byte[] r) {
    foreach (var link in d.fingers) {
      uint id = VL(d, DIG, link, 0x51, r); if (id == uint.MaxValue) continue;
      var us = new ushort[16]; uint nu = 16; bool tip = false;
      if (HidP_GetUsages(0, DIG, link, us, ref nu, d.ppd, r, (uint)r.Length) == 0x110000) for (int i = 0; i < nu; i++) if (us[i] == 0x42) tip = true;
      uint x = VL(d, GEN, link, 0x30, r), y = VL(d, GEN, link, 0x31, r);
      if (tip && x != uint.MaxValue) touch[id] = new double[] { x / d.xmax, y / d.ymax }; else touch.Remove(id);
    }
    int n = touch.Count; double cx = 0, cy = 0, dist = 0; var pts = new List<double[]>(touch.Values);
    foreach (var p in pts) { cx += p[0]; cy += p[1]; } if (n > 0) { cx /= n; cy /= n; }
    if (n >= 2) { double dx = (pts[0][0] - pts[1][0]) * 1.5, dy = pts[0][1] - pts[1][1]; dist = Math.Sqrt(dx * dx + dy * dy); }
    if (n == 0 && lastN == 0) return; lastN = n;
    var b = Encoding.ASCII.GetBytes(string.Format(CultureInfo.InvariantCulture, "T {0} {1:F5} {2:F5} {3:F5}", n, cx, cy, dist)); udp.Send(b, b.Length);
  }
  uint VL(Dev d, ushort page, ushort link, ushort u, byte[] r) { uint v; return HidP_GetUsageValue(0, page, link, u, out v, d.ppd, r, (uint)r.Length) == 0x110000 ? v : uint.MaxValue; }
  uint V(Dev d, ushort page, ushort u, byte[] r) { uint v; return HidP_GetUsageValue(0, page, d.link, u, out v, d.ppd, r, (uint)r.Length) == 0x110000 ? v : uint.MaxValue; }
  [STAThread] static void Main(string[] a) {
    log = new StreamWriter(Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "pencast.log"), true);
    if (a.Length == 0) { MessageBox.Show("Usage: PenCast.exe <mac-host>[+<other-host>...] [port]", "PenCast"); return; }
    var pc = new PenCast(a[0], a.Length > 1 ? int.Parse(a[1]) : 47555);
    Application.Run();
  }
}
