// GekiBridge: lets an iPad (GekiPad app) act as the ONGEKI cabinet controls on PC.
//  - Has no serial protocol to speak (unlike maimai): ONGEKI's segatools IO is a plain DLL API (mu3io/aimeio), so a
//    companion DLL (GekiIo.dll) is loaded directly into the game process and answers the game's calls by reading a
//    small named shared-memory block. This bridge only has to: (1) talk to the iPad over USB, (2) fill that shared
//    memory block, and (3) stream the game's picture back. No key injection happens here at all - the one exception
//    (coin, which has no mu3io entry point) is injected by GekiIo.dll itself, in-process, right when the game needs it.
//  - Shared memory layout must match GekiIo.dll's GekiPadShared struct byte-for-byte (see pc/dll/GekiIo.cpp).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace GekiBridgeApp
{
    // Talks to Apple's usbmuxd (Apple Mobile Device Service listens on 127.0.0.1:27015) so the PC can open a TCP
    // connection to a port on a USB-connected iPad, like iTunes / Brokenithm's bridge do. (Identical to MaiTouchBridge.)
    static class UsbMux
    {
        const int MuxPort = 27015;

        static string Request(string type, int deviceId, int devicePort)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>");
            sb.Append("<key>MessageType</key><string>" + type + "</string>");
            sb.Append("<key>ClientVersionString</key><string>GekiBridge</string><key>ProgName</key><string>GekiBridge</string><key>kLibUSBMuxVersion</key><integer>3</integer>");
            if (deviceId >= 0)
            {
                int swapped = ((devicePort & 0xFF) << 8) | ((devicePort >> 8) & 0xFF);
                sb.Append("<key>DeviceID</key><integer>" + deviceId + "</integer><key>PortNumber</key><integer>" + swapped + "</integer>");
            }
            sb.Append("</dict></plist>\n");
            return sb.ToString();
        }

        static void SendPacket(NetworkStream ns, string plist, int tag)
        {
            byte[] body = Encoding.UTF8.GetBytes(plist);
            byte[] pkt = new byte[16 + body.Length];
            BitConverter.GetBytes(pkt.Length).CopyTo(pkt, 0);
            BitConverter.GetBytes(1).CopyTo(pkt, 4);
            BitConverter.GetBytes(8).CopyTo(pkt, 8);
            BitConverter.GetBytes(tag).CopyTo(pkt, 12);
            Buffer.BlockCopy(body, 0, pkt, 16, body.Length);
            ns.Write(pkt, 0, pkt.Length);
        }

        static string ReadPacket(NetworkStream ns)
        {
            byte[] hd = new byte[16];
            if (!Fill(ns, hd, 16)) return null;
            int len = BitConverter.ToInt32(hd, 0) - 16;
            if (len < 0 || len > 1 << 20) return null;
            byte[] body = new byte[len];
            if (len > 0 && !Fill(ns, body, len)) return null;
            return Encoding.UTF8.GetString(body);
        }

        static bool Fill(NetworkStream ns, byte[] b, int n)
        {
            int got = 0;
            try { while (got < n) { int r = ns.Read(b, got, n - got); if (r <= 0) return false; got += r; } return true; }
            catch { return false; }
        }

        static int ResultNumber(string plist)
        {
            System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(plist ?? "", "<key>Number</key>\\s*<integer>(\\d+)</integer>");
            return m.Success ? int.Parse(m.Groups[1].Value) : -1;
        }

        public static List<int> ListUsbDevices(out string error)
        {
            error = null;
            List<int> ids = new List<int>();
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    c.Connect(IPAddress.Loopback, MuxPort);
                    NetworkStream ns = c.GetStream();
                    SendPacket(ns, Request("Listen", -1, 0), 1);
                    if (ResultNumber(ReadPacket(ns)) != 0) { error = "usbmuxd refused Listen"; return ids; }
                    ns.ReadTimeout = 500;
                    for (int i = 0; i < 16; i++)
                    {
                        string p = ReadPacket(ns);
                        if (p == null) break;
                        if (p.IndexOf("<string>Attached</string>") < 0) continue;
                        System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(p, "<key>DeviceID</key>\\s*<integer>(\\d+)</integer>");
                        if (!m.Success) continue;
                        if (p.IndexOf("<key>ConnectionType</key>") >= 0 && p.IndexOf("<string>USB</string>") < 0) continue;
                        ids.Add(int.Parse(m.Groups[1].Value));
                    }
                }
            }
            catch (Exception e) { error = e.Message; }
            return ids;
        }

        public static TcpClient Connect(int deviceId, int port, out string error)
        {
            error = null;
            TcpClient c = new TcpClient();
            try
            {
                c.NoDelay = true;
                c.Connect(IPAddress.Loopback, MuxPort);
                NetworkStream ns = c.GetStream();
                ns.ReadTimeout = 3000;
                SendPacket(ns, Request("Connect", deviceId, port), 2);
                int r = ResultNumber(ReadPacket(ns));
                if (r != 0) { error = r == 3 ? "app not open on the iPad" : "usbmuxd connect result " + r; c.Close(); return null; }
                ns.ReadTimeout = System.Threading.Timeout.Infinite;
                return c;
            }
            catch (Exception e) { error = e.Message; try { c.Close(); } catch { } return null; }
        }
    }

    // Mirrors GekiIo.cpp's GekiPadShared struct exactly (Pack=1, same field order/sizes). This process creates (or
    // attaches to, if the DLL got there first) the same named section and writes into it; the DLL only ever reads.
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct GekiPadShared
    {
        public uint magic;
        public byte version;
        public short lever;
        public byte leftBtn, rightBtn, opBtn, coinHeld, cardScan;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)] public byte[] aimeLuid;
        public byte connected;
    }

    class SharedMem
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileMapping(IntPtr hFile, IntPtr lpAttr, uint flProtect, uint dwMaxSizeHigh, uint dwMaxSizeLow, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr MapViewOfFile(IntPtr hMap, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);
        [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
        const uint PAGE_READWRITE = 0x04, FILE_MAP_ALL_ACCESS = 0xF001F;
        const uint MAGIC = 0x44504B47u; // "GKPD"

        IntPtr map = IntPtr.Zero, view = IntPtr.Zero;
        int size;
        readonly object wlock = new object();

        public bool Open(out string error)
        {
            error = null;
            size = Marshal.SizeOf(typeof(GekiPadShared));
            map = CreateFileMapping(new IntPtr(-1), IntPtr.Zero, PAGE_READWRITE, 0, (uint)size, "Local\\GekiPadShared");
            if (map == IntPtr.Zero) { error = "CreateFileMapping failed: " + Marshal.GetLastWin32Error(); return false; }
            view = MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, (UIntPtr)size);
            if (view == IntPtr.Zero) { error = "MapViewOfFile failed: " + Marshal.GetLastWin32Error(); return false; }
            GekiPadShared init = Read();
            if (init.magic != MAGIC)
            {
                init = new GekiPadShared();
                init.magic = MAGIC; init.version = 1; init.aimeLuid = new byte[10];
                Write(init);
            }
            return true;
        }

        GekiPadShared Read()
        {
            return (GekiPadShared)Marshal.PtrToStructure(view, typeof(GekiPadShared));
        }

        public void Write(GekiPadShared s)
        {
            lock (wlock) { Marshal.StructureToPtr(s, view, false); }
        }

        public void Update(Action<GekiPadShared[]> mutate)
        {
            lock (wlock)
            {
                GekiPadShared[] box = { Read() };
                mutate(box);
                Marshal.StructureToPtr(box[0], view, false);
            }
        }

        public void Close()
        {
            if (view != IntPtr.Zero) UnmapViewOfFile(view);
            if (map != IntPtr.Zero) CloseHandle(map);
        }
    }

    // Streams the game window's picture to the iPad app as JPEG frames: [uint32 length LE][jpeg bytes]. Unlike
    // maimai there is no circular crop or forced window resize - ONGEKI's screen is just captured and scaled down
    // to the requested width, preserving its own aspect ratio. The app switches it on/off with "V<width>,<quality>"
    // ("V0" = off). Only this thread writes to the socket.
    class Video
    {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
        [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

        readonly NetworkStream ns;
        readonly object wlock = new object();
        readonly string windowTitle;
        volatile int width = 0, quality = 65;
        volatile bool stop;
        Thread thread;
        readonly object cfgLock = new object();

        public Video(NetworkStream s, string window) { ns = s; windowTitle = window; }

        public void Configure(string arg)
        {
            string[] p = arg.Split(',');
            int w = 0, q = 65;
            int.TryParse(p[0], out w);
            if (p.Length > 1) int.TryParse(p[1], out q);
            if (w != 0) w = Math.Max(320, Math.Min(1600, w));
            q = Math.Max(30, Math.Min(95, q));
            lock (cfgLock)
            {
                width = w; quality = q;
                if (w != 0 && thread == null)
                {
                    thread = new Thread(Loop); thread.IsBackground = true; thread.Priority = ThreadPriority.AboveNormal; thread.Start();
                }
            }
            Program.Log("video " + (w == 0 ? "off" : "on: " + w + "w q" + q));
        }

        public void Stop() { stop = true; }

        public void SendControl(string text)
        {
            byte[] p = Encoding.ASCII.GetBytes(text);
            byte[] f = new byte[4 + p.Length];
            BitConverter.GetBytes((uint)p.Length | 0x80000000u).CopyTo(f, 0);
            Buffer.BlockCopy(p, 0, f, 4, p.Length);
            try { lock (wlock) { ns.Write(f, 0, f.Length); } } catch { }
        }

        IntPtr FindGame()
        {
            IntPtr f = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                StringBuilder sb = new StringBuilder(128); GetWindowText(h, sb, 128);
                if (sb.ToString().IndexOf(windowTitle, StringComparison.OrdinalIgnoreCase) >= 0) { f = h; return false; }
                return true;
            }, IntPtr.Zero);
            return f;
        }

        void Loop()
        {
            try { SetProcessDPIAware(); } catch { }
            ImageCodecInfo jpeg = null;
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpeg = c;
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr mem = IntPtr.Zero, bmp = IntPtr.Zero;
            int curW = 0, curH = 0, curQ = -1;
            EncoderParameters ep = null;
            IntPtr game = IntPtr.Zero;
            Stopwatch sw = new Stopwatch(), stat = Stopwatch.StartNew(), sec = Stopwatch.StartNew();
            int frames = 0; long bytes = 0; double capMs = 0, totMs = 0, maxMs = 0; int secFrames = 0; double secTot = 0;
            bool waiting = false;
            try
            {
                while (!stop)
                {
                    int w = width;
                    if (w == 0) { Thread.Sleep(50); continue; }
                    if (game == IntPtr.Zero || !IsWindowVisible(game)) game = FindGame();
                    RECT cr;
                    if (game == IntPtr.Zero || IsIconic(game) || !GetClientRect(game, out cr) || cr.R - cr.L < 64 || cr.B - cr.T < 64)
                    {
                        game = IntPtr.Zero;
                        if (!waiting) { waiting = true; Program.Log("video: waiting for the game window (looking for a title containing \"" + windowTitle + "\")"); }
                        Thread.Sleep(200); continue;
                    }
                    waiting = false;
                    int cw = cr.R - cr.L, ch = cr.B - cr.T;
                    if (w > cw) w = cw;   // never upscale
                    int h = Math.Max(1, (int)Math.Round(w * (double)ch / cw));
                    if (w != curW || h != curH)
                    {
                        if (bmp != IntPtr.Zero) { SelectObject(mem, IntPtr.Zero); DeleteObject(bmp); }
                        if (mem == IntPtr.Zero) mem = CreateCompatibleDC(screen);
                        bmp = CreateCompatibleBitmap(screen, w, h);
                        SelectObject(mem, bmp);
                        SetStretchBltMode(mem, 4);   // HALFTONE
                        curW = w; curH = h;
                    }
                    if (quality != curQ)
                    {
                        curQ = quality;
                        ep = new EncoderParameters(1);
                        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)curQ);
                    }
                    POINT org = new POINT(); ClientToScreen(game, ref org);
                    sw.Restart();
                    StretchBlt(mem, 0, 0, w, h, screen, org.X, org.Y, cw, ch, 0x00CC0020);
                    double cap = sw.Elapsed.TotalMilliseconds;
                    byte[] jpg;
                    using (Bitmap b = Image.FromHbitmap(bmp))
                    using (MemoryStream ms = new MemoryStream(96 * 1024))
                    {
                        b.Save(ms, jpeg, ep);
                        jpg = ms.ToArray();
                    }
                    byte[] pkt = new byte[4 + jpg.Length];
                    BitConverter.GetBytes(jpg.Length).CopyTo(pkt, 0);
                    Buffer.BlockCopy(jpg, 0, pkt, 4, jpg.Length);
                    lock (wlock) { ns.Write(pkt, 0, pkt.Length); }
                    double tot = sw.Elapsed.TotalMilliseconds;
                    frames++; bytes += jpg.Length; capMs += cap; totMs += tot; if (tot > maxMs) maxMs = tot;
                    secFrames++; secTot += tot;
                    if (sec.ElapsedMilliseconds >= 1000)
                    {
                        SendControl("T" + (secTot / Math.Max(secFrames, 1)).ToString("F1", System.Globalization.CultureInfo.InvariantCulture) + "," + secFrames);
                        secFrames = 0; secTot = 0; sec.Restart();
                    }
                    if (stat.ElapsedMilliseconds >= 5000)
                    {
                        Program.Log(string.Format("video: {0:F1} fps, {1} KB/frame, capture {2:F1} ms, total {3:F1} ms (max {4:F0}), {5:F1} MB/s",
                            frames * 1000.0 / stat.ElapsedMilliseconds, bytes / Math.Max(frames, 1) / 1024, capMs / Math.Max(frames, 1), totMs / Math.Max(frames, 1), maxMs, bytes / 1048576.0 * 1000.0 / stat.ElapsedMilliseconds));
                        frames = 0; bytes = 0; capMs = 0; totMs = 0; maxMs = 0; stat.Restart();
                    }
                    if (tot < 15) Thread.Sleep(1);
                }
            }
            catch (Exception e) { Program.Log("video stopped: " + e.Message); }
            finally
            {
                if (bmp != IntPtr.Zero) { SelectObject(mem, IntPtr.Zero); DeleteObject(bmp); }
                if (mem != IntPtr.Zero) DeleteDC(mem);
                ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }

    static class Program
    {
        static string baseDir, logPath;
        static int usbPort = 24880;
        static string windowTitle = "MU3";       // CONFIRM against the real game window title once installed
        static string deviceTcp = null;          // test hook: replaces usbmuxd with a direct TCP connection
        static byte[] aimeLuid = new byte[10];
        static readonly object logLock = new object();
        static SharedMem shared;
        static int clients = 0, msgCount = 0;

        public static void Log(string m)
        {
            lock (logLock) { try { File.AppendAllText(logPath, DateTime.Now.ToString("HH:mm:ss.fff") + "  " + m + "\r\n"); } catch { } }
        }

        static int Main(string[] args)
        {
            baseDir = AppDomain.CurrentDomain.BaseDirectory;
            logPath = Path.Combine(baseDir, "GekiBridge.log");
            try { File.WriteAllText(logPath, ""); } catch { }
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "--usb-port" && i + 1 < args.Length) int.TryParse(args[++i], out usbPort);
                else if (a == "--window" && i + 1 < args.Length) windowTitle = args[++i];
                else if (a == "--device-tcp" && i + 1 < args.Length) deviceTcp = args[++i];
            }

            LoadAime();
            shared = new SharedMem();
            string err;
            if (!shared.Open(out err)) { Log("cannot open shared memory: " + err); Console.WriteLine("cannot open shared memory: " + err); return 2; }
            Log("shared memory ready (Local\\GekiPadShared); looking for a game window containing \"" + windowTitle + "\"");
            Console.WriteLine("GekiBridge running. Make sure GekiIo.dll is set as [mu3io] and [aimeio] path= in segatools.ini.");

            Thread usb = new Thread(UsbLoop); usb.IsBackground = true; usb.Start();
            while (true) Thread.Sleep(1000);
        }

        static void LoadAime()
        {
            string f = Path.Combine(baseDir, "aime.txt");
            string hex = null;
            try { if (File.Exists(f)) hex = File.ReadAllText(f).Trim(); } catch { }
            if (string.IsNullOrEmpty(hex) || hex.Length != 20)
            {
                byte[] r = new byte[10]; new RNGCryptoServiceProvider().GetBytes(r);
                r[0] = 0x01; // classic Aime cards conventionally start with 0x01 in the real header's examples
                hex = BitConverter.ToString(r).Replace("-", "");
                try { File.WriteAllText(f, hex); } catch { }
                Log("generated a random Aime card id in aime.txt: " + hex);
            }
            for (int i = 0; i < 10; i++) aimeLuid[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        }

        static List<bool> Bits(string s, int n)
        {
            List<bool> r = new List<bool>();
            for (int i = 0; i < n; i++) r.Add(i < s.Length && s[i] == '1');
            return r;
        }

        static void HandleLine(string msg, Video vid)
        {
            char k = msg[0];
            string rest = msg.Substring(1);
            if (k == 'L')
            {
                int v;
                if (int.TryParse(rest, out v))
                {
                    short lv = (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, v));
                    shared.Update(box => { GekiPadShared s = box[0]; s.lever = lv; box[0] = s; });
                }
            }
            else if (k == 'G' && rest.Length >= 10)
            {
                List<bool> b = Bits(rest, 10);
                byte left = 0, right = 0;
                // order per bit: btn1,btn2,btn3,side,menu (matches MU3_IO_GAMEBTN_* bit values 1,2,4,8,0x10)
                byte[] map = { 0x01, 0x02, 0x04, 0x08, 0x10 };
                for (int i = 0; i < 5; i++) { if (b[i]) left |= map[i]; if (b[i + 5]) right |= map[i]; }
                shared.Update(box => { GekiPadShared s = box[0]; s.leftBtn = left; s.rightBtn = right; box[0] = s; });
            }
            else if (k == 'X' && rest.Length >= 4)
            {
                List<bool> b = Bits(rest, 4);
                byte op = 0;
                if (b[0]) op |= 0x01; // test
                if (b[1]) op |= 0x02; // service
                byte coin = (byte)(b[2] ? 1 : 0);
                byte card = (byte)(b[3] ? 1 : 0);
                byte[] luid = aimeLuid;
                shared.Update(box => { GekiPadShared s = box[0]; s.opBtn = op; s.coinHeld = coin; s.cardScan = card; s.aimeLuid = luid; box[0] = s; });
            }
            else if (k == 'V') vid.Configure(rest);
            else if (k == 'P') vid.SendControl("O" + rest);
        }

        static void UsbLoop()
        {
            string lastNote = "";
            while (true)
            {
                TcpClient c = null;
                string err = null, note;
                if (deviceTcp != null)
                {
                    try { string[] hp = deviceTcp.Split(':'); c = new TcpClient(); c.NoDelay = true; c.Connect(hp[0], int.Parse(hp[1])); }
                    catch (Exception e) { err = e.Message; c = null; }
                    note = "test device " + deviceTcp + ": " + err;
                }
                else
                {
                    List<int> ids = UsbMux.ListUsbDevices(out err);
                    if (ids.Count == 0) note = err != null ? "USB service not reachable: " + err + " (install iTunes / Apple Devices)" : "no iPad on USB (plug it in, unlock it, tap Trust)";
                    else
                    {
                        note = "iPad found but " + usbPort + ": ";
                        foreach (int id in ids) { c = UsbMux.Connect(id, usbPort, out err); if (c != null) break; note = "iPad found but " + err; }
                    }
                }
                if (c == null)
                {
                    if (note != lastNote) { Log("USB: " + note); lastNote = note; }
                    Thread.Sleep(1200);
                    continue;
                }
                lastNote = "";
                shared.Update(box => { GekiPadShared s = box[0]; s.connected = 1; box[0] = s; });
                RunUsbSession(c);
                shared.Update(box => {
                    GekiPadShared s = box[0];
                    s.connected = 0; s.lever = 0; s.leftBtn = 0; s.rightBtn = 0; s.opBtn = 0; s.coinHeld = 0; s.cardScan = 0;
                    box[0] = s;
                });
                Thread.Sleep(300);
            }
        }

        static void RunUsbSession(TcpClient c)
        {
            Video vid = null;
            int now = Interlocked.Increment(ref clients);
            Log("iPad app connected over USB (" + now + " client(s))");
            try
            {
                NetworkStream ns = c.GetStream();
                c.SendBufferSize = 64 * 1024;
                vid = new Video(ns, windowTitle);
                byte[] buf = new byte[256];
                StringBuilder line = new StringBuilder();
                while (true)
                {
                    int n = ns.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    for (int i = 0; i < n; i++)
                    {
                        char ch = (char)buf[i];
                        if (ch != '\n') { if (line.Length < 200) line.Append(ch); continue; }
                        string msg = line.ToString(); line.Length = 0;
                        if (msg.Length == 0) continue;
                        msgCount++;
                        if (msgCount <= 12 && msg[0] != 'P' && msg[0] != 'L') Log("iPad message: " + msg);
                        HandleLine(msg, vid);
                    }
                }
            }
            catch { }
            finally
            {
                if (vid != null) vid.Stop();
                try { c.Close(); } catch { }
                int left = Interlocked.Decrement(ref clients);
                Log("iPad app disconnected (" + left + " client(s) left)");
            }
        }
    }
}
